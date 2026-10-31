"""Diagnostic helper contracts without Playwright, a browser, or Node installs.

AST loading deliberately extracts only the pure helper: browser execution and
its imports are not needed for these bounded metadata/privacy tests.
"""
import ast
import json
from pathlib import Path
import re
import time
import unittest
from unittest.mock import Mock
from urllib.parse import urlsplit

SOURCE = Path(__file__).with_name("browser_flow.py").read_text(encoding="utf-8")
TREE = ast.parse(SOURCE)
NAMESPACE = {"json": json, "re": re, "time": time, "urlsplit": urlsplit}
HELPER = next(node for node in TREE.body if isinstance(node, ast.ClassDef)
              and node.name == "RuntimeTrace")
exec(compile(ast.Module(body=[HELPER], type_ignores=[]), "browser_flow.py", "exec"), NAMESPACE)
RuntimeTrace = NAMESPACE["RuntimeTrace"]
SCRIPT = next(ast.literal_eval(node.value) for node in TREE.body
              if isinstance(node, ast.Assign)
              and any(isinstance(target, ast.Name) and target.id == "INPUT_TRACE_SCRIPT"
                      for target in node.targets))


class BrowserInputDiagnostics(unittest.TestCase):
    def setUp(self):
        self.trace = RuntimeTrace("http://127.0.0.1:18081")

    def request(self, payload=None, url="http://127.0.0.1:18081/api/v1/runtime?secret=DO_NOT_RECORD"):
        response = Mock(status=200)
        response.body.return_value = json.dumps(payload or {"version": "runtime-42"}).encode()
        return Mock(url=url, response=Mock(return_value=response))

    def test_only_same_origin_exact_runtime_and_bounded_records(self):
        for url in ["https://127.0.0.1:18081/api/v1/runtime",
                    "http://evil.test/api/v1/runtime",
                    "http://127.0.0.1:18081/api/v1/auth/login",
                    "http://127.0.0.1:18081/api/v1/runtime/events"]:
            self.trace.request(self.request(url=url))
        self.assertEqual(self.trace.events, [])
        for _ in range(70):
            request = self.request({"version": "runtime-42", "password": "DO_NOT_RECORD",
                                    "values": ["SECRET"]})
            self.trace.request(request)
            self.trace.finished(request)
        snapshot = self.trace.snapshot()
        self.assertEqual(len(snapshot["events"]), 64)
        self.assertEqual(snapshot["dropped"], 6)
        self.assertFalse(self.trace.pending)
        self.assertNotIn("DO_NOT_RECORD", json.dumps(snapshot))
        self.assertNotIn("SECRET", json.dumps(snapshot))
        self.assertTrue(all(event["version"] == "runtime-42" for event in snapshot["events"]))

    def test_response_failures_cannot_escape_diagnostics(self):
        for location in ["response", "body", "json", "missing"]:
            with self.subTest(location=location):
                request = self.request()
                if location == "response":
                    request.response.side_effect = RuntimeError("SECRET")
                elif location == "body":
                    request.response.return_value.body.side_effect = RuntimeError("SECRET")
                elif location == "json":
                    request.response.return_value.body.return_value = b"SECRET"
                else:
                    request.response.return_value = None
                self.trace.request(request)
                self.trace.finished(request)
                self.assertIn(self.trace.events[-1]["result"], ["unavailable", "no_response"])
        self.assertNotIn("SECRET", json.dumps(self.trace.snapshot()))

    def test_body_limit_unsafe_version_and_failed_request(self):
        request = self.request()
        request.response.return_value.body.return_value = b"x" * 65537
        self.trace.request(request)
        self.trace.finished(request)
        self.assertEqual(self.trace.events[-1]["result"], "body_limit")
        for version in ["secret with spaces", "x" * 129, {"secret": "value"}]:
            request = self.request({"version": version})
            self.trace.request(request)
            self.trace.finished(request)
            self.assertNotIn("version", self.trace.events[-1])
        request = self.request()
        self.trace.request(request)
        self.trace.failed(request)
        self.assertEqual(self.trace.events[-1]["result"], "failed")
        self.assertFalse(self.trace.pending)

    def test_input_script_is_scoped_bounded_and_observational(self):
        self.assertIn("new Set(['最小值', '最大值'])", SCRIPT)
        self.assertIn("e instanceof HTMLInputElement", SCRIPT)
        self.assertIn("labels.has(e.getAttribute('aria-label'))", SCRIPT)
        self.assertIn("events.length >= 256", SCRIPT)
        for field in ["selectionStart", "selectionEnd", "autocorrect", "WeakMap",
                      "beforeinput", "keydown", "keyup", "focus", "blur",
                      "queueMicrotask", "requestAnimationFrame", "MutationObserver", "selectionchange",
                      "stopped = true", "stopped || !target(e)"]:
            self.assertIn(field, SCRIPT)
        for forbidden in [".focus(", ".click(", "preventDefault", "stopPropagation",
                          "dispatchEvent", "fetch(", "XMLHttpRequest"]:
            self.assertNotIn(forbidden, SCRIPT)
        self.assertIn('minimum.press_sequentially("30", delay=50)', SOURCE)
        self.assertIn('maximum.press_sequentially("70", delay=50)', SOURCE)
        self.assertIn('expect(maximum).to_have_value("70")', SOURCE)


if __name__ == "__main__":
    unittest.main()
