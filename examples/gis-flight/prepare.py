"""Build a self-hosted globe/XYZ imagery demo from fixed, public inputs.

Run with rasterio 1.4.3, numpy and Pillow available. No API key is used.
Downloaded and generated files live under .local/gis-flight-demo by default.
"""
import argparse
import base64
import hashlib
import json
import math
from pathlib import Path
import shutil
import tarfile
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parents[2]
CESIUM_URL = "https://registry.npmjs.org/cesium/-/cesium-1.127.0.tgz"
CESIUM_INTEGRITY = "MRGkPb3ClEkAI9viZxxdD3LCu7ydOzOKdJ6/iPtBx1GUsPCZNbgB0IH7wmhwgbxA5sjv4/a90+mvR9CoLP1PWQ=="
EARTH_URL = "https://svs.gsfc.nasa.gov/vis/a010000/a012500/a012564/frames/5400x2700_2x1_60p/world.topo.2004-08.png"
EARTH_SHA256 = "022c38f2a214274f9876770d5ad37cf0847c14ad0d85f12bc31f82f927afbe54"
REGION_URL = "https://assets.science.nasa.gov/content/dam/science/esd/eo/images/bmng/bmng-topography-bathymetry/august/world.topo.bathy.200408.3x21600x21600.D1.jpg"
REGION_SHA256 = "89bb1fb179220e226aacab885a763b81fee72cca6ab89ecdef87ef32961fe2b0"
REGION_BBOX = [108,25,138,55]
IDS = ["S2B_51SVD_20250929_0_L2A", "S2B_51TVE_20250929_0_L2A",
       "S2B_51SWD_20250929_0_L2A", "S2B_51TWE_20250929_0_L2A",
       "S2B_51SUD_20250929_0_L2A", "S2B_51TUE_20250929_0_L2A"]
BBOX = [122.45, 39.42, 123.50, 40.60]
DALIAN_BBOX = [121.30, 38.85, 123.65, 40.60]
RADIUS = 6378137
HALF_WORLD = math.pi * RADIUS


def download(url, path):
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {path.name}", flush=True)
    req = urllib.request.Request(url, headers={"User-Agent": "UniversalHMI-GIS-demo/1.0"})
    temp = path.with_suffix(path.suffix + ".part")
    with urllib.request.urlopen(req, timeout=120) as response, temp.open("wb") as target:
        shutil.copyfileobj(response, target)
    temp.replace(path)


def prepare_vendor(out, cache):
    archive = cache / "cesium-1.127.0.tgz"
    download(CESIUM_URL, archive)
    digest = base64.b64encode(hashlib.sha512(archive.read_bytes()).digest()).decode()
    if digest != CESIUM_INTEGRITY:
        raise ValueError("Cesium archive integrity mismatch")
    vendor = out / "vendor/cesium"
    vendor.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as bundle:
        for member in bundle:
            prefix = "package/Build/Cesium/"
            if member.isfile() and member.name.startswith(prefix):
                relative = Path(member.name[len(prefix):])
                dest = (vendor / relative).resolve()
                if not dest.is_relative_to(vendor.resolve()):
                    raise ValueError("Unexpected archive path")
                dest.parent.mkdir(parents=True, exist_ok=True)
                with bundle.extractfile(member) as source, dest.open("wb") as target:
                    shutil.copyfileobj(source, target)
            elif member.isfile() and Path(member.name).name in ("LICENSE.md", "ThirdParty.json"):
                (vendor / Path(member.name).name).write_bytes(bundle.extractfile(member).read())


def prepare_earth(out, cache):
    from PIL import Image, ImageFilter
    source = cache / 'nasa-blue-marble-200408.png'
    download(EARTH_URL, source)
    if hashlib.sha256(source.read_bytes()).hexdigest() != EARTH_SHA256:
        raise ValueError('NASA source integrity mismatch')
    image = Image.open(source).convert('RGB')
    folder = out / 'imagery'
    folder.mkdir(parents=True, exist_ok=True)
    image.resize((4096,2048),Image.Resampling.LANCZOS).save(folder/'earth-portrait.jpg',quality=92)
    image.resize((256,128),Image.Resampling.LANCZOS).filter(ImageFilter.GaussianBlur(1.2)).save(folder/'earth-low.jpg',quality=90)
    (folder/'earth-source.json').write_text(json.dumps({'name':'NASA Blue Marble Next Generation','acquired':'2004-08','source':EARTH_URL,'sha256':EARTH_SHA256,'credit':'NASA Earth Observatory / Reto Stockli','usage':'https://www.nasa.gov/nasa-brand-center/images-and-media/','processing':'4096x2048 portrait and blurred 256x128 background; decorative lighting, not real-time illumination'},indent=2),encoding='utf-8')


def scene(item_id, cache):
    meta = cache / f"{item_id}.json"
    download(f"https://earth-search.aws.element84.com/v1/collections/sentinel-2-l2a/items/{item_id}", meta)
    data = json.loads(meta.read_text())
    tif = cache / f"{item_id}.tif"
    download(data["assets"]["visual"]["href"], tif)
    return data, tif


