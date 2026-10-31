"""Real browser file import/filter/export, with an isolated input-event probe.

A browser automation failure is recorded as blocked and fails this gate; XLSX
40/60 inclusion and 20 exclusion are never weakened to accommodate the runtime.
"""
import argparse
import json
import re
import time
from urllib.parse import urlsplit
from pathlib import Path
import subprocess
import tempfile
import zipfile

from playwright.sync_api import expect, sync_playwright

from common import ROOT, health, port_available, stop, wait_for


# Test-fixture-only instrumentation; never installed on login or arbitrary pages.
# Both clocks are epoch milliseconds so input and runtime records can be correlated.
INPUT_TRACE_SCRIPT = r"""() => {
  const labels = new Set(['最小值', '最大值']);
  const events = [];
  let dropped = 0, nextID = 0, stopped = false;
  const ids = new WeakMap();
  const target = e => e instanceof HTMLInputElement &&
    labels.has(e.getAttribute('aria-label'));
  const id = e => {
    if (!ids.has(e)) ids.set(e, ++nextID);
    return ids.get(e);
  };
  const snapshot = e => ({
    node: id(e), label: e.getAttribute('aria-label'), connected: e.isConnected,
    focused: document.activeElement === e, value: e.value.slice(0, 32),
    selection_start: e.selectionStart, selection_end: e.selectionEnd,
    selection_direction: e.selectionDirection,
    autocorrect: e.getAttribute('autocorrect'),
    autocomplete: e.getAttribute('autocomplete'),
    spellcheck: e.getAttribute('spellcheck'),
    semantics_role: e.getAttribute('data-semantics-role'),
    readonly: e.readOnly, disabled: e.disabled
  });
  const record = (type, e, extra = {}) => {
    if (stopped || !target(e)) return;
    if (events.length >= 256) { dropped++; return; }
    events.push({at_ms: Date.now(), monotonic_ms: performance.now(), type,
      ...snapshot(e), ...extra});
  };
  const listeners = [];
  for (const type of ['focus', 'blur', 'keydown', 'beforeinput', 'input', 'keyup']) {
    const listener = event => {
      if (!target(event.target)) return;
      const e = event.target;
      // Keys/data only come from these two synthetic numeric fixture fields.
      const extra = {key: (event.key || '').slice(0, 24),
        input_type: (event.inputType || '').slice(0, 32),
        data: (event.data || '').slice(0, 16), composing: !!event.isComposing};
      record(type, e, extra);
      queueMicrotask(() => record(type + ':after', e));
      requestAnimationFrame(() => record(type + ':frame', e));
    };
    document.addEventListener(type, listener, true);
    listeners.push([type, listener]);
  }
  const selection = () => record('selectionchange', document.activeElement);
  document.addEventListener('selectionchange', selection, true);
  const scan = () => document.querySelectorAll('input[aria-label]').forEach(e => {
    if (target(e) && !ids.has(e)) record('node_seen', e);
  });
  const observer = new MutationObserver(records => {
    for (const mutation of records) {
      if (mutation.type === 'attributes')
        record('attribute:' + mutation.attributeName, mutation.target);
    }
    scan();
  });
  observer.observe(document.documentElement, {subtree: true, childList: true,
    attributes: true, attributeFilter: ['autocorrect', 'autocomplete',
      'spellcheck', 'aria-label', 'data-semantics-role', 'readonly', 'disabled']});
  scan();
  window.__hmiInputTrace = {finish: () => {
    document.querySelectorAll('input[aria-label]').forEach(e => record('final', e));
    stopped = true;
    observer.disconnect();
    for (const [type, listener] of listeners)
      document.removeEventListener(type, listener, true);
    document.removeEventListener('selectionchange', selection, true);
    return {events, dropped, limit: 256};
  }};
}"""


