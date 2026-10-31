"""Reproduce the pinned, static FUXA process-symbol subset from an extracted source archive.

Not run during builds: the reviewed SVGs, manifest and license are committed.
Usage: python ci/vendor_process_symbols.py --source <FUXA-SVG-Widgets-70e7...>
"""
import argparse
import hashlib
import json
import re
from pathlib import Path
import xml.etree.ElementTree as ET

REVISION = "70e7c4a656d111c0428c77eb4b0409fc3670b8d5"
REPOSITORY = "https://github.com/frangoteam/FUXA-SVG-Widgets"
DEST = Path(__file__).resolve().parents[1] / "app/assets/process"
ALLOWED = set("svg g defs path rect circle ellipse line polyline polygon text tspan linearGradient radialGradient stop clipPath use title desc".split())
CATEGORIES = {
    "Heat Exchangers": "换热器", "Pumps": "泵", "Pumps DIN": "泵 DIN",
    "Pumps ISO": "泵 ISO", "Valves": "阀门", "Vessels": "容器与水箱",
    "Flow Sensors": "流量仪表", "Instruments": "仪表", "Piping": "管道",
    "Fittings": "管件", "Filters": "过滤器", "Compressors": "压缩机",
    "Compressors ISO": "压缩机 ISO", "Agitators": "搅拌器", "Apparatus Elements": "设备部件",
    "Centrifuges": "离心机", "Crushers Grinding": "破碎研磨", "Driers": "干燥器",
    "Engines": "驱动设备", "Feeders": "给料设备", "Misc": "其他工艺",
    "Mixers": "混合器", "Separators": "分离器",
}

def sanitize(data):
    root = ET.fromstring(data)
    def clean(element):
        for child in list(element):
            if child.tag.split("}")[-1] not in ALLOWED:
                element.remove(child)
            else:
                clean(child)
                if child.tag.split("}")[-1] == "defs" and len(child) == 0:
                    element.remove(child)
        for key, value in list(element.attrib.items()):
            local = key.split("}")[-1]
            if local.lower().startswith("on") or local == "style" or local.startswith("data-"):
                # Turn supported inline presentation styles into attributes.
                if local == "style":
                    for declaration in value.split(";"):
                        if ":" not in declaration: continue
                        prop, val = map(str.strip, declaration.split(":",1))
                        if prop in {"fill","stroke","stroke-width","opacity","fill-opacity","stroke-opacity","font-size","font-family","font-weight","text-anchor"}:
                            element.set(prop,val)
                del element.attrib[key]
        for key, value in list(element.attrib.items()):
            if (key.split("}")[-1] == "href" and not value.startswith("#")) or re.search(r"url\(\s*[^#]",value) or re.search(r"(?:https?:|file:|javascript:|data:)",value,re.I):
                del element.attrib[key]
    clean(root)
    root.set("width","100%")
    root.set("height","100%")
    ET.register_namespace("","http://www.w3.org/2000/svg")
    return ET.tostring(root,encoding="utf-8",xml_declaration=True)+b"\n"

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source",type=Path,required=True)
    args=parser.parse_args()
    assert args.source.name.endswith(REVISION), "Use the pinned source revision"
    (DEST/"symbols").mkdir(parents=True,exist_ok=True)
    entries=[]
    for path in sorted((args.source/"Proc. Engineering").rglob("*.svg")):
        original=path.read_bytes()
        assert not re.search(rb"copyright|opto\s*22|creativecommons",original,re.I), f"Separate notice requires review: {path}"
        relative=path.relative_to(args.source).as_posix()
        identity="fuxa_"+hashlib.sha256(relative.encode()).hexdigest()[:16]
        rendered=sanitize(original)
        filename=f"symbols/{identity}.svg"
        (DEST/filename).write_bytes(rendered)
        category=re.sub(r"^Proc\. Eng\.\s*","",path.parent.name).strip()
        entries.append({"id":identity,"name":re.sub(r"^\d+_","",path.stem).replace("_"," "),
                        "category":CATEGORIES.get(category,category),"path":"assets/process/"+filename,
                        "source_path":relative,"source_sha256":hashlib.sha256(original).hexdigest(),
                        "sha256":hashlib.sha256(rendered).hexdigest()})
    assert len(entries)==458
    manifest={"schema_version":1,"repository":REPOSITORY,"revision":REVISION,"license":"MIT",
              "modifications":"Static geometry only; removed scripts, event handlers, foreign elements and external references. Presentation styles normalized.","items":entries}
    (DEST/"catalog.json").write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+"\n",encoding="utf-8",newline="\n")
    (DEST/"LICENSE-FUXA.txt").write_bytes((args.source/"LICENSE").read_bytes())
    print(f"Vendored {len(entries)} reviewed process symbols at {REVISION}")

if __name__=="__main__": main()