def prepare_region(out, cache):
    """Offline crop of a pinned NASA 500m D1 tile (90E-180E, 0N-90N).

    Runtime gets only a 2048-square geographic texture, never the 69MB source.
    Feather alpha is geographic, so the same texture works in any viewport.
    """
    from PIL import Image
    import numpy as np
    source = cache / 'nasa-east-asia-200408.jpg'
    download(REGION_URL, source)
    if hashlib.sha256(source.read_bytes()).hexdigest() != REGION_SHA256:
        raise ValueError('NASA regional source integrity mismatch')
    # Only this fixed, hash-verified large scientific raster exceeds PIL's limit.
    limit = Image.MAX_IMAGE_PIXELS
    try:
        Image.MAX_IMAGE_PIXELS = 500_000_000
        with Image.open(source) as image:
            if image.size != (21600,21600):
                raise ValueError('Unexpected NASA D1 dimensions')
            w,s,e,n = REGION_BBOX
            box = (int((w-90)*240),int((90-n)*240),int((e-90)*240),int((90-s)*240))
            crop = image.crop(box).resize((2048,2048),Image.Resampling.LANCZOS).convert('RGB')
    finally:
        Image.MAX_IMAGE_PIXELS = limit
    axis = (np.arange(2048)+.5)/2048
    edge = np.minimum(axis,1-axis)
    alpha = np.clip(np.minimum(edge[:,None],edge[None,:])/.05,0,1)
    alpha = (alpha*alpha*(3-2*alpha)*255).astype('uint8')
    folder = out / 'imagery'
    folder.mkdir(parents=True, exist_ok=True)
    rgb = np.asarray(crop).astype('float32')
    # Restrained display grading for NASA's blue bathymetric ocean, to avoid
    # a bright-blue flash before the darker Sentinel sea. Geometry is unchanged.
    water = np.clip((rgb[:,:,2]-rgb[:,:,0]-8)/32,0,1)*np.clip((rgb[:,:,2]-rgb[:,:,1])/24,0,1)
    rgb *= 1-water[:,:,None]*np.array([.60,.50,.48],dtype='float32')
    Image.fromarray(np.dstack((np.clip(rgb,0,255).astype('uint8'),alpha))).save(folder/'liaodong.webp',quality=90,method=6)
    record = {'url':'imagery/liaodong.webp','bounds':REGION_BBOX,'featherMeters':170000,
              'name':'NASA Blue Marble with topography and bathymetry','acquired':'2004-08',
              'source':REGION_URL,'sha256':REGION_SHA256,'sourceDimensions':[21600,21600],
              'outputDimensions':[2048,2048],'outputSha256':hashlib.sha256((folder/'liaodong.webp').read_bytes()).hexdigest(),
              'sourceResolutionMeters':500,
              'processing':'D1 geographic crop, downsampled to 2048x2048 (about 1.6km latitude/pixel), 5% edge feather; blue-dominant ocean darkened for display continuity; historical composite, not live imagery',
              'credit':'NASA Earth Observatory / Reto Stockli',
              'usage':'https://www.nasa.gov/nasa-brand-center/images-and-media/'}
    (folder/'region-source.json').write_text(json.dumps(record,indent=2),encoding='utf-8')


