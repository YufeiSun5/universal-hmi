"""Read-only runtime HTTP and package consistency checks against the demo server."""
import argparse
import json
import hashlib
import urllib.request
import urllib.error
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--site', type=Path, required=True)
p.add_argument('--base', default='http://127.0.0.1:18149')
a = p.parse_args()
checks = []
def request(path, expected=200, method='GET', headers=None):
    req = urllib.request.Request(a.base + path, method=method, headers=headers or {})
    try:
        response = urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        status, body, hs = response.status, response.read(), response.headers
    assert status == expected, (path, status, expected)
    checks.append({'path':path, 'method':method, 'expected':expected, 'actual':status})
    return body, hs

_, headers = request('/')
assert "connect-src 'self'" in headers['Content-Security-Policy']
assert "'unsafe-eval'" not in headers['Content-Security-Policy']
request('/', method='HEAD')
request('/', 405, method='POST')
request('/', 403, headers={'Host':'untrusted.invalid'})
request('/imagery/', 404)
request('/missing-resource.webp', 404)
request('/health')
data, _ = request('/imagery/manifest.json')
manifest = json.loads(data)
assert manifest == json.loads((a.site/'imagery/manifest.json').read_text('utf-8'))
for layer in manifest['layers']:
    tiles = list((a.site/'imagery'/layer['id']).rglob('*.webp'))
    assert len(tiles) == layer['tileCount']
    for z in range(layer['minZoom'], layer['maxZoom']+1):
        tile = next((a.site/'imagery'/layer['id']/str(z)).rglob('*.webp'))
        image, _ = request('/' + tile.relative_to(a.site).as_posix())
        assert image[:4] == b'RIFF' and image[8:12] == b'WEBP'
for name in ('stations.js','stations.css','stations.json','station-pin.png','flight.js','sea.js','flight.css','embed.html','embed.js','vendor/cesium/Cesium.js','vendor/cesium/LICENSE.md','imagery/earth-portrait.jpg','imagery/earth-low.jpg','imagery/earth-source.json','imagery/region-source.json'):
    request('/' + name)
region = json.loads((a.site/'imagery/region-source.json').read_text('utf-8'))
image, _ = request('/' + region['url'])
assert hashlib.sha256(image).hexdigest() == region['outputSha256']
from PIL import Image
with Image.open(a.site/region['url']) as im:
    assert list(im.size) == region['outputDimensions'] == [2048,2048]
    assert im.mode == 'RGBA' and im.getextrema()[3] == (0,255)
water_bytes, _ = request('/imagery/water-source.json')
water = json.loads(water_bytes)
assert water['nonWaterLeakPixels'] == 0
for url, digest in [(water['url'],water['sha256']), (water['normalUrl'],water['normalSha256'])]:
    data, _ = request('/'+url)
    assert hashlib.sha256(data).hexdigest() == digest
with Image.open(a.site/water['url']) as mask:
    assert list(mask.size) == water['dimensions'] and mask.mode == 'L'
    west,south,east,north = water['bounds']
    for lon,lat,expected in [(122.967,39.681,0), (122.9,39.8,0), (123.08,39.62,255)]:
        pixel=(int((lon-west)/(east-west)*mask.width),int((north-lat)/(north-south)*mask.height))
        assert mask.getpixel(pixel) == expected, (lon,lat)
print(json.dumps({'passed':True,'checks':checks,'layers':manifest['layers']}, ensure_ascii=False, indent=2))
