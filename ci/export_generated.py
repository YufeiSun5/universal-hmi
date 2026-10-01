import base64
import json
import pathlib
import sys

scope = sys.argv[1]
root = pathlib.Path.cwd().parent
paths = []
if scope == "backend":
    paths = [root / "backend/go.mod", root / "backend/go.sum"]
    paths += sorted((root / "backend/cmd").rglob("*.go"))
    paths += sorted((root / "backend/internal").rglob("*.go"))
else:
    paths = [root / "app/pubspec.lock"]
    paths += [p for p in sorted((root / "app/linux").rglob("*")) if p.is_file() and "ephemeral" not in p.parts and ".git" not in p.parts]
for path in paths:
    if path.is_file():
        print("HMI_FILE " + json.dumps({"path": str(path.relative_to(root)), "base64": base64.b64encode(path.read_bytes()).decode("ascii")}))
