"""Export only public scaffold files to CI logs for repository initialization."""
import base64
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
paths = list((root / "backend").rglob("*.go"))
paths += list((root / "app" / "web").rglob("*"))
paths += list((root / "app" / "windows").rglob("*"))
paths += [root / "app" / "pubspec.lock", root / "app" / ".gitignore"]
for path in sorted(set(paths)):
    if not path.is_file():
        continue
    relative = path.relative_to(root).as_posix()
    if "/ephemeral/" in relative or "/build/" in relative:
        continue
    if path.stat().st_size > 256 * 1024:
        raise RuntimeError("Unexpected large generated file")
    record = {"path": relative, "base64": base64.b64encode(path.read_bytes()).decode("ascii")}
    print("HMI_FILE " + json.dumps(record, separators=(",", ":")), flush=True)
