"""Rasterize the small native vector primitives as a movable device asset."""

import io, struct, re, math, base64
from PIL import Image, ImageDraw


def device(d, parts, b, typ):
    x, y, w, h = b
    scale = 3
    im = Image.new("RGBA", (max(1, round(w * scale)), max(1, round(h * scale))))
    for o in parts:
        k = o["object"].rstrip("0123456789")
        if k in ("Group", "PictureWrap", "GeneralLights"):
            continue
        r = d[o["strings"][0]["end"] : o["end"]]
        positions = []
        for m in re.finditer(b"\x01\x00\x01\x00\x00\x00", r):
            a = m.end()
            if k in ("Rect", "Ellipse", "RoundRect"):
                if a + 16 > len(r):
                    continue
                xx, yy, ww, hh = struct.unpack_from("<4f", r, a)
                pts = [(xx, yy), (xx + ww, yy + hh)]
                if not 0.001 < ww < 350 or not 0.001 < hh < 350:
                    continue
            else:
                if k not in (
                    "Polygon",
                    "ClosedBezier",
                    "ClosedSpline",
                    "Line",
                    "Polyline",
                ):
                    raise ValueError(k)
                if k == "Line":
                    pts = list(struct.iter_unpack("<2f", r[a : a + 16]))
                else:
                    if a + 8 > len(r):
                        continue
                    one, n = struct.unpack_from("<2I", r, a)
                    if one != 1 or not 2 <= n <= 400 or a + 8 + n * 8 > len(r):
                        continue
                    pts = list(struct.iter_unpack("<2f", r[a + 8 : a + 8 + 8 * n]))
            if pts and all(
                math.isfinite(u)
                and math.isfinite(v)
                and x - w <= u <= x + 2 * w
                and y - h <= v <= y + 2 * h
                for u, v in pts
            ):
                positions.append((a, pts))
        if not positions:
            raise ValueError(("native component geometry", typ, o["object"], b))
        a, pts = positions[-1]
        pts = [((u - x) * scale, (v - y) * scale) for u, v in pts]
        if k == "ClosedBezier" and (len(pts) - 1) % 3 == 0:
            path = [pts[0]]
            for i in range(0, len(pts) - 1, 3):
                for step in range(1, 10):
                    t = step / 9
                    q = 1 - t
                    path.append(
                        tuple(
                            q**3 * pts[i][c]
                            + 3 * q * q * t * pts[i + 1][c]
                            + 3 * q * t * t * pts[i + 2][c]
                            + t**3 * pts[i + 3][c]
                            for c in (0, 1)
                        )
                    )
            pts = path
        mask = Image.new("L", im.size)
        draw = ImageDraw.Draw(mask)
        if k == "Ellipse":
            draw.ellipse(pts, fill=255)
        elif k == "RoundRect":
            draw.rounded_rectangle(
                pts, radius=min(3, max(0.1, (pts[1][1] - pts[0][1]) / 3)), fill=255
            )
        elif k == "Rect":
            draw.rectangle(pts, fill=255)
        elif k in ("Line", "Polyline"):
            draw.line(pts, fill=255, width=2)
        else:
            draw.polygon(pts, fill=255)
        trans = re.search(b"\x07\x00\x01\x00\x00\x00", r[:80])
        if trans:
            angle, _, _, _ = struct.unpack_from("<4f", r, trans.end())
            if abs(angle) > 0.05:
                center = (
                    (min(u for u, v in pts) + max(u for u, v in pts)) / 2,
                    (min(v for u, v in pts) + max(v for u, v in pts)) / 2,
                )
                mask = mask.rotate(
                    -angle, center=center, resample=Image.Resampling.BILINEAR
                )
        bb = mask.getbbox()
        if not bb:
            continue
        fill = r.find(b"\x02\x00\x01\x00\x00\x00", 475)
        stops = []
        if fill >= 0 and r[fill + 6 : fill + 10] == b"\x01\x00\x00\x00":
            stops = [(0, tuple(r[fill + 14 : fill + 17][::-1]))]
        elif fill >= 0:
            for q in range(fill + 10, min(a - 12, fill + 90)):
                cnt, n = struct.unpack_from("<2I", r, q)
                if not 2 <= cnt == n <= 40 or q + 8 + 8 * n > a:
                    continue
                cl = [
                    (
                        struct.unpack_from("<f", r, q + 12 + j * 8)[0],
                        tuple(r[q + 8 + j * 8 : q + 11 + j * 8][::-1]),
                    )
                    for j in range(n)
                ]
                if (
                    all(0 <= t <= 1 for t, c in cl)
                    and cl[0][0] == 0
                    and all(t <= u for (t, _), (u, _) in zip(cl, cl[1:]))
                ):
                    stops = cl
                    break
            if not stops:
                j = r.find(b"\x00\x00\x00\x00\x01\x00\x00\x00", fill + 28, fill + 65)
                if j >= 0:
                    stops = [
                        (0, tuple(r[j + 8 : j + 11][::-1])),
                        (1, tuple(r[j + 12 : j + 15][::-1])),
                    ]
        if not stops:
            stops = [(0, (88, 103, 114))]
        stops = [(-1, stops[0][1]), *stops, (2, stops[-1][1])]
        layer = Image.new("RGBA", im.size)
        g = ImageDraw.Draw(layer)
        for xx in range(bb[0], bb[2]):
            t = (xx - bb[0]) / max(1, bb[2] - bb[0] - 1)
            (lo, c), (hi, f) = next(
                (s1, s2)
                for s1, s2 in zip(stops, stops[1:])
                if s1[0] <= t <= s2[0] and s2[0] > s1[0]
            )
            g.line(
                (xx, bb[1], xx, bb[3]),
                fill=tuple(
                    round(v + (u - v) * (t - lo) / (hi - lo)) for v, u in zip(c, f)
                )
                + (255,),
            )
        im.paste(layer, (0, 0), mask)
    f = io.BytesIO()
    im.save(f, "PNG")
    return base64.b64encode(f.getvalue()).decode()
