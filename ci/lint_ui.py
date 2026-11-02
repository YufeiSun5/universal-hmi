"""Security UI quality gate. Run from any directory; requires the fixed Flutter SDK.

Static checks prevent removed product UI from returning. Runtime tests inspect
rendered controls across widths/text scales, including scrolling and edit pages.
The JSON report describes test outcomes; this is not a substitute for visual QA.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def static_issues():
    issues = []
    for name in ("account_security.dart", "login.dart", "security.dart", "device_certificates.dart"):
        path = ROOT / "app/lib/features" / name
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if re.search(r"/mfa/|验证器|恢复码|双因素", line):
                issues.append({"rule": "removed-authenticator-ui", "file": str(path.relative_to(ROOT)), "line": number})
    return issues


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--static-only", action="store_true")
    parser.add_argument("--report", type=Path, default=ROOT / "output/ui-lint/report.json")
    args = parser.parse_args()
    report = {"schema": 1, "scope": ["account", "network", "user editor", "whitelist editor"],
              "rules": ["removed-authenticator-ui", "layout-exception", "target-size", "control-overlap", "control-gap"],
              "static_issues": static_issues(), "runtime": "unexecuted", "tests": [], "errors": []}
    code = 1 if report["static_issues"] else 0
    if not args.static_only and not code:
        flutter = shutil.which("flutter")
        if not flutter:
            report["errors"].append("Flutter SDK not found on PATH")
            code = 2
        else:
            result = subprocess.run([flutter, "test", "--no-pub", "--machine", "test/ui_lint_test.dart"], cwd=ROOT / "app", capture_output=True, text=True, encoding="utf-8", errors="replace")
            code = result.returncode
            names = {}
            for line in result.stdout.splitlines():
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(event, dict):
                    continue
                if event.get("type") == "testStart":
                    names[event["test"]["id"]] = event["test"]["name"]
                elif event.get("type") == "testDone" and not event.get("hidden"):
                    report["tests"].append({"name": names.get(event["testID"], str(event["testID"])), "result": event["result"], "skipped": event.get("skipped", False)})
                elif event.get("type") == "error":
                    report["errors"].append({"test": names.get(event.get("testID")), "message": event.get("error"), "stack": event.get("stackTrace")})
            if not report["tests"]:
                report["errors"].append("No runtime test results; gate fails closed")
                code = code or 2
            if result.stderr.strip():
                report["stderr"] = result.stderr.strip()
            report["runtime"] = "passed" if code == 0 else "failed"
    report["passed"] = code == 0
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"UI lint {'PASS' if code == 0 else 'FAIL'}: {len(report['tests'])} runtime cases; report {args.report}")
    if code:
        for error in report["static_issues"] + report["errors"]:
            print(json.dumps(error, ensure_ascii=False))
    return code


if __name__ == "__main__":
    sys.exit(main())
