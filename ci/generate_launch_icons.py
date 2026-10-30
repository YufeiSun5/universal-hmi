"""Export platform icon formats from the approved generated Universal HMI master.

No drawing: the original RGBA design is only resized or placed on a maskable
background. Pillow is required, as in the existing asset generation workflow.
"""
from pathlib import Path
import base64
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'app/assets/branding/universal_hmi.png'
OUT = ROOT / 'packaging/icons'
SIZES = (16, 24, 32, 48, 64, 128, 256)


def resize(image, size):
    return image.resize((size, size), Image.Resampling.LANCZOS)


def svg(image):
    import io
    data = io.BytesIO()
    image.save(data, format='PNG')
    encoded = base64.b64encode(data.getvalue()).decode('ascii')
    return ('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
            'viewBox="0 0 512 512"><image width="512" height="512" '
            f'xlink:href="data:image/png;base64,{encoded}"/></svg>\n')


def main():
    image = Image.open(SOURCE).convert('RGBA')
    assert image.width == image.height and image.getextrema()[3][0] == 0
    OUT.mkdir(parents=True, exist_ok=True)
    desktop = resize(image, 256)
    for name in ('runtime', 'developer'):
        desktop.save(OUT / f'{name}.png')
        desktop.save(OUT / f'{name}.ico', sizes=[(s, s) for s in SIZES])
        (OUT / f'{name}.svg').write_text(svg(resize(image, 512)), encoding='utf-8')
    desktop.save(ROOT / 'app/windows/runner/resources/app_icon.ico', sizes=[(s, s) for s in SIZES])
    (ROOT / 'packaging/universal-hmi.svg').write_text(svg(resize(image, 512)), encoding='utf-8')
    for size in (16, 32, 64, 128, 256, 512, 1024):
        resize(image, size).save(ROOT / f'app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png')
    resize(image, 32).save(ROOT / 'app/web/favicon.png')
    for size in (192, 512):
        resize(image, size).save(ROOT / f'app/web/icons/Icon-{size}.png')
        # The entire square design fits inside the central 80%-diameter circle.
        # This keeps the complete mark safe through every PWA mask shape.
        maskable = Image.new('RGBA', (size, size), '#071633')
        inner = resize(image, round(size * .56))
        maskable.alpha_composite(inner, ((size-inner.width)//2, (size-inner.height)//2))
        maskable.convert('RGB').save(ROOT / f'app/web/icons/Icon-maskable-{size}.png')
    print('Exported Windows ICO, launch icons, Web/PWA, macOS and Linux SVG wrapper from', SOURCE)


if __name__ == '__main__':
    main()
