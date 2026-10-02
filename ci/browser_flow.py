"""Real browser file import/filter/export, with an isolated input-event probe.

A browser automation failure is recorded as blocked and fails this gate; XLSX
40/60 inclusion and 20 exclusion are never weakened to accommodate the runtime.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import zipfile

from playwright.sync_api import expect, sync_playwright

from common import ROOT, health, port_available, stop, wait_for


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, default=ROOT / "dist/universal-hmi-server")
    parser.add_argument("--web", type=Path, default=ROOT / "app/build/web")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/screenshots")
    args = parser.parse_args()
    args.server = args.server.resolve()
    args.server.chmod(0o755)
    args.output.mkdir(parents=True, exist_ok=True)
    base = "http://127.0.0.1:18081"
    assert port_available(18081), "Browser fixture port occupied; refusing to replace another backend"
    evidence = {"status": "running", "checks": {}}
    backend = None
    with tempfile.TemporaryDirectory(prefix="hmi-browser-") as data:
        try:
            with (args.output / "browser-backend.log").open("w") as log:
                backend = subprocess.Popen([str(args.server), "--listen", "127.0.0.1:18081", "--data-dir", data, "--web-dir", str(args.web.resolve())], stdout=log, stderr=subprocess.STDOUT)
            wait_for(lambda: health(base), description="browser fixture backend")
            with sync_playwright() as playwright:
                browser = playwright.chromium.launch()
                page = browser.new_page(viewport={"width": 1440, "height": 900}, accept_downloads=True)
                messages = []
                history_requests = []
                page.on("request", lambda request: history_requests.append(request.url) if "/api/v1/history?" in request.url else None)
                page.on("console", lambda message: messages.append({"type": message.type, "text": message.text}))
                page.on("pageerror", lambda error: messages.append({"type": "pageerror", "text": str(error)}))
                try:
                    # Diagnostic fixture exists only in the temporary test directory.
                    input_probe = Path(data) / "browser-input-probe.html"
                    input_probe.write_text('<!doctype html>\n<meta charset="utf-8">\n<title>Local browser input fixture</title>\n<label>Input probe <input aria-label="Input probe"></label>\n<output aria-label="Observed input"></output>\n<script>\nconst input = document.querySelector(\'input\');\ninput.addEventListener(\'input\', () => {\n  document.querySelector(\'output\').textContent = input.value;\n});\n</script>\n', encoding="utf-8")
                    page.goto(input_probe.as_uri())
                    page.get_by_role("textbox", name="Input probe", exact=True).fill("30")
                    try:
                        page.get_by_text("30", exact=True).wait_for(timeout=5000)
                    except Exception:
                        evidence["status"] = "blocked"
                        evidence["blocker"] = "Playwright/Chromium did not dispatch an input event on the independent plain HTML fixture"
                        page.screenshot(path=str(args.output / "browser-input-probe-failure.png"))
                        raise
                    evidence["checks"]["plain_html_input_events"] = True
                    page.goto(base, wait_until="networkidle", timeout=60000)
                    page.locator("flt-semantics-placeholder").wait_for(state="attached", timeout=30000)
                    page.locator("flt-semantics-placeholder").evaluate("element => element.click()")
                    page.get_by_role("button", name="历史报表", exact=True).click()
                    with page.expect_file_chooser() as chooser:
                        page.get_by_role("button", name="导入 Excel / CSV", exact=True).click()
                    chooser.value.set_files({"name": "fixture.csv", "mimeType": "text/csv", "buffer": b"time,value\n2026-10-01T00:00:00Z,20\n2026-10-01T00:01:00Z,40\n2026-10-01T00:02:00Z,60\n"})
                    page.get_by_role("button", name="验证映射并预览", exact=True).click()
                    page.get_by_text("有效行数：3", exact=True).wait_for()
                    page.get_by_role("button", name="导入历史数据", exact=True).click()
                    # Import returns asynchronously and changes the station scope.
                    # Wait for its actual history result, not merely the click.
                    page.get_by_text("工作表与列映射", exact=True).wait_for(state="hidden")
                    page.get_by_text("样本  3", exact=True).wait_for()
                    filter_button = page.get_by_role("button", name="筛选", exact=True)
                    expect(filter_button).to_be_enabled()
                    minimum = page.get_by_role("textbox", name="最小值", exact=True)
                    maximum = page.get_by_role("textbox", name="最大值", exact=True)
                    minimum.fill("30")
                    expect(minimum).to_have_value("30")
                    maximum.fill("70")
                    expect(maximum).to_have_value("70")
                    filter_button.click()
                    expect(minimum).to_have_value("30")
                    expect(maximum).to_have_value("70")
                    page.get_by_text("样本  2", exact=True).wait_for()
                    page.get_by_role("button", name="导出 XLSX", exact=True).click()
                    page.get_by_role("button", name="保存报表", exact=True).wait_for(timeout=15000)
                    with page.expect_download() as download:
                        page.get_by_role("button", name="保存报表", exact=True).click()
                    path = args.output / "browser-filtered-report.xlsx"
                    download.value.save_as(path)
                    with zipfile.ZipFile(path) as archive:
                        sheet = archive.read("xl/worksheets/sheet1.xml")
                        assert b"<v>40</v>" in sheet and b"<v>60</v>" in sheet and b"<v>20</v>" not in sheet
                    evidence["checks"]["file_picker_upload_preview_import_filter_and_download"] = True
                    evidence["checks"]["xlsx_contains_40_60_and_excludes_20"] = True
                    page.screenshot(path=str(args.output / "web-analysis.png"))
                    evidence["status"] = "passed"
                    print("PASS: browser file picker -> CSV preview/import -> 30..70 filter -> XLSX includes40/60 and excludes20")
                except Exception as error:
                    if evidence["status"] != "blocked":
                        evidence["status"] = "failed"
                    evidence["error"] = str(error)
                    page.screenshot(path=str(args.output / "browser-failure.png"))
                    raise
                finally:
                    (args.output / "browser-console.json").write_text(json.dumps(messages, indent=2) + "\n")
                    (args.output / "browser-history-requests.json").write_text(json.dumps(history_requests, indent=2) + "\n")
                    browser.close()
        finally:
            stop(backend)
            (args.output / "browser-flow.json").write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    main()
