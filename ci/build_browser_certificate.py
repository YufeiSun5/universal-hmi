"""Build a per-user certificate installer containing only a public server leaf."""
import argparse
import hashlib
import ipaddress
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
from datetime import datetime, timezone
from urllib.parse import urlsplit

from cryptography import x509
from cryptography.hazmat.primitives.serialization import Encoding

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin', required=True)
    parser.add_argument('--server-certificate', type=Path, required=True)
    parser.add_argument('--compiler', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    url = urlsplit(args.origin)
    assert url.scheme == 'https' and url.hostname and url.path == ''
    assert not url.username and not url.password and not url.query and not url.fragment
    assert url.port != 443, 'Omit the default HTTPS port for a canonical origin'
    raw = args.server_certificate.read_bytes()
    assert b'PRIVATE KEY' not in raw
    cert = x509.load_pem_x509_certificate(raw) if raw.startswith(b'-----BEGIN') else x509.load_der_x509_certificate(raw)
    assert not cert.extensions.get_extension_for_class(x509.BasicConstraints).value.ca
    assert cert.subject == cert.issuer, 'This deployment uses an explicitly pinned self-signed server leaf'
    assert cert.not_valid_before_utc <= datetime.now(timezone.utc) < cert.not_valid_after_utc
    san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    try:
        ip = ipaddress.ip_address(url.hostname)
    except ValueError:
        assert url.hostname in san.get_values_for_type(x509.DNSName)
    else:
        assert ip in san.get_values_for_type(x509.IPAddress)
    public = cert.public_bytes(Encoding.DER)
    digest = hashlib.sha256(public).hexdigest()
    site_id = hashlib.sha256(args.origin.encode()).hexdigest()[:24]
    config = dict(schema=1, origin=args.origin, server_certificate='server-public.cer', server_sha256=digest)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='browser-installer-', dir=ROOT / '.local'))
    recipe = ROOT / 'packaging/browser-certificate'
    for name in ('Browser-Certificate.ps1', 'Browser-Policy.ps1', 'README.txt'):
        # Windows PowerShell 5.1 requires BOM for Chinese source text.
        (work / name).write_text((recipe / name).read_text('utf-8-sig'), encoding='utf-8-sig')
    (work / 'server-public.cer').write_bytes(public)
    (work / 'site.json').write_text(json.dumps(config, indent=2), encoding='utf8')
    app_id = str(uuid.uuid5(uuid.NAMESPACE_URL, 'universal-hmi/browser/' + args.origin))
    subprocess.run([str(args.compiler.resolve()), '/Qp', f'/DPayloadDir={work}',
                    f'/DOutputDir={output}', f'/DSiteID={site_id}', f'/DSetupAppId={app_id}',
                    str(recipe / 'browser-certificate.iss')], check=True)
    setup = output / 'Universal-HMI-Browser-Certificate-Setup.exe'
    evidence = dict(schema=1, origin=args.origin, server_sha256=digest, signed=False,
                    installer_sha256=hashlib.sha256(setup.read_bytes()).hexdigest(),
                    installer_bytes=setup.stat().st_size, payload=str(work),
                    sources={p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                             for p in [*recipe.iterdir(), Path(__file__)] if p.is_file()})
    setup.with_suffix('.json').write_text(json.dumps(evidence, indent=2), encoding='utf8')
    shutil.copyfile(recipe / 'README.txt', output / '浏览器证书使用说明.txt')
    print(json.dumps(evidence), flush=True)


if __name__ == '__main__':
    main()
