"""Isolated real two-listener HTTPS smoke; no PostgreSQL or field connections."""
import http.client
import argparse, base64, ctypes, datetime, hashlib, hmac, ipaddress, json, os
from pathlib import Path
import signal, socket, ssl, struct, subprocess, time, urllib.request, urllib.error, uuid, zlib
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
ROOT=Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server',type=Path)
    args=parser.parse_args()
    out=ROOT/'.local'/('public-remote-'+time.strftime('%Y%m%d-%H%M%S'))
    out.mkdir()
    server=args.server.resolve() if args.server else out/'universal-hmi-server.exe'
    if not args.server:
        go=ROOT/'.local/toolchains/go-1.24.7/go/bin/go.exe'
        env=os.environ.copy();env['GOROOT']=str(go.parent.parent);env['GOTOOLCHAIN']='local'
        subprocess.run([str(go),'build','-trimpath','-o',str(server),'./cmd/server'],cwd=ROOT/'backend',env=env,check=True)
    def free():
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));return sock.getsockname()[1]
    local_port,remote_port=free(),free()
    local=f'http://127.0.0.1:{local_port}';remote=f'https://127.0.0.1:{remote_port}'
    key=ec.generate_private_key(ec.SECP256R1());now=datetime.datetime.now(datetime.timezone.utc)
    subject=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'Isolated HMI loopback smoke')])
    cert=(x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=1)).not_valid_after(now+datetime.timedelta(hours=1)).add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]),False).add_extension(x509.BasicConstraints(ca=False,path_length=None),True).add_extension(x509.KeyUsage(True,False,False,False,False,False,False,False,False),True).sign(key,hashes.SHA256()))
    cert_file=out/'test-cert.pem';cert_file.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    (out/'test-key.pem').write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
    config={'schema':2,'enabled':True,'web_allowlist':[{'cidr':'127.0.0.1/32','owner':'Synthetic loopback test'}],'origin':remote,'listen':f'127.0.0.1:{remote_port}','certificate':'test-cert.pem','private_key':'test-key.pem'}
    (out/'remote.json').write_text(json.dumps(config))
    tls=ssl.create_default_context(cafile=str(cert_file)) # explicit isolated trust, no OS trust changes
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPSHandler(context=tls))
    checks={};token='';password='Smoke-'+uuid.uuid4().hex
    def call(base,method,path,body=None,auth=None,origin=None,expected=200):
        data=None if body is None else json.dumps(body).encode()
        address=urllib.parse.urlsplit(base)
        connection=(http.client.HTTPSConnection(address.hostname,address.port,context=tls,timeout=8) if address.scheme=='https' else http.client.HTTPConnection(address.hostname,address.port,timeout=8))
        headers={'Origin':origin or base,'Content-Type':'application/json'}
        if auth:headers['Authorization']='Bearer '+auth
        try:
            connection.request(method,path,body=data,headers=headers)
            response=connection.getresponse();status=response.status;raw=response.read()
        finally:connection.close()
        assert status==expected,(method,path,status,raw[:300])
        return json.loads(raw) if raw else None
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.CreateEventW.restype=ctypes.c_void_p;kernel.CreateEventW.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_wchar_p]
    kernel.SetEvent.argtypes=[ctypes.c_void_p];kernel.CloseHandle.argtypes=[ctypes.c_void_p]
    name='Local\\HMI-Smoke-'+uuid.uuid4().hex
    event=kernel.CreateEventW(None,1,0,name);assert event
    log=(out/'server.log').open('wb')
    child_env=os.environ.copy();child_env['HMI_SMOKE_STACKS']=str(out/'goroutines.txt')
    child=subprocess.Popen([str(server),'--listen',f'127.0.0.1:{local_port}','--data-dir',str(out/'data'),'--identity','--identity-local-setup','--public-origin',local,'--remote-config',str(out/'remote.json'),'--shutdown-event',name],stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NEW_PROCESS_GROUP,env=child_env)
    try:
        for _ in range(100):
            if child.poll() is not None:raise AssertionError('backend exited: '+(out/'server.log').read_text())
            try:call(local,'GET','/health');break
            except (OSError,urllib.error.URLError):time.sleep(.1)
        else:raise AssertionError('backend startup timed out')
        call(local,'POST','/api/v1/auth/setup',{'username':'smoke-owner','password':password});checks['local_setup']=True
        session=call(remote,'POST','/api/v1/auth/login',{'username':'smoke-owner','password':password,'issue_token':True});token=session['bearer_token'];assert session['mfa_required'];checks['actual_tls_login']=True
        call(remote,'GET','/api/v1/runtime',auth=token,expected=403)
        secret=call(remote,'POST','/api/v1/security/mfa/begin',{'password':password},token)['secret']
        counter=int(time.time())//30;digest=hmac.new(base64.b32decode(secret+'='*((8-len(secret)%8)%8)),struct.pack('>Q',counter),hashlib.sha1).digest();offset=digest[-1]&15;code=f'{(struct.unpack(">I",digest[offset:offset+4])[0]&0x7fffffff)%1000000:06d}'
        recovery=call(remote,'POST','/api/v1/security/mfa/confirm',{'code':code},token)['recovery_codes'];checks['remote_mfa']=True
        local_session=call(local,'POST','/api/v1/auth/login',{'username':'smoke-owner','password':password,'issue_token':True,'code':recovery[0]});local_token=local_session['bearer_token']
        assert not session['can_write'] and not session['can_develop'] and not session['can_manage_users']
        call(local,'GET','/api/v1/runtime',auth=token,expected=401)
        call(remote,'GET','/api/v1/runtime',auth=local_token,expected=401);checks['bidirectional_session_isolation']=True
        call(remote,'GET','/api/v1/runtime',auth=token);checks['remote_read']=True
        call(remote,'POST','/api/v1/points',{},token,expected=403)
        call(remote,'POST','/api/v1/apply',{},token,expected=403)
        point=call(local,'POST','/api/v1/points',{'station':'smoke-only','name':'isolated manual sample','source_type':'manual','data_type':'FLOAT'},local_token,expected=201)
        call(local,'POST','/api/v1/apply',{},local_token)
        call(local,'POST','/api/v1/points/'+point['id']+'/sample',{'value':42.25},local_token)
        def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
        png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(b'\x00\x22\x88\xcc\xff'))+chunk(b'IEND',b'')
        asset={'name':'smoke-pixel.png','mime':'image/png','data':base64.b64encode(png).decode()}
        material={'schema_version':1,'id':'smoke-material','revision':0,'name':'isolated smoke material','category':'smoke','width':1,'height':1,'asset':asset}
        saved=call(local,'PUT','/api/v1/process-materials/smoke-material',material,local_token)
        read=call(local,'GET','/api/v1/process-materials/smoke-material',auth=local_token);assert read['asset']==asset and read['revision']==saved['revision'];checks['material_upload_readback']=True
        screen={'schema_version':1,'id':'smoke-screen','revision':0,'name':'isolated smoke drawing','station':'smoke-only','width':800,'height':600,'nodes':[{'id':'image','kind':'image','x':10,'y':10,'width':50,'height':50,'image':'pixel','color':'#112233','fill':'none','stroke_width':1,'font_size':12}],'assets':{'pixel':asset}}
        saved=call(local,'PUT','/api/v1/screens/smoke-screen',screen,local_token)
        read=call(remote,'GET','/api/v1/screens/smoke-screen',auth=token);assert read['assets']['pixel']==asset and read['nodes'][0]['image']=='pixel' and read['revision']==saved['revision'];checks['screen_save_readback']=True
        req=urllib.request.Request(remote+'/api/v1/runtime/events?protocol=delta&ids='+point['id'],headers={'Authorization':'Bearer '+token,'Origin':remote})
        with opener.open(req,timeout=8) as response:
            event_type='';frame=None
            for _ in range(20):
                line=response.readline().decode().strip()
                if line.startswith('event:'):event_type=line[6:].strip()
                if line.startswith('data:'):frame=json.loads(line[5:])
                if not line and frame is not None:break
            assert frame and frame['kind']=='reset' and any(v['point_id']==point['id'] and v['value']==42.25 for v in frame['values']),frame
        checks['sse_actual_sample']=True
        # urllib forces Connection: close; exercise bounded early-body rejection
        # repeatedly without retrying any request or accepting a disconnect.
        for denial in range(20):
            req=urllib.request.Request(remote+'/api/v1/screens/smoke-screen',data=json.dumps(screen).encode(),method='PUT',headers={'Origin':remote if denial%2==0 else 'https://wrong.invalid','Content-Type':'application/json'})
            if denial%2:req.add_header('Authorization','Bearer '+token)
            try:
                response=opener.open(req,timeout=8)
                raise AssertionError('rejected write unexpectedly accepted')
            except urllib.error.HTTPError as error:
                assert error.code==403,(denial,error.code)
                error.read()
        checks['twenty_connection_close_body_rejections']=True
        call(remote,'PUT','/api/v1/screens/smoke-screen',screen,expected=403)
        call(remote,'PUT','/api/v1/screens/smoke-screen',screen,token,origin='https://wrong.invalid',expected=403);checks['unauthenticated_write_and_wrong_origin_rejected']=True
        call(remote,'GET','/api/v1/local/deployment',auth=token,expected=403)
        deployment=opener.open(local+'/api/v1/local/deployment',timeout=5);assert json.load(deployment)['remote_enabled'];checks['deployment_local_only']=True
        call(remote,'GET','/api/v1/runtime',auth=token,origin='https://wrong.invalid',expected=403)
        call(local,'GET','/api/v1/runtime',auth=local_token);checks['local_still_usable']=True
    finally:
        assert kernel.SetEvent(event),ctypes.get_last_error()
        try:child.wait(timeout=12)
        except subprocess.TimeoutExpired:
            child.send_signal(signal.CTRL_BREAK_EVENT)
            time.sleep(2)
            if child.poll() is None:child.kill()
            child.wait();raise AssertionError('isolated shutdown exceeded 12 seconds')
        kernel.CloseHandle(event);log.close()
    assert child.returncode==0,child.returncode
    for port in (local_port,remote_port):
        with socket.socket() as sock:assert sock.connect_ex(('127.0.0.1',port))!=0
    checks['graceful_shutdown_both_listeners_closed']=True
    evidence={'passed':True,'checks':checks,'server_sha256':hashlib.sha256(server.read_bytes()).hexdigest(),'tls_certificate_sha256':cert.fingerprint(hashes.SHA256()).hex(),'local_origin':local,'remote_origin':remote,'storage':'isolated SQLite','scope':'loopback integration only; no real public network, PG, browser acceptance or field device','directory':str(out)}
    (out/'evidence.json').write_text(json.dumps(evidence,indent=2));print(json.dumps(evidence,indent=2))
if __name__=='__main__':main()
