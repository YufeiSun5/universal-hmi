"""Decode source objects in drawing order; no station template or inferred piping."""

import io, re, sys, math, base64, struct, collections
from pathlib import Path
from PIL import Image

sys.path.insert(0, str(Path("tools").resolve()))
import picx_refresh as p
from parts import device


def make(st, pic, d):
    ss = p.strings_from(d)
    oo = p.objects_from(ss)
    text_items = p.native_text_rows(d, oo)
    texts = {o["offset"]: (t, b) for o, t, b in text_items}
    u = lambda off: struct.unpack_from("<I", d, off)[0]
    box = lambda off: list(struct.unpack_from("<4f", d, off))
    resources = {}
    for i, s in enumerate(ss):
        if s["text"] in ("image/png", "image/gif", "image/jpeg", "image/bmp"):
            key = ss[i - 1]["text"]
            im = Image.open(io.BytesIO(d[s["end"] + 4 :]))
            resources[key] = im.convert("RGBA")
    nodes = []
    assets = {}
    audit = []
    readings = []
    warnings = []
    for i, o in enumerate(oo):
        o["end"] = (
            oo[i + 1]["offset"]
            if i + 1 < len(oo)
            else max(
                o["offset"] + 1,
                next(
                    (
                        s["offset"]
                        for s in ss
                        if s["offset"] > o["offset"] and s["text"] == "treeSelect"
                    ),
                    len(d),
                ),
            )
        )

    def group(o):
        start = o["offset"]
        end = o["end"]
        b = d[start:end]
        m = list(re.finditer(rb"\xff\xfe\xff\x00\x12\x00\x00\x00", b))
        for v in reversed(m):
            s = start + v.end()
            if d[s + 44 : s + 48] == b"\x02\x00\x03\x00":
                return box(s + 20), u(s + 48)
            if d[s + 44 : s + 46] == b"\x03\x00":
                return box(s + 20), u(s + 46)
        raise ValueError(("group", st, o["object"]))

    def walk(i, wrapped=None):
        o = oo[i]
        name = o["object"]
        k = name.rstrip("0123456789")
        start = o["offset"]
        end = o["end"]
        raw = d[start:end]
        rid = "ks-" + name + "-" + str(i)
        rec = [st, pic, name, start, "", ""]
        audit.append(rec)

        def add(kind, b, **kw):
            x, y, w, h = b
            if not all(math.isfinite(f) and abs(f) < 20000 for f in b):
                raise ValueError((st, name, b))
            if x >= 1750 or y >= 800 or x + w <= 0 or y + h <= 0:
                rec[4] = "主图边界外"
                return
            x = max(0, x)
            y = max(0, y)
            w = min(max(8, w), 1750 - x)
            h = min(max(8, h), 800 - y)
            if w < 8 or h < 8:
                rec[4] = "主图边界外"
                return
            n = p.text_node(rid, "", x, y, w, h)
            n.update(kind=kind, **kw)
            nodes.append(n)
            rec[4] = "画面节点"
            rec[5] = rid
            return n

        if k in ("Group", "PictureWrap", "GeneralLights"):
            b, c = group(o)
            assert c < 1000
            # Exclude the entire separate native action-button groups, including bevels.
            if (
                k == "Group"
                and 1400 < b[0] < 1650
                and 0 <= b[1] < 60
                and 70 < b[2] < 110
                and 20 < b[3] < 46
                and any(
                    v[0]["offset"] >= start
                    and v[0]["offset"] < oo[min(i + 13, len(oo) - 1)]["offset"]
                    and v[1] in ("设备操作", "参数设定")
                    and b[0] <= v[2][0] <= b[0] + b[2]
                    for v in text_items
                )
            ):
                wrapped = "excluded-operation"
                rec[4:] = ["按要求去掉操作入口", ""]

            children = wrapped
            if not children and k == "PictureWrap":
                words = [s["text"] for s in o["strings"]]
                typ = next(
                    (v for v in words if v in ("补水泵", "循环泵", "电磁阀")), None
                )
                if typ:
                    n = add(
                        "symbol",
                        b,
                        symbol={
                            "补水泵": "monitor_pump",
                            "循环泵": "monitor_pump",
                            "电磁阀": "monitor_valve",
                        }[typ],
                        label=typ,
                    )
                    children = rid
                elif "B_LightState" in words:
                    n = add(
                        "ellipse",
                        b,
                        fill="#B9C3CA",
                        color="#5D6D78",
                        label="状态灯（无实时状态）",
                    )
                    children = rid
                    # The native light model serializes owner properties after its last path.
                    last = next(
                        j
                        for j in range(i + 1, min(i + 40, len(oo)))
                        if oo[j]["object"].startswith("ClosedSpline")
                        and any(v["text"] == "LightOpen" for v in oo[j]["strings"])
                    )
                    for part in oo[i + 1 : last + 1]:
                        audit.append(
                            [st, pic, part["object"], part["offset"], "组合部件", rid]
                        )
                    return last + 1
            if wrapped:
                rec[4:] = (
                    ["按要求去掉操作入口", ""]
                    if wrapped == "excluded-operation"
                    else ["组合部件", wrapped]
                )
            elif not rec[4]:
                rec[4] = "原图容器"
            j = i + 1
            for _ in range(c):
                j = walk(j, children)
            if not wrapped and k == "PictureWrap" and typ and n:
                a = "art-" + str(i)
                assets[a] = dict(
                    name=typ, mime="image/png", data=device(d, oo[i + 1 : j], b, typ)
                )
                n.update(kind="image", image=a)
                n.pop("symbol", None)
            return j
        if wrapped:
            rec[4:] = (
                ["按要求去掉操作入口", ""]
                if wrapped == "excluded-operation"
                else ["组合部件", wrapped]
            )
            return i + 1
        tail = re.search(
            rb"(?:\x01\x00\x00\x00)?(?:.\x80|\xff\xff\x00\x00..Ckx[A-Za-z0-9_]+)\xff\xff....$",
            raw,
            re.S,
        )
        t = start + tail.start() if tail else end
        if k == "Text":
            if start not in texts:
                raise ValueError(("unlocated text", st, name))
            txt, b = texts[start]
            num = o["numeric"]
            if num:
                n = add(
                    "value",
                    b,
                    unit_override=re.sub(r"^[#.]+", "", txt),
                    show_unit=True,
                    decimals=1 if "." not in txt else len(re.search(r"\.(#+)", txt)[1]),
                    label=" / ".join(
                        a["path"].removeprefix(p.LOCAL) for a in o["bindings"]
                    ),
                    font_size=14,
                )
                if n:
                    readings.append((o, n))
            else:
                add(
                    "text",
                    b,
                    text=p.display_text(txt),
                    font_size=min(22, max(12, b[3] * 0.69)),
                    color="#BC252D" if re.search(r"\d#.*泵", txt) else "#283B46",
                )
        elif k == "Image":
            s = next((v for v in o["strings"][1:] if v["text"] in resources), None)
            if not s:
                raise ValueError(("image", st, name))
            b = box(s["offset"] - 62)
            a = "img-" + p.digest(s["text"].encode())[:14]
            n = add("image", b, image=a)
            if n and a not in assets:
                im = resources[s["text"]].copy()
                im.thumbnail(
                    (max(96, round(b[2] * 2)), max(96, round(b[3] * 2))),
                    Image.Resampling.LANCZOS,
                )
                f = io.BytesIO()
                im.save(f, "PNG")
                assets[a] = dict(
                    name=s["text"],
                    mime="image/png",
                    data=base64.b64encode(f.getvalue()).decode(),
                )
        elif k in ("Pipe", "Line", "Polyline"):
            if k == "Pipe":
                m = list(re.finditer(rb"\xff\x01\x00\x00\x00", raw))
                pos = next(
                    start + v.end()
                    for v in reversed(m)
                    if 2 <= u(start + v.end()) <= 256
                    and start + v.end() + 4 + 8 * u(start + v.end()) < end
                    and 1 <= u(start + v.end() + 4 + 8 * u(start + v.end())) <= 32
                )
                count = u(pos)
                xy = struct.unpack_from("<" + "f" * count * 2, d, pos + 4)
                width = u(pos + 4 + 8 * count)
            elif k == "Line":
                xy = box(t - 16)
                width = 2
            else:
                count = next(n for n in range(2, 65) if u(t - 8 * n - 4) == n)
                xy = struct.unpack_from("<" + "f" * count * 2, d, t - 8 * count)
                width = 2
            angle = sx = 0
            sy = 1
            transform = re.search(
                b"\x07\x00\x01\x00\x00\x00",
                d[o["strings"][0]["end"] : o["strings"][0]["end"] + 75],
            )
            if transform:
                angle, _, sx, sy = struct.unpack_from(
                    "<4f", d, o["strings"][0]["end"] + transform.end()
                )
                cx = (max(xy[::2]) + min(xy[::2])) / 2
                cy = (max(xy[1::2]) + min(xy[1::2])) / 2
                ar = math.radians(angle)
                co = math.cos(ar)
                si = math.sin(ar)
                xy = [
                    v
                    for x, y in zip(xy[::2], xy[1::2])
                    for v in (
                        cx + (x - cx) * sx * co - (y - cy) * sy * si,
                        cy + (x - cx) * sx * si + (y - cy) * sy * co,
                    )
                ]
            pts = [
                dict(x=max(0, min(1750, x)), y=max(0, min(800, y)))
                for x, y in zip(xy[::2], xy[1::2])
            ]
            if all(y > 800 for y in xy[1::2]):
                rec[4] = "主图边界外"
                return i + 1
            x = min(v["x"] for v in pts)
            y = min(v["y"] for v in pts)
            w = max(v["x"] for v in pts) - x
            h = max(v["y"] for v in pts) - y
            n = p.text_node(rid, "", x, y, w, h)
            n.update(
                kind="pipe",
                points=pts,
                stroke_width=max(1, min(32, width)),
                color=(
                    "#C95251"
                    if y < 320
                    else "#5680BC" if y < 500 and max(xy[1::2]) < 510 else "#739DA4"
                ),
                pipe_style="cylinder" if k == "Pipe" else "solid",
            )
            if k != "Pipe":
                n.pop("pipe_style")
            else:
                n["color"] = "#" + d[pos - 50 : pos - 47][::-1].hex()
            if k == "Line":
                n.update(
                    color="#" + d[t - 27 : t - 24][::-1].hex(),
                    stroke_width=max(
                        1, min(32, struct.unpack_from("<f", d, t - 47)[0])
                    ),
                    arrow=u(t - 59) != 0,
                )
                if n["stroke_width"] <= 1:
                    n.update(color="#799DAC", arrow=False)
            if k == "Polyline":
                n["color"] = "#799DAC"
            nodes.append(n)
            rec[4:] = ["画面节点", rid]
        elif k in ("Rect", "RoundRect", "Ellipse"):
            b = box(t - (28 if k == "RoundRect" else 16))
            n = add(
                "ellipse" if k == "Ellipse" else "rect",
                b,
                color="#799DAC",
                fill="#EDF2F4",
            )
        else:
            raise ValueError(("unsupported leaf", st, name))
        return i + 1

    i = 0
    while i < len(oo):
        i = walk(i)
    key = "pic1103-" + p.digest(pic.encode())[:20]
    doc = dict(
        schema_version=1,
        id=key,
        revision=0,
        name=st + " · 工艺",
        station=st,
        width=1750,
        height=800,
        background=dict(
            type="linear", color="#F0F3F5", end_color="#D5DEE5", angle=45, opacity=1
        ),
        assets=assets,
        nodes=nodes,
    )
    return key, doc, audit, readings
