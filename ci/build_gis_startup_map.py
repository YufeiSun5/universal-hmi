"""Rebuild the first-view geographic image from existing local Sentinel tiles.

One-time asset authoring: Pillow 12.0.0; normal release builds copy the committed
WebP and provenance JSON and do not need Pillow or source imagery downloads.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
from PIL import Image


def build(site, output):
    zoom = 13
    bounds = [122.65, 39.42, 123.30, 40.02]
    west, south, east, north = bounds
    size = 256 * 2**zoom
    def px(lon): return (lon + 180) / 360 * size
    def py(lat): return (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * size
    x0, x1 = math.floor(px(west)/256), math.floor(px(east)/256)
    y0, y1 = math.floor(py(north)/256), math.floor(py(south)/256)
    mosaic = Image.new('RGBA', ((x1-x0+1)*256, (y1-y0+1)*256))
    hashes = {}
    for x in range(x0, x1+1):
        for y in range(y0, y1+1):
            relative = f'imagery/zhuanghe/{zoom}/{x}/{y}.webp'
            path = site / relative
            if not path.is_file():
                raise ValueError(f'Missing source tile: {relative}')
            hashes[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
            with Image.open(path) as tile:
                mosaic.paste(tile.convert('RGBA'), ((x-x0)*256, (y-y0)*256))
    width = 3072
    height = round(width * (north-south) / (east-west))
    mesh = []
    for top in range(0, height, 32):
        bottom = min(height, top+32)
        upper = py(north-(north-south)*top/height)-y0*256
        lower = py(north-(north-south)*bottom/height)-y0*256
        left, right = px(west)-x0*256, px(east)-x0*256
        mesh.append(((0,top,width,bottom), (left,upper,left,lower,right,lower,right,upper)))
    geographic = mosaic.transform((width,height), Image.Transform.MESH, mesh, Image.Resampling.BICUBIC)
    output.mkdir(parents=True, exist_ok=True)
    target = output/'startup-map.webp'
    geographic.save(target, 'WEBP', quality=82, method=6)
    (output/'startup-map.json').write_text(json.dumps({
        'bounds':bounds, 'width':width, 'height':height, 'zoom':zoom,
        'projection':'EPSG:4326', 'image':'startup-map.webp',
        'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),
        'source':'Existing local Copernicus Sentinel-2 imagery, 2025-09-29',
        'tiles':hashes,
    }, indent=2)+'\n', encoding='utf8')
    print(f'{target}: {target.stat().st_size} bytes, {width}x{height}, {len(hashes)} source tiles')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--site', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path('examples/gis-flight'))
    args = parser.parse_args()
    build(args.site, args.output)
