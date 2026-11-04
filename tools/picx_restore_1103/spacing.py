"""Place each annotation close to its original anchor, keeping its frame with it."""

import math


def rect(n):
    return (n["x"], n["y"], n["x"] + n["width"], n["y"] + n["height"])


def union(boxes):
    return (
        min(b[0] for b in boxes),
        min(b[1] for b in boxes),
        max(b[2] for b in boxes),
        max(b[3] for b in boxes),
    )


def hit(a, b, pad=2):
    return (
        a[0] < b[2] + pad
        and b[0] < a[2] + pad
        and a[1] < b[3] + pad
        and b[1] < a[3] + pad
    )


def place(doc):
    ns = doc["nodes"]
    frames = [
        n for n in ns if n["kind"] == "rect" and n["width"] >= 40 and n["height"] >= 16
    ]
    groups = {}
    owned = set()

    def assign(key, n):
        assert n["id"] not in owned
        groups.setdefault(key, []).append(n)
        owned.add(n["id"])

    for n in ns:
        if n["kind"] != "value":
            continue
        x, y = n["x"] + n["width"] / 2, n["y"] + n["height"] / 2
        opts = [
            f
            for f in frames
            if f["x"] - 1 <= x <= f["x"] + f["width"] + 1
            and f["y"] - 1 <= y <= f["y"] + f["height"] + 1
        ]
        f = min(opts, key=lambda f: f["width"] * f["height"]) if opts else None
        key = f["id"] if f else n["id"]
        if f and f["id"] not in owned:
            assign(key, f)
        assign(key, n)
    for n in ns:
        if n["kind"] != "pipe" or n["stroke_width"] > 1.2:
            continue
        x, y = n["x"] + n["width"] / 2, n["y"] + n["height"] / 2
        opts = [
            f
            for f in frames
            if f["id"] in groups
            and f["x"] - 3 <= x <= f["x"] + f["width"] + 3
            and f["y"] - 2 <= y <= f["y"] + f["height"] + 2
            and n["width"] <= f["width"] + 5
        ]
        if opts:
            assign(opts[0]["id"], n)
    for n in ns:
        if n["kind"] == "text":
            assign(n["id"], n)
    occupied = []
    for n in ns:
        if n["id"] in owned:
            continue
        if n["kind"] == "pipe":
            for a, b in zip(n["points"], n["points"][1:]):
                r = n["stroke_width"] / 2
                occupied.append(
                    (
                        min(a["x"], b["x"]) - r,
                        min(a["y"], b["y"]) - r,
                        max(a["x"], b["x"]) + r,
                        max(a["y"], b["y"]) + r,
                    )
                )
        else:
            occupied.append(rect(n))
    shifts = []
    for key, members in groups.items():
        a = union([rect(n) for n in members])
        # Where native text extends beyond its frame or a neighbour's row, use the actual cell.
        vals = sorted(
            (n for n in members if n["kind"] == "value"), key=lambda n: n["y"]
        )
        if vals and members[0]["kind"] == "rect":
            f = members[0]
            lines = sorted(n["y"] for n in members if n["kind"] == "pipe")
            for i, n in enumerate(vals):
                left = f["x"] + 2
                right = f["x"] + f["width"] - 2
                top = (
                    f["y"] + 1
                    if i == 0
                    else (
                        (lines[i - 1] + 1)
                        if len(lines) == len(vals) - 1
                        else f["y"] + i * f["height"] / len(vals) + 1
                    )
                )
                bot = (
                    f["y"] + f["height"] - 1
                    if i == len(vals) - 1
                    else (
                        (lines[i] - 1)
                        if len(lines) == len(vals) - 1
                        else f["y"] + (i + 1) * f["height"] / len(vals) - 1
                    )
                )
                n.update(x=left, y=top, width=right - left, height=max(8, bot - top))
        a = union([rect(n) for n in members])
        # Candidate positions are the edges of existing obstacles, plus the native anchor.
        xs = {0, 2 - a[0], doc["width"] - 2 - a[2]}
        ys = {0, 2 - a[1], doc["height"] - 2 - a[3]}
        for l, t, r, b in occupied:
            if hit((a[0] - 125, a[1] - 125, a[2] + 125, a[3] + 125), (l, t, r, b)):
                xs.update((l - 3 - a[2], r + 3 - a[0]))
                ys.update((t - 3 - a[3], b + 3 - a[1]))
        offsets = sorted(
            ((x, y) for x in xs for y in ys),
            key=lambda p: (p[0] ** 2 + p[1] ** 2, abs(p[0]), p),
        )
        for dx, dy in offsets:
            proposed = (a[0] + dx, a[1] + dy, a[2] + dx, a[3] + dy)
            if (
                proposed[0] >= 0
                and proposed[1] >= 0
                and proposed[2] <= doc["width"]
                and proposed[3] <= doc["height"]
                and not any(hit(proposed, b) for b in occupied)
            ):
                break
        else:
            raise ValueError(("no room", doc["station"], key))
        for n in members:
            n["x"] += dx
            n["y"] += dy
            for pt in n["points"]:
                pt["x"] += dx
                pt["y"] += dy
        occupied.append(proposed)
        if abs(dx) + abs(dy) > 0.01:
            shifts.append([doc["station"], key, round(dx, 2), round(dy, 2)])
    return shifts
