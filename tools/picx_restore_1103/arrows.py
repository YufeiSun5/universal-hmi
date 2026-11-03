"""Put each on-pipe direction mark on the matching native cylinder segment."""

import math, bisect, collections, copy


def apply(doc):
    ns = doc["nodes"]
    hosts = {}
    parts = collections.defaultdict(list)
    used = set()
    for n in ns:
        if n.get("pipe_style") != "cylinder":
            continue
        xy = [complex(p["x"], p["y"]) for p in n["points"]]
        ds = [0]
        for a, b in zip(xy, xy[1:]):
            ds.append(ds[-1] + abs(b - a))
        hosts[n["id"]] = (n, xy, ds)
    for n in ns:
        if not n.get("arrow"):
            continue
        n.update(arrow_mode="single", arrow_animate=False)
        a, b = (complex(p["x"], p["y"]) for p in n["points"])
        options = []
        if abs(a - b) < 1:
            continue
        for key, (h, xy, ds) in hosts.items():
            for j, (s, t) in enumerate(zip(xy, xy[1:])):
                if abs(t - s) < 1:
                    continue
                u = (t - s) / abs(t - s)
                x = (a - s) / u
                y = (b - s) / u
                if abs(((b - a) / abs(b - a) / u).imag) > 0.12:
                    continue
                error = max(abs(x.imag), abs(y.imag))
                if error > h["stroke_width"] / 2 + 1:
                    continue
                lo, hi = sorted([x.real, y.real])
                lo = max(0, lo)
                hi = min(abs(t - s), hi)
                if hi - lo < max(10, abs(b - a) * 0.65):
                    continue
                options.append((error, key, ds[j] + lo, ds[j] + hi, y.real < x.real))
        for _, key, l, r, rev in sorted(options):
            if any(l < end and begin < r for begin, end, _, _ in parts[key]):
                continue
            parts[key].append((l, r, rev, n["id"]))
            used.add(n["id"])
            break
    out = []
    for n in ns:
        key = n["id"]
        if key in used:
            continue
        if not parts.get(key):
            out.append(n)
            continue
        h, xy, ds = hosts[key]
        intervals = []
        prev = 0
        for l, r, rev, aid in sorted(parts[key]):
            if l - prev > 0.001:
                intervals.append((prev, l, False, None))
            intervals.append((l, r, rev, aid))
            prev = r
        if ds[-1] - prev > 0.001:
            intervals.append((prev, ds[-1], False, None))

        def pos(at):
            j = max(0, min(len(ds) - 2, bisect.bisect_right(ds, at) - 1))
            return (
                xy[j]
                if ds[j + 1] == ds[j]
                else xy[j] + (xy[j + 1] - xy[j]) * (at - ds[j]) / (ds[j + 1] - ds[j])
            )

        plain = 0
        for l, r, rev, aid in intervals:
            points = (
                [pos(l)]
                + [p for p, d in zip(xy, ds) if l + 0.001 < d < r - 0.001]
                + [pos(r)]
            )
            s = copy.deepcopy(n)
            xs = [v.real for v in points]
            ys = [v.imag for v in points]
            s.update(
                id=aid or (key if plain == 0 else key + "-p" + str(plain)),
                points=[dict(x=p.real, y=p.imag) for p in points],
                x=min(xs),
                y=min(ys),
                width=max(xs) - min(xs),
                height=max(ys) - min(ys),
                arrow=bool(aid),
            )
            if aid:
                s.update(arrow_mode="single", arrow_reverse=rev, arrow_animate=False)
            else:
                plain += 1
            out.append(s)
        if not plain:
            # The source pipe is fully occupied by a direction marker.
            assert len(intervals) == 1
            out[-1]["id"] = key
    doc["nodes"] = out
    assert len(set(n["id"] for n in out)) == len(out)
    return len(used)
