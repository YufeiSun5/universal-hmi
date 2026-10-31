"""Repackage a verified application with pinned, offline private PostgreSQL.

The application's build manifest stays unchanged. A separate deployment manifest
records packaging scripts and PG bytes; this is not a new application build.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import time
import zipfile

from common import ROOT
from build_installers import verify_bundle
from build_release import sha256, sources
from stage_gis import verify_staged as verify_gis


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--postgres-zip', type=Path, required=True)
    parser.add_argument('--compiler', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'dist/installers')
    parser.add_argument('--no-supplement', action='store_true', help='Produce only the full installer, with no extra PostgreSQL ZIP delivery')
    args = parser.parse_args()
    bundle = args.bundle.resolve(strict=True)
    manifest = verify_bundle(bundle, 'windows')
    verify_gis(bundle / 'web', manifest['source_files'])
    # Permit deployment-only changes without relabeling or rebuilding app bytes.
    previous = manifest['source_files']
    current = sources()
    differences = [n for n in previous.keys() | current.keys() if previous.get(n) != current.get(n)]
    assert all(n.startswith(('packaging/windows-lazy/', 'ci/build_windows_lazy.py', 'ci/test_windows_lazy.py', 'ci/test_v10_reset.py')) for n in differences), differences
    recipe = ROOT/'packaging/windows-lazy'
    installer_code=(recipe/'windows-lazy.iss').read_text(encoding='utf-8-sig').split('[Code]',1)[1]
    assert all(token not in installer_code for token in ('Reset-Project-v10.ps1','ResetPage','CurStepChanged')), 'Preserve-only installer must not invoke project maintenance'
    lock = json.loads((recipe/'postgresql.lock.json').read_text(encoding='utf-8'))
    archive = args.postgres_zip.resolve(strict=True)
    assert archive.stat().st_size == lock['archive_size']
    assert sha256(archive) == lock['archive_sha256'], 'PostgreSQL archive checksum mismatch'
    work = ROOT/'.local'/('lazy-installer-build-'+time.strftime('%Y%m%d-%H%M%S'))
    work.mkdir(parents=True, exist_ok=False)
    pg = work/'postgresql'
    with zipfile.ZipFile(archive) as source:
        for item in source.infolist():
            path = PurePosixPath(item.filename)
            assert not path.is_absolute() and '..' not in path.parts and '\\' not in item.filename
            if len(path.parts) < 2 or path.parts[0] != 'pgsql' or item.is_dir():
                continue
            if path.parts[1] not in ('bin','lib','share','doc') and not (len(path.parts) == 2 and path.name.endswith('.txt')):
                continue
            # Optional interactive installer is not needed for the private cluster.
            if path.name.lower() == 'stackbuilder.exe':
                continue
            target = pg/Path(*path.parts[1:])
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.open(item) as inp, target.open('wb') as out:
                shutil.copyfileobj(inp,out)
    # Same redistributable files already verified for the desktop; make PG portable.
    for runtime in bundle.glob('*140*.dll'):
        shutil.copy2(runtime,pg/'bin'/runtime.name)
    shutil.copytree(bundle/'licenses',pg/'licenses-app-local-runtime')
    version = subprocess.check_output([str(pg/'bin/postgres.exe'),'--version'],text=True).strip()
    assert version == 'postgres (PostgreSQL) '+lock['version'], version
    pg_files = {p.relative_to(pg).as_posix():sha256(p) for p in pg.rglob('*') if p.is_file()}
    scripts = {p.relative_to(ROOT).as_posix():sha256(p) for p in recipe.iterdir() if p.is_file()}
    scripts['ci/build_windows_lazy.py'] = sha256(Path(__file__))
    test = ROOT/'ci/test_windows_lazy.py'
    if test.exists(): scripts['ci/test_windows_lazy.py'] = sha256(test)
    reset_test=ROOT/'ci/test_v10_reset.py'
    if reset_test.exists(): scripts['ci/test_v10_reset.py']=sha256(reset_test)
    frozen_recipe=work/'recipe'
    shutil.copytree(recipe,frozen_recipe)
    deployment = {'schema':1,'application_source_sha256':manifest['source_sha256'],
                  'application_manifest_sha256':sha256(bundle/'build-manifest.json'),
                  'application_recompiled':False,'packaging_sources':scripts,
                  'postgresql':lock,'postgresql_files':pg_files,
                  'launcher_sha256':sha256(recipe/'Start-HMI.ps1'),'upgrade_policy':'preserve-only','installer_invokes_project_reset':False}
    digest = hashlib.sha256(json.dumps(deployment,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    deployment['deployment_sha256'] = digest
    deployment['payload_id'] = manifest['source_sha256'][:12]+'-pg-'+digest[:12]
    deploy_manifest = work/'deployment-manifest.json'
    write_json(deploy_manifest,deployment)
    output=args.output.resolve()
    output.mkdir(parents=True,exist_ok=True)
    supplement=None
    if not args.no_supplement:
        supplement=output/'Universal-HMI-PostgreSQL-18.6-Supplement.zip'
        with zipfile.ZipFile(supplement,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as out:
            for name in sorted(pg_files):out.write(pg/name,'postgresql/'+name)
            out.write(recipe/'INSTALL.txt','PG-Supplement-README.txt')
            out.write(deploy_manifest,'PG-Supplement-manifest.json')
    subprocess.run([str(args.compiler.resolve()),'/Qp',f'/DBundleDir={bundle}',
                    f'/DPgDir={pg}',f'/DOutputDir={output}',f'/DPayloadId={deployment["payload_id"]}',
                    f'/DDeployManifest={deploy_manifest}',str(frozen_recipe/'windows-lazy.iss')],check=True)
    assert all(sha256(ROOT/name)==checksum for name,checksum in scripts.items()), 'Deployment sources changed while building; rebuild before delivery'
    setup=output/'Universal-HMI-20261030-Full-v19-Setup.exe'
    evidence={'schema':1,'installer':str(setup),'sha256':sha256(setup),'size_bytes':setup.stat().st_size,
              'supplement':str(supplement) if supplement else None,'supplement_sha256':sha256(supplement) if supplement else None,'supplement_size':supplement.stat().st_size if supplement else None,
              'application_source_sha256':manifest['source_sha256'],'deployment_sha256':digest,
              'payload_id':deployment['payload_id'],'work':str(work),'signed':False,'upgrade_policy':'preserve-only','installer_invokes_project_reset':False,
              'webview2':'external prerequisite; not bundled or installed'}
    write_json(output/'Universal-HMI-20261030-Full-v19-Setup.manifest.json',evidence)
    (output/'Universal-HMI-20261030-Full-v19-SHA256.txt').write_text(evidence['sha256']+'  '+setup.name+'\n'+(evidence['supplement_sha256']+'  '+supplement.name+'\n' if supplement else ''),encoding='utf-8')
    shutil.copy2(recipe/'INSTALL.txt',output/'Universal-HMI-20261030-部署说明.txt')
    verify_bundle(bundle,'windows')
    print(json.dumps(evidence),flush=True)


if __name__ == '__main__':main()