class RuntimeTrace:
    """Bounded synthetic runtime metadata, not request/response payload logging."""

    def __init__(self, base):
        self.base = urlsplit(base)
        self.events = []
        self.pending = {}
        self.dropped = 0
        self.sequence = 0

    def request(self, request):
        url = urlsplit(request.url)
        if (url.scheme, url.netloc, url.path) != (
                self.base.scheme, self.base.netloc, "/api/v1/runtime"):
            return
        if len(self.events) >= 64:
            self.dropped += 1
            return
        self.sequence += 1
        entry = {"id": self.sequence, "requested_at_ms": time.time_ns() // 1_000_000}
        self.events.append(entry)
        self.pending[request] = entry

    def finished(self, request):
        entry = self.pending.pop(request, None)
        if entry is None:
            return
        entry["finished_at_ms"] = time.time_ns() // 1_000_000
        try:
            response = request.response()
            if response is None:
                entry["result"] = "no_response"
                return
            entry["status"] = response.status
            # Isolated fixture only: body() reads the completed response. This
            # 64 KiB parsing/retention limit is NOT a network streaming limit.
            # Do not retain values or other fields.
            body = response.body()
            if len(body) > 65536:
                entry["result"] = "body_limit"
                return
            data = json.loads(body)
            version = data.get("version") if isinstance(data, dict) else None
            if isinstance(version, str) and re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", version):
                entry["version"] = version
            entry["result"] = "observed"
        except Exception:
            entry["result"] = "unavailable"

    def failed(self, request):
        entry = self.pending.pop(request, None)
        if entry is not None:
            entry.update(finished_at_ms=time.time_ns() // 1_000_000, result="failed")

    def snapshot(self):
        return {"events": self.events, "dropped": self.dropped, "limit": 64}


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
                runtime_trace = RuntimeTrace(base)
                page.on("request", runtime_trace.request)
                page.on("requestfinished", runtime_trace.finished)
                page.on("requestfailed", runtime_trace.failed)
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
                    # Network quiescence is not app readiness with live streams/polling.
                    # https://playwright.dev/python/docs/api/class-page#page-goto-option-wait-until
                    evidence["phase"] = "document_navigation"
                    response = page.goto(base, wait_until="domcontentloaded", timeout=60000)
                    assert response is not None and response.ok, "Workspace document did not load successfully"
                    evidence["phase"] = "workspace_semantics"
                    page.locator("flt-semantics-placeholder").wait_for(state="attached", timeout=30000)
                    page.locator("flt-semantics-placeholder").evaluate("element => element.click()")
                    history_button = page.get_by_role("button", name="历史报表", exact=True)
                    expect(history_button).to_be_visible(timeout=30000)
                    expect(history_button).to_be_enabled(timeout=30000)
                    evidence["checks"]["workspace_semantics_ready"] = True
                    evidence["phase"] = "import_filter_export"
                    history_button.click()
                    with page.expect_file_chooser() as chooser:
                        page.get_by_role("button", name="导入 Excel / CSV", exact=True).click()
                    chooser.value.set_files({"name": "fixture.csv", "mimeType": "text/csv", "buffer": b"time,value\n2026-10-01T00:00:00Z,20\n2026-10-01T00:01:00Z,40\n2026-10-01T00:02:00Z,60\n"})
                    page.get_by_role("button", name="验证映射并预览", exact=True).click()
                    page.get_by_text("有效行数：3", exact=True).wait_for()
                    page.get_by_role("button", name="导入历史数据", exact=True).click()
                    # Import returns asynchronously and changes the station scope.
                    # Wait for its actual history result, not merely the click.
                    # Flutter may replace its semantics editor on first focus; real
                    # click/key events re-resolve that editor instead of assigning
                    # a value to the transient pre-focus DOM input.
                    page.get_by_text("工作表与列映射", exact=True).wait_for(state="hidden")
                    page.get_by_text("样本  3", exact=True).wait_for()
                    filter_button = page.get_by_role("button", name="筛选", exact=True)
                    expect(filter_button).to_be_enabled()
                    minimum = page.get_by_role("textbox", name="最小值", exact=True)
                    maximum = page.get_by_role("textbox", name="最大值", exact=True)
                    page.evaluate(INPUT_TRACE_SCRIPT)
                    minimum.click()
                    expect(minimum).to_be_focused()
                    minimum.press("ControlOrMeta+A")
                    minimum.press_sequentially("30", delay=50)
                    expect(minimum).to_have_value("30")
                    maximum.click()
                    expect(maximum).to_be_focused()
                    maximum.press("ControlOrMeta+A")
                    maximum.press_sequentially("70", delay=50)
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
                    evidence["phase"] = "complete"
                    print("PASS: browser file picker -> CSV preview/import -> 30..70 filter -> XLSX includes40/60 and excludes20")
                except Exception as error:
                    if evidence["status"] != "blocked":
                        evidence["status"] = "failed"
                    evidence["error"] = str(error)
                    page.screenshot(path=str(args.output / "browser-failure.png"))
                    raise
                finally:
                    try:
                        input_trace = page.evaluate("() => window.__hmiInputTrace ? window.__hmiInputTrace.finish() : {events: [], not_installed: true}")
                    except Exception:
                        input_trace = {"events": [], "unavailable": True}
                    (args.output / "browser-input-trace.json").write_text(json.dumps(input_trace, indent=2) + "\n")
                    (args.output / "browser-runtime-trace.json").write_text(json.dumps(runtime_trace.snapshot(), indent=2) + "\n")
                    (args.output / "browser-console.json").write_text(json.dumps(messages, indent=2) + "\n")
                    (args.output / "browser-history-requests.json").write_text(json.dumps(history_requests, indent=2) + "\n")
                    browser.close()
        finally:
            stop(backend)
            (args.output / "browser-flow.json").write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    main()
