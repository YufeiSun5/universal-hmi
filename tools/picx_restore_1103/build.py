from layout import *
from zipfile import ZipFile
import csv, hashlib

out = Path("outputs/process-restore-1103")
out.mkdir(parents=True, exist_ok=True)
ref = Path("D:/DEV_D/KS_HELP/outputs/01a19edc_1103_KS_KIO")
md = (ref / "1103新点表_KS与KIO_按画面.md").read_text("utf-8-sig")
data = p.read(ref / "点表数据.json")
tags = collections.defaultdict(list)
tagdir = Path("D:/DEV_D/KS_HELP/output/庄河环海KIO点表解析_20261025")
sys.path.insert(0, str(tagdir))
import parse_kio

with ZipFile("D:/Users/SunYufei/Downloads/z庄河供热KIO1.113.zip") as kzip:
    tagbytes = kzip.read(next(n for n in kzip.namelist() if n.endswith("/Tag.db")))
    for t in parse_kio.tags_from(tagbytes):
        tags[t["name"]].append(t)
proof = {}
byname = {}
for sheet in data["sheets"]:
    for r in sheet["rows"]:
        assert ("\x60" + r["ks"] + "\x60" in md if r["ks"] else True) and (
            "\x60" + r["kio"] + "\x60" in md if r["kio"] else True
        )
        proof[(r["station"], r["object"], r["ks"])] = r
        if r["kio"]:
            byname.setdefault(r["ks"], r)
seed = p.read(Path(__file__).with_name("seed.json"))
before = {"import_identity": seed["import_identity"]}
types = seed["types"]
source = seed["source_map"]
ev = {(r["station"], r["object"]): r for r in seed["binding_evidence"]}
fmt = {
    "IOFloat": "FLOAT",
    "IOLong": "INT",
    "IOShort": "INT",
    "IOByte": "INT",
    "IODisc": "BOOL",
}
from spacing import place
from arrows import apply

shifts = []
rows = []
issues = []
objects = []
screens = []
bindings = []
variables = {}
summary = []
choices = []
candidatevars = {}


def csvout(name, head, rs):
    with (out / name).open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(head)
        w.writerows(rs)


with ZipFile("D:/Users/SunYufei/Downloads/1103pic.zip", metadata_encoding="gbk") as z:
    pairs = p.menu_pairs(p.strings_from(z.read("1103pic/工艺图菜单.picx")))
    for st, pic in pairs:
        d = z.read("1103pic/" + pic + ".picx")
        k, doc, a, values = make(st, pic, d)
        objects += a
        # Exhaustive cross-check independent of traversal: identical source offsets and text rectangles.
        os = p.objects_from(p.strings_from(d))
        native = p.native_text_rows(d, os)
        visible = [
            o["offset"]
            for o, t, (x, y, w, h) in native
            if o["numeric"] and x < 1750 and y < 800 and x + w > 0 and y + h > 0
        ]
        assert sorted(visible) == sorted(o["offset"] for o, n in values), (
            st,
            len(visible),
            len(values),
        )
        assert [o["offset"] for o in os] == [row[3] for row in a]
        assert not [
            row
            for row in a
            if row[4] == "组合部件" and row[2].startswith(("Text", "Image", "Pipe"))
        ], st
        assert len({n["id"] for n in doc["nodes"]}) == len(doc["nodes"])
        assert not any(n.get("text") in ("设备操作", "参数设定") for n in doc["nodes"])
        apply(doc)
        shifts += place(doc)
        screens.append(dict(key=k, document=doc))
        first = len(rows)
        for o, n in values:
            paths = [b["path"] for b in o["bindings"]]
            ks = paths[0] if len(paths) == 1 else ""
            r = proof.get((st, o["object"], ks), {})
            pr = r or byname.get(ks, {})
            if r.get("sourceHash"):
                assert r["sourceHash"] == p.digest(d)
            old = ev.get((st, o["object"]), {})
            name = pr.get("kio", "")
            status = pr.get("mapping", "")
            note = r.get("note", "")
            if not pr and old.get("paths") == paths and old.get("mapped_key"):
                name = old["kio"]
                status = old["status"]
                note = "逐对象旧XML或已确认路径补证"
            if not ks or p.REFERENCE.search(ks):
                why = "无唯一固定KS路径"
            elif re.search("跨站|重复|现场修正|待核|仍停用", note):
                why = "原图或报表冲突"
            elif not name:
                why = "缺少KIO映射"
            elif status == "同名候选，绑定待核":
                why = "仅同名待确认"
            elif status in (
                "用户确认同名",
                "用户确认下划线变量同名",
                "工程师明确映射",
                "XML明确绑定",
            ):
                why = "已接KIO"
            else:
                why = "待核依据"
            dtype = (
                types.get(name)
                or (
                    fmt.get(tags[name][0]["data_type"])
                    if len(tags[name]) == 1
                    else None
                )
                or (
                    "FLOAT"
                    if status in ("用户确认同名", "用户确认下划线变量同名")
                    else None
                )
            )
            if why in ("仅同名待确认", "已接KIO") and not dtype:
                why = "缺少采集类型"
            if name and dtype and why in ("仅同名待确认", "已接KIO"):
                vkey = "kio-" + p.digest(name.encode())[:20]
                v = dict(
                    key=vkey,
                    definition=dict(
                        name=name,
                        station="",
                        data_type=dtype,
                        source_type="mqtt",
                        source_id="kingio-confirmed",
                        source_path=name,
                        topic="",
                        unit="",
                        rw_mode="R",
                        writable=False,
                    ),
                )
                b = dict(
                    screen_key=k,
                    node_id=n["id"],
                    property="point_id",
                    operation="set",
                    variable_key=vkey,
                )
                if why == "已接KIO":
                    variables[vkey] = v
                    bindings.append(b)
                elif len(tags[name]) == 1:
                    choices.append(b)
                    candidatevars[vkey] = v
            n["label"] = r.get("label") or ks.removeprefix(p.LOCAL) or o["object"]
            row = [
                st,
                pic,
                o["object"],
                n["id"],
                ks,
                name,
                status,
                why,
                note,
                dtype or "",
                old.get("kio") or "",
            ]
            rows.append(row)
            if why != "已接KIO":
                issues.append(row)
        sub = rows[first:]
        summary.append(
            [
                st,
                pic,
                len(a),
                len(doc["nodes"]),
                len(sub),
                sum(r[7] == "已接KIO" for r in sub),
                sum(r[7] != "已接KIO" for r in sub),
                p.digest(d),
            ]
        )
