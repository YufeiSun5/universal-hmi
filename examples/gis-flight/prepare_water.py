"""Build a conservative, geographic sea mask from same-date Sentinel SCL.

Requires the same rasterio/numpy/Pillow environment as prepare.py. No invented
coastline or RGB blue threshold; only class 6 connected to the southern sea.
"""
import argparse
from collections import deque
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter
import rasterio
from rasterio.transform import from_bounds
from rasterio.warp import reproject, Resampling
from prepare import ROOT, download

BOUNDS = [122.45, 39.42, 123.50, 40.00]
SIZE = (2048, 1536)
IDS = ['S2B_51SVD_20250929_0_L2A', 'S2B_51SWD_20250929_0_L2A']
SOURCE_HASHES = ['14a13c8849d8e535825daebca28af875b6489013a70cb649b0b5f6bfecbd9d7a',
                 'c0b4a14e66158fced16b49160236fcbb0a79fa28eb7c0e9fff469f2702641f93']


def build(out, cache):
    w, h = SIZE
    transform = from_bounds(*BOUNDS, w, h)
    classes = np.zeros((h, w), dtype='uint8')
    sources = []
    for item_id in IDS:
        meta = cache / (item_id + '.json')
        download(f'https://earth-search.aws.element84.com/v1/collections/sentinel-2-l2a/items/{item_id}', meta)
        data = json.loads(meta.read_text('utf-8'))
        url = data['assets']['scl']['href']
        path = cache / (item_id + '-SCL.tif')
        download(url, path)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != SOURCE_HASHES[IDS.index(item_id)]:
            raise ValueError(f'SCL source integrity mismatch: {item_id}')
        dest = np.zeros_like(classes)
        with rasterio.open(path) as src:
            reproject(rasterio.band(src, 1), dest, src_transform=src.transform,
                      src_crs=src.crs, dst_transform=transform, dst_crs='EPSG:4326',
                      resampling=Resampling.nearest, dst_nodata=0)
        # Only valid coverage replaces an overlapping scene.
        classes[dest != 0] = dest[dest != 0]
        sources.append({'id': item_id, 'url': url,
                        'sha256': digest})
    water = classes == 6
    # Flood from south edge, excluding detached reservoirs / aquaculture ponds.
    sea = np.zeros_like(water)
    queue = deque()
    for x in np.flatnonzero(water[-1]):
        sea[-1, x] = True
        queue.append((h - 1, int(x)))
    while queue:
        y, x = queue.popleft()
        for yy, xx in ((y-1,x), (y+1,x), (y,x-1), (y,x+1)):
            if 0 <= yy < h and 0 <= xx < w and water[yy, xx] and not sea[yy, xx]:
                sea[yy, xx] = True
                queue.append((yy, xx))
    raw = Image.fromarray((sea * 255).astype('uint8'))
    # Retreat ~150m from islands/shore then soften. Multiplication by the
    # original sea mask guarantees that blur never paints classified land.
    eroded = raw.filter(ImageFilter.MinFilter(9))
    soft = np.asarray(eroded.filter(ImageFilter.GaussianBlur(5)), dtype='float32') / 255
    yy, xx = np.mgrid[:h, :w]
    edge = np.minimum.reduce([xx/(w*.035), (w-1-xx)/(w*.035), yy/(h*.035), (h-1-yy)/(h*.035)])
    mask = (soft * sea * np.clip(edge, 0, 1) * 255).astype('uint8')
    folder = out / 'imagery'
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / 'zhuanghe-sea-mask.png'
    Image.fromarray(mask).save(target, optimize=True)
    # Seamless, wind-aligned multiscale normals, made once offline. Runtime
    # samples this small texture twice instead of evaluating noise per pixel.
    rng = np.random.default_rng(91357)
    n = 512
    fx, fy = np.meshgrid(np.fft.fftfreq(n), np.fft.fftfreq(n))
    radial = np.sqrt((fx * .6)**2 + (fy * 1.8)**2)
    spectrum = np.exp(-((radial-.055)/.04)**2) + .25*np.exp(-((radial-.17)/.07)**2)
    height = np.fft.ifft2(np.fft.fft2(rng.normal(size=(n,n))) * spectrum).real
    gx = np.roll(height,-1,1) - np.roll(height,1,1)
    gy = np.roll(height,-1,0) - np.roll(height,1,0)
    scale = 2.8 * max(gx.std(), gy.std())
    normals = np.stack((np.clip(.5+gx/scale*.5,0,1), np.clip(.5+gy/scale*.5,0,1), np.ones_like(gx)),axis=-1)
    normal_path = folder / 'sea-normal.png'
    Image.fromarray((normals*255).astype('uint8')).save(normal_path, optimize=True)
    record = {'bounds': BOUNDS, 'dimensions': SIZE, 'url': 'imagery/zhuanghe-sea-mask.png',
              'acquired': '2025-09-29', 'sourceResolutionMeters': 20,
              'processing': 'SCL class 6, nearest geographic reprojection; south-edge connected sea only; conservative shore retreat and feather; zero on non-water pixels',
              'purpose': 'Decorative water shading only; not a surveyed coastline or live sea state',
              'sources': sources, 'sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
              'normalUrl': 'imagery/sea-normal.png',
              'normalSha256': hashlib.sha256(normal_path.read_bytes()).hexdigest(),
              'waterPixels': int(np.count_nonzero(mask)),
              'nonWaterLeakPixels': int(np.count_nonzero(mask[~water]))}
    (folder / 'water-source.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
    print(json.dumps({'bytes': target.stat().st_size, **record}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT / '.local/gis-flight-demo/site-lod')
    args = parser.parse_args()
    build(args.output, ROOT / '.local/gis-flight-demo/cache')
