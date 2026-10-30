"""Real PostgreSQL/PowerShell integration checks, using isolated local projects.

Requires an assembled payload containing Start-HMI.ps1 and postgresql/. Does not
touch the default user project, installed services, or the review server.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import time
import urllib.request


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def inventory(root):return {p.relative_to(root).as_posix():digest(p) for p in root.rglob('*') if p.is_file()}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--payload',type=Path,required=True)
    parser.add_argument('--legacy-fixture',type=Path,required=True)
    parser.add_argument('--work',type=Path,required=True)
    args=parser.parse_args()
    payload=args.payload.resolve(strict=True)
    work=args.work.resolve()
    work.mkdir(parents=True,exist_ok=False)
    ps=Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe'
    report={}
    projects=[]

    def launch(project,legacy=None,stop=False,ok=True,view='runtime'):
        command=[str(ps),'-NoProfile','-ExecutionPolicy','Bypass','-File',str(payload/'Start-HMI.ps1'),
                 '-ProjectRoot',str(project),'-LegacyRoot',str(legacy or work/'absent'),'-NoUI','-View',view]
        if stop:command.append('-Stop')
        logfile=work/(project.name+('-stop' if stop else '-launch')+'.log')
        # Long-lived PG may inherit Windows handles; no communicate()/pipe EOF wait.
        with logfile.open('wb') as output:
            result=subprocess.run(command,stdout=output,stderr=subprocess.STDOUT,timeout=160,creationflags=subprocess.CREATE_NO_WINDOW)
        result.stdout=logfile.read_text(encoding='utf-8',errors='replace')
        assert (result.returncode==0)==ok,(project.name,result.returncode,result.stdout)
        return result

    def state(project):return json.loads((project/'private-settings.json').read_text(encoding='utf-8-sig'))
    def sql(project,query,database='universal_hmi'):
        settings=state(project)
        env=dict(os.environ,PGPASSWORD=settings['adminPassword'])
        result=subprocess.run([str(payload/'postgresql/bin/psql.exe'),'-X','-w','-h','127.0.0.1','-p',str(settings['pgPort']),
            '-U','hmi_admin','-d',database,'-A','-t','-v','ON_ERROR_STOP=1','-c',query],env=env,capture_output=True,text=True,timeout=15,creationflags=subprocess.CREATE_NO_WINDOW)
        assert result.returncode==0,'Isolated test SQL failed'
        return result.stdout.strip()
    def ready(project):return json.loads((project/'ready.json').read_text(encoding='utf-8-sig'))
    def get(project,path):
        with urllib.request.urlopen(ready(project)['url']+path,timeout=5) as response:return response.read()
    def counts(project):
        return {table:int(sql(project,'SELECT count(*) FROM '+table+';')) for table in ['samples','config','executions','users','stations','audit','mfa','recovery','custom_roles','user_role_policy','documents']}
    def block(port):
        s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_EXCLUSIVEADDRUSE,1)
        s.bind(('127.0.0.1',port));s.listen();return s
    def assert_stopped(project):
        for port in [state(project)['pgPort'],state(project)['httpPort']]:
            with socket.socket() as probe:assert probe.connect_ex(('127.0.0.1',port))!=0

    try:
        clean=work/'clean project';projects.append(clean)
        blockers=[]
        for port in [18080,55432]:
            try:blockers.append(block(port))
            except OSError:pass # An existing listener also exercises first-start fallback.
        try:launch(clean)
        finally:
            for sock in blockers:sock.close()
        assert state(clean)['pgPort']!=55432 and state(clean)['httpPort']!=18080
        assert json.loads(get(clean,'/health'))['authentication_required'] is True
        assert get(clean,'/')==(payload/'web/index.html').read_bytes()
        assert get(clean,'/main.dart.js')==(payload/'web/main.dart.js').read_bytes()
        session=json.loads(get(clean,'/api/v1/auth/session'))
        assert session['setup_required'] and not session['authenticated']
        assert counts(clean)['users']==0,'Package seeded an account'
        assert sql(clean,"SELECT rolsuper,rolcreatedb,rolcreaterole FROM pg_roles WHERE rolname='hmi_app';")=='f|f|f'
        assert sql(clean,'SHOW listen_addresses;')=='127.0.0.1'
        pid=(clean/'postgres-data/postmaster.pid').read_text().splitlines()[0]
        before=counts(clean)
        launch(clean,view='developer')
        assert counts(clean)==before
        assert (clean/'postgres-data/postmaster.pid').read_text().splitlines()[0]==pid
        report['clean']={'first_start':True,'automatic_port_fallback':True,'no_default_account':True,'application_role_restricted':True,'web_bytes_match':True,'repeat_developer_reuses_pg':True}
        launch(clean,stop=True);assert_stopped(clean)
        # An unrelated listener must not be stopped or reused.
        blocker=block(state(clean)['pgPort'])
        try:
            failure=launch(clean,ok=False)
            assert 'occupied' in failure.stdout
            assert blocker.fileno()!=-1
        finally:blocker.close()
        launch(clean)
        assert counts(clean)==before
        report['clean']['stop_restart_and_pg_conflict']=True

        legacy=work/'legacy source';shutil.copytree(args.legacy_fixture,legacy)
        # Add a history row to the isolated copy, never the reference fixture.
        history=legacy/'history.db'
        conn=sqlite3.connect(history)
        now=int(time.time()*1000)
        conn.execute('INSERT INTO samples(point_id,station,name,value,raw,numeric,unit,quality,source_time,received_time,version) VALUES(?,?,?,?,?,?,?,?,?,?,?)',
                     ('migration-proof','Test station','Migration proof','12.5','12.5',12.5,'C','good',now,now,'test'))
        conn.commit();conn.execute('PRAGMA wal_checkpoint(TRUNCATE)');conn.close()
        source_before=inventory(legacy)
        migrated=work/'upgrade project';projects.append(migrated)
        launch(migrated,legacy)
        assert inventory(legacy)==source_before
        assert inventory(migrated/'legacy-backup')==source_before
        assert int(sql(migrated,"SELECT count(*) FROM samples WHERE point_id='migration-proof';"))==1
        assert sql(migrated,"SELECT numeric FROM samples WHERE point_id='migration-proof';")=='12.5'
        expected_docs=[]
        if (legacy/'points.json').exists():expected_docs.append(('points','definitions',legacy/'points.json'))
        for kind,folder in [('screens',legacy/'screens'),('materials',legacy/'screens/materials')]:
            expected_docs.extend((kind,p.stem,p) for p in folder.glob('*.json'))
        for kind,name,path in expected_docs:
            assert "'" not in name
            actual=bytes.fromhex(sql(migrated,f"SELECT encode(data,'hex') FROM documents WHERE kind='{kind}' AND id='{name}';"))
            assert actual==path.read_bytes(),name
        after=counts(migrated)
        # The DB marker is sufficient even if the launcher's completion record vanished.
        (migrated/'ready.json').unlink()
        launch(migrated,legacy,view='developer')
        assert counts(migrated)==after
        assert inventory(legacy)==source_before
        launch(migrated,stop=True);assert_stopped(migrated)
        launch(migrated,legacy)
        assert counts(migrated)==after
        report['upgrade']={'original_unchanged':True,'backup_byte_exact':True,'documents_byte_exact':len(expected_docs),'historical_value_retained':True,'repeat_does_not_reimport':True,'restart_preserves_counts':after}

        corrupt=work/'corrupt legacy';shutil.copytree(legacy,corrupt)
        (corrupt/'points.json').write_text('{broken json',encoding='utf-8')
        failed=work/'failed migration';projects.append(failed)
        corrupt_before=inventory(corrupt)
        launch(failed,corrupt,ok=False)
        assert inventory(corrupt)==corrupt_before
        assert sql(failed,"SELECT count(*) FROM config WHERE key='postgres_migration';")=='0'
        assert not (failed/'ready.json').exists()
        shutil.copy2(legacy/'points.json',failed/'data/points.json')
        launch(failed,corrupt)
        assert sql(failed,"SELECT count(*) FROM config WHERE key='postgres_migration';")=='1'
        report['migration_failure']={'failed_closed':True,'original_preserved':True,'no_completion_marker_on_failure':True,'retry_after_repair':True}
    finally:
        for project in reversed(projects):
            if (project/'private-settings.json').exists():launch(project,stop=True)
    report['all_test_backgrounds_stopped']=True
    (work/'result.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report),flush=True)


if __name__=='__main__':main()