def prepare_tiles(out, scenes, bbox, min_z, max_z, name, feather_m):
    import numpy as np
    import rasterio
    from rasterio.merge import merge
    from rasterio.vrt import WarpedVRT
    from rasterio.enums import Resampling
    from rasterio.warp import transform_bounds
    from PIL import Image
    from contextlib import ExitStack

    bounds = transform_bounds("EPSG:4326", "EPSG:3857", *bbox)
    tile_span = 2 * HALF_WORLD / 2**max_z
    x0 = math.floor((bounds[0] + HALF_WORLD) / tile_span)
    x1 = math.floor((bounds[2] + HALF_WORLD) / tile_span)
    y0 = math.floor((HALF_WORLD - bounds[3]) / tile_span)
    y1 = math.floor((HALF_WORLD - bounds[1]) / tile_span)
    snapped = (x0 * tile_span - HALF_WORLD, HALF_WORLD - (y1+1)*tile_span,
               (x1+1)*tile_span - HALF_WORLD, HALF_WORLD - y0*tile_span)
    print("Reprojecting Sentinel scenes and making local XYZ tiles", flush=True)
    with ExitStack() as stack:
        datasets = [stack.enter_context(rasterio.open(p)) for _, p in scenes]
        vrts = [stack.enter_context(WarpedVRT(d, crs="EPSG:3857", resampling=Resampling.bilinear)) for d in datasets]
        data, _ = merge(vrts, bounds=snapped, res=tile_span/256, nodata=0, indexes=[1,2,3])
    image = Image.fromarray(np.moveaxis(data, 0, -1), "RGB")
    # Full tiles are retained outside the requested footprint. The provider rectangle clips them.
    count = 0
    for z in range(min_z, max_z+1):
        divisor = 2**(max_z-z)
        left, top = x0//divisor, y0//divisor
        right, bottom = x1//divisor, y1//divisor
        for x in range(left, right+1):
            folder = out / "imagery" / name / str(z) / str(x)
            folder.mkdir(parents=True, exist_ok=True)
            for y in range(top, bottom+1):
                box = ((x*divisor-x0)*256, (y*divisor-y0)*256,
                       ((x+1)*divisor-x0)*256, ((y+1)*divisor-y0)*256)
                # Sample directly into 256px: a low-zoom tile can span >1G source
                # pixels outside our small AOI, so never allocate its full crop.
                tile = image.transform((256,256), Image.Transform.EXTENT, box,
                                       Image.Resampling.BICUBIC)
                # Feather each geographic footprint, so resolution zones blend
                # instead of exposing a hard rectangular edge during flight.
                span = tile_span * divisor
                xx = (x + (np.arange(256)+0.5)/256)*span - HALF_WORLD
                yy = HALF_WORLD - (y + (np.arange(256)+0.5)/256)*span
                dx = np.minimum(xx-bounds[0], bounds[2]-xx)
                dy = np.minimum(yy-bounds[1], bounds[3]-yy)
                alpha = (np.clip(np.minimum(dy[:,None], dx[None,:])/feather_m,0,1)*255).astype('uint8')
                rgb = np.asarray(tile)
                alpha[~np.any(rgb,axis=2)] = 0
                Image.fromarray(np.dstack((rgb,alpha)), 'RGBA').save(folder / f"{y}.webp", quality=88, method=4)
                count += 1
        print(f"{name} XYZ level {z} complete", flush=True)
    image.thumbnail((1400,1400))
    image.save(out / f"imagery/{name}-overview.jpg", quality=90)
    return count


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / ".local/gis-flight-demo/site")
    parser.add_argument("--skip-imagery", action="store_true")
    args = parser.parse_args()
    out = args.output.resolve()
    cache = ROOT / ".local/gis-flight-demo/cache"
    out.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    prepare_earth(out, cache)
    prepare_region(out, cache)
    from prepare_water import build as prepare_water
    prepare_water(out, cache)
    with ThreadPoolExecutor(max_workers=3) as pool:
        vendor = pool.submit(prepare_vendor, out, cache)
        futures = [pool.submit(scene, item_id, cache) for item_id in IDS] if not args.skip_imagery else []
        scenes = [f.result() for f in futures]
        vendor.result()
    if not args.skip_imagery:
        coarse_count = prepare_tiles(out, scenes, DALIAN_BBOX, 5, 10, 'dalian', 16000)
        # West Dalian scenes are irrelevant to the detailed Zhuanghe footprint.
        count = prepare_tiles(out, scenes[:4], BBOX, 7, 14, 'zhuanghe', 6500)
        manifest = {
            "schemaVersion": 1, "center": [122.967,39.681], "bounds": BBOX,
            "minZoom": 7, "maxZoom": 14, "tileCount": count,
            "layers": [
                {"id":"dalian", "bounds":DALIAN_BBOX, "minZoom":5, "maxZoom":10, "tileCount":coarse_count, "featherMeters":16000},
                {"id":"zhuanghe", "bounds":BBOX, "minZoom":7, "maxZoom":14, "tileCount":count, "featherMeters":6500},
            ],
            "acquired": "2025-09-29", "nativeResolutionMeters": 10,
            "credit": "Contains modified Copernicus Sentinel data (2025). L2A COGs: Element 84 / Earth Search.",
            "license": "https://sentinels.copernicus.eu/documents/247904/690755/Sentinel_Data_Legal_Notice",
            "processing": "True-color L2A visual COGs, bilinear reprojection EPSG:3857, WebP XYZ pyramids with feathered alpha; detailed Zhuanghe AOI and coarse Dalian surroundings. AOIs are rectangles, not administrative boundaries. No fabricated detail.",
            "scenes": [{"id": d["id"], "datetime": d["properties"]["datetime"],
                        "sceneCloudPercent": d["properties"]["eo:cloud_cover"],
                        "url": d["assets"]["visual"]["href"],
                        "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for d,p in scenes],
            "cesium": {"version": "1.127.0", "url": CESIUM_URL, "sha512": CESIUM_INTEGRITY},
        }
        (out / "imagery/manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    for name in ("index.html", "flight.css", "flight.js", "sea.js", "celestial.js", "tour.js", "orbital-scene.js", "moon-lroc-2k.jpg", "satellite-v2.png", "satellite-normal.png", "stations.js", "stations.css", "stations.json", "station-pin.png", "embed.html", "embed.js", "THIRD_PARTY_NOTICES.txt"):
        shutil.copy2(Path(__file__).parent / name, out / name)
    print(f"Built: {out}", flush=True)


if __name__ == "__main__":
    main()
