"""Resolve new HMI references using KIO identity and explicit engineer evidence."""
import collections
import csv
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path("D:/DEV_D/KS_HELP/output/庄河环海KIO点表解析_20261025")
REFERENCE = Path("D:/DEV_D/KS_HELP/outputs/01a19edc_1103_KS_KIO/点表数据.json")
LOCAL = "\\\\local\\"
TYPE = {"IOFloat": "FLOAT", "IOLong": "INT", "IOShort": "INT", "IOByte": "INT"}

def read(path):
    return json.loads(path.read_text("utf-8-sig"))

def resolve():
    output = ROOT / "outputs/process-restore-1103"
    baseline = output / "逐点连线.csv"
    with baseline.open(encoding="utf-8-sig") as stream:
        readings = list(csv.DictReader(stream))
    tag_rows = read(SOURCE / "KIO变量明细.json")
    stats = read(SOURCE / "解析统计.json")
    package = Path("D:/Users/SunYufei/Downloads/z庄河供热KIO1.113.zip")
    assert hashlib.sha256(package.read_bytes()).hexdigest() == stats["sha256"]
    tags = collections.defaultdict(list)
    for tag in tag_rows:
        tags[tag["name"]].append(tag)
    engineer = read(SOURCE / "硬件工程师补充映射.json")["records"]
    references = {
        (row["station"], row["object"], row["ks"]): row
        for sheet in read(REFERENCE)["sheets"]
        for row in sheet["rows"]
    }
    # These rows are explicitly corrected to zone 1 in the engineer's report.
    cumulative_corrections = {
        ("中心站东南区", "Text535"),
        ("中心站西北区", "Text535"),
        ("香港广场党校区", "Text535"),
        ("华府怡景原阳光壹佰", "Text535"),
        ("新西站北线区", "Text535"),
        ("新北站北线", "Text535"),
    }
    resolutions = []
    for row in readings:
        key = (row["站区"], row["原图对象"], row["原图KS路径"])
        ref = references.get(key, {})
        selected = None
        evidence = None
        # Explicitly identified conflicts must not be turned into same-name matches.
        if ref.get("mapping") == "同名候选，绑定待核" and not re.search("跨站|重复|现场修正|待核|仍停用", ref.get("note", "")):
            name = ref["kio"]
            assert row["原图KS路径"].removeprefix(LOCAL) == name
            selected = name
            evidence = {"kind": "KIO完整同名唯一核对", "reference": str(REFERENCE)}
        if key[:2] in cumulative_corrections:
            matches = [
                record for record in engineer
                if record["站区"] == row["站区"] and record["传输位置"] == 11
            ]
            assert len(matches) <= 1
            if matches:
                selected = matches[0]["KIO变量"]
                evidence = {"kind": "工程师表累计量修正", "source": matches[0]["来源"],
                            "previous_pic_path": matches[0].get("原PIC路径")}
        if selected is None:
            continue
        assert len(tags[selected]) == 1, selected
        tag = tags[selected][0]
        assert tag["enabled"] == 1 and tag["data_type"] in TYPE, selected
        assert tag["device_address"] and tag["item"], selected
        resolutions.append({
            "station": key[0], "object": key[1], "ks": key[2], "kio": selected,
            "data_type": TYPE[tag["data_type"]], "evidence": evidence,
            "tag_id": tag["tag_id"], "device": tag["device"],
            "device_address": tag["device_address"], "register": tag["item"],
            "kio_package_sha256": stats["sha256"],
        })
    assert len({(r["station"], r["object"], r["ks"]) for r in resolutions}) == len(resolutions)
    destination = Path(__file__).with_name("variable_resolutions.json")
    destination.write_text(json.dumps(resolutions, ensure_ascii=False, indent=2), encoding="utf8")
    print("Resolved references", len(resolutions),
          dict(collections.Counter(r["evidence"]["kind"] for r in resolutions)))

if __name__ == "__main__":
    resolve()
