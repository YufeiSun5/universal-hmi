"""Real browser import/filter/export interaction against the Go backend."""
import base64
import io
import json
import pathlib
import subprocess
import tempfile
import time
import urllib.request
import zipfile
from playwright.sync_api import sync_playwright

root=pathlib.Path.cwd().parent
server=root/"dist/universal-hmi-server";server.chmod(0o755)
base="http://127.0.0.1:18081"
def api(path):
    with urllib.request.urlopen(base+path,timeout=5) as r:return json.load(r)
with tempfile.TemporaryDirectory(prefix="hmi-browser-") as data:
    backend=subprocess.Popen([str(server),"--listen","127.0.0.1:18081","--data-dir",data,"--web-dir",str(root/"app/build/web")],stdout=subprocess.DEVNULL)
    try:
        deadline=time.monotonic()+10
        while time.monotonic()<deadline:
            try:
                if api("/health")["status"]=="ok":break
            except Exception:time.sleep(.1)
        with sync_playwright() as playwright:
            browser=playwright.chromium.launch()
            page=browser.new_page(viewport={"width":1440,"height":900},accept_downloads=True)
            page.goto(base,wait_until="networkidle",timeout=60000)
            page.locator("flt-semantics-placeholder").wait_for(state="attached",timeout=30000)
            page.locator("flt-semantics-placeholder").evaluate("(element) => element.click()")
            page.get_by_role("button",name="分析与报表",exact=True).click()
            with page.expect_file_chooser() as chooser:
                page.get_by_role("button",name="导入 Excel / CSV",exact=True).click()
            chooser.value.set_files({"name":"fixture.csv","mimeType":"text/csv","buffer":b"time,value\n2026-10-01T00:00:00Z,20\n2026-10-01T00:01:00Z,40\n2026-10-01T00:02:00Z,60\n"})
            page.get_by_role("button",name="验证映射并预览",exact=True).click()
            page.get_by_text("有效行数：3",exact=True).wait_for()
            page.get_by_role("button",name="导入历史数据",exact=True).click()
            page.get_by_role("textbox",name="最小值",exact=True).fill("30")
            page.get_by_role("textbox",name="最大值",exact=True).fill("70")
            page.get_by_role("button",name="筛选",exact=True).click()
            page.get_by_text("样本  2",exact=True).wait_for()
            page.get_by_role("button",name="导出 XLSX",exact=True).click()
            page.get_by_role("button",name="保存报表",exact=True).wait_for(timeout=15000)
            with page.expect_download() as download:
                page.get_by_role("button",name="保存报表",exact=True).click()
            folder=root/"dist/screenshots";folder.mkdir(parents=True,exist_ok=True)
            path=folder/"browser-filtered-report.xlsx";download.value.save_as(path)
            with zipfile.ZipFile(path) as archive:
                sheet=archive.read("xl/worksheets/sheet1.xml")
                assert b"<v>40</v>" in sheet and b"<v>60</v>" in sheet and b"<v>20</v>" not in sheet
            page.wait_for_timeout(3500)  # Let the save/queue notification leave the workspace.
            page.screenshot(path=str(folder/"web-analysis.png"))
            page.screenshot(path=str(folder/"web-analysis.jpg"),type="jpeg",quality=75)
            print("HMI_SCREENSHOT "+base64.b64encode((folder/"web-analysis.jpg").read_bytes()).decode())
            page.get_by_role("button",name="浅色主题",exact=True).click()
            page.screenshot(path=str(folder/"web-analysis-light.png"))
            browser.close()
        print("PASS: real browser file picker -> upload -> column preview -> historical import -> numeric filter -> statistics/chart -> XLSX download and workbook validation")
    finally:
        backend.terminate();backend.wait(timeout=10)
