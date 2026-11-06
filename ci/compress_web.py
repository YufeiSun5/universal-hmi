"""Build deterministic gzip siblings for static Web downloads, never API data."""
import gzip
from pathlib import Path

EXTENSIONS = {'.js', '.mjs', '.wasm', '.css', '.json', '.ttf', '.otf', '.svg'}


def compress_web(folder, verify_only=False):
    for source in sorted(Path(folder).rglob('*')):
        if not source.is_file() or source.suffix not in EXTENSIONS or source.name == 'build-manifest.json':
            continue
        target = source.with_name(source.name + '.gz')
        original = source.read_bytes()
        if verify_only:
            if target.exists() and gzip.decompress(target.read_bytes()) != original:
                raise ValueError(f'Stale compressed resource: {source}')
            continue
        packed = gzip.compress(original, compresslevel=9, mtime=0)
        if len(original) >= 1024 and len(packed) < len(original) * .95:
            target.write_bytes(packed)
        elif target.exists():
            target.unlink()