bundle = dict(
    format="universal-hmi-process-bundle",
    version=1,
    screens=screens,
    bindings=bindings,
    variables=list(variables.values()),
)
request = dict(
    bundle=bundle,
    import_identity=before["import_identity"],
    screen_targets={s["key"]: dict(mode="create") for s in screens},
    variable_targets={key: dict(mode="match_existing") for key in variables},
    station_map=dict((st, st) for st, _ in pairs),
    create_stations=[],
    source_map=source,
)


def save(name, obj):
    (out / name).write_text(
        __import__("json").dumps(obj, ensure_ascii=False, separators=(",", ":")),
        encoding="utf8",
    )


save("31站工艺重建-KIO已核对.json", dict(retry_request=request))
verify = out / "check"
verify.mkdir(exist_ok=True)
for name, obj in [
    ("导入请求-匹配已有变量.json", dict(retry_request=request)),
    ("screens.json", bundle),
    ("confirmed-bindings.json", bundle),
]:
    (verify / name).write_text(
        __import__("json").dumps(obj, ensure_ascii=False, separators=(",", ":")),
        encoding="utf8",
    )
hdr = [
    "站区",
    "原图",
    "原图对象",
    "新画面节点",
    "原图KS路径",
    "点表KIO采集名",
    "对应依据",
    "处理结果",
    "备注",
    "匹配类型",
    "旧包KIO引用",
]
csvout("逐点连线.csv", hdr, rows)
csvout("待核对点.csv", hdr, issues)
csvout(
    "逐图验收.csv",
    [
        "站区",
        "原图",
        "识别原图对象",
        "生成节点",
        "可见读数",
        "设置KIO绑定",
        "待核对",
        "原PICX SHA256",
    ],
    summary,
)
csvout(
    "逐元素去向.csv",
    ["站区", "原图", "原图对象", "文件偏移", "去向", "生成节点"],
    objects,
)
print(
    "screens",
    len(screens),
    "readings",
    len(rows),
    "set",
    len(bindings),
    "vars",
    len(variables),
    "counts",
    collections.Counter(r[7] for r in rows),
    "objects",
    len(objects),
    "bytes",
    (out / "31站工艺重建-KIO已核对.json").stat().st_size,
)


csvout("标注避让记录.csv", ["站区", "节点或读数框", "水平移动", "垂直移动"], shifts)
