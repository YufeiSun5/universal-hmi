"""Stage the offline GIS package beside a built Flutter Web entry.

Usage: python ci/stage_gis.py --site .local/gis-flight-demo/site-lod --web <web-build>
Run after each Flutter Web build; no backend, credentials or source COGs copied.
"""
import argparse
import hashlib
import json
import shutil
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / 'examples/gis-flight'
PRESENTATION_FILES = ('index.html', 'flight.js', 'flight.css', 'sea.js', 'celestial.js', 'tour.js',
                      'orbital-scene.js', 'moon-lroc-2k.jpg', 'satellite-v2.png', 'satellite-normal.png',
                      'stations.js', 'stations.css', 'stations.json',
                      'station-pin.png', 'THIRD_PARTY_NOTICES.txt')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def versioned_entry(text, hashes):
    for name in PRESENTATION_FILES:
        if name.endswith(('.js', '.css')):
            text = text.replace('"' + name + '"', '"' + name + '?v=' + hashes[name][:16] + '"')
    return text


def verify_staged(web, source_files):
    """Bind the shipped map to the same source inventory as Flutter/Go.

    Generated imagery directories may contain stale copies of presentation JS.
    Hashing those copies as artifacts alone would certify the wrong program.
    """
    target = Path(web) / 'gis'
    if not target.exists():
        return  # Builds without the optional offline imagery remain supported.
    record = json.loads((target / 'gis-manifest.json').read_text('utf-8'))
    hashes = record['presentation_sources']
    if set(hashes) != set(PRESENTATION_FILES):
        raise ValueError('Incomplete GIS presentation provenance')
    for name, expected in hashes.items():
        source = 'examples/gis-flight/' + name
        if source_files.get(source) != expected:
            raise ValueError(f'GIS does not match release source: {name}')
        if name != 'index.html' and digest(target / name) != expected:
            raise ValueError(f'Stale GIS presentation: {name}')
    original = (target / 'index.source.html').read_bytes()
    if hashlib.sha256(original).hexdigest() != hashes['index.html']:
        raise ValueError('GIS entry source does not match release')
    expected_html = versioned_entry(original.decode('utf-8'), hashes)
    for name in ('index.html', 'map.html'):
        if (target / name).read_bytes().decode('utf-8') != expected_html:
            raise ValueError(f'GIS entry does not reference current scripts: {name}')


def stage(site: Path, web: Path):
    site, web = site.resolve(), web.resolve()
    target = web / 'gis'
    if site == target or site.is_relative_to(web) or web.is_relative_to(site):
        raise ValueError('GIS source and Web output must be separate directories')
    if not (web / 'flutter_bootstrap.js').is_file():
        raise ValueError('Build Flutter Web first')
    for name in PRESENTATION_FILES:
        if not (SOURCE / name).is_file():
            raise ValueError(f'Missing GIS presentation source: {name}')
    for name in ('imagery/manifest.json', 'vendor/cesium/Cesium.js', 'vendor/cesium/LICENSE.md'):
        if not (site / name).is_file():
            raise ValueError(f'Missing GIS resource: {name}')
    manifest = json.loads((site / 'imagery/manifest.json').read_text('utf-8'))
    for layer in manifest['layers']:
        if len(list((site / 'imagery' / layer['id']).rglob('*.webp'))) != layer['tileCount']:
            raise ValueError(f"Incomplete tiles: {layer['id']}")
    # Update only this owned subdirectory. No destructive cleanup of Web output.
    target.mkdir(parents=True, exist_ok=True)
    hashes = {name: digest(SOURCE / name) for name in PRESENTATION_FILES}
    for name in PRESENTATION_FILES:
        shutil.copy2(SOURCE / name, target / name)
    # FileServer redirects index.html to a directory URL; KP intentionally serves
    # only regular files. A named entry works in both /gis/ and /kp/gis/.
    shutil.copy2(SOURCE / 'index.html', target / 'index.source.html')
    entry = versioned_entry((SOURCE / 'index.html').read_bytes().decode('utf-8'), hashes)
    for name in ('index.html', 'map.html'):
        (target / name).write_text(entry, encoding='utf-8', newline='')
    for name in ('imagery', 'vendor'):
        shutil.copytree(site / name, target / name, dirs_exist_ok=True)
    (target / 'gis-manifest.json').write_text(json.dumps({
        'schema': 1, 'presentation_sources': hashes,
    }, indent=2) + '\n', encoding='utf-8')
    verify_staged(web, {'examples/gis-flight/' + name: value for name, value in hashes.items()})
    print(f'Staged GIS at {target}; same-origin URL: gis/map.html')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--site', required=True, type=Path)
    parser.add_argument('--web', required=True, type=Path)
    args = parser.parse_args()
    stage(args.site, args.web)
