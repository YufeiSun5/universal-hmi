// Execute with playwright-cli run-code --filename <this file>.
async (page) => {
  const report = JSON.parse(await page.locator('html').getAttribute('data-probe-report'));
  if (!report.passed) throw new Error(JSON.stringify(report));
  await page.setViewportSize({width: 1440, height: 900});
  // Canvas cell B2: coordinates observed in the 1440x900 fixture screenshot.
  await page.mouse.dblclick(270, 167);
  const input = page.frameLocator('iframe').locator('.luckysheet-cell-input');
  await input.fill('55');
  await input.press('Enter');
  const snapshot = await page.evaluate(() => new Promise((resolve, reject) => {
    const frame = document.querySelector('iframe');
    const timeout = setTimeout(() => { window.removeEventListener('message', listener); reject(new Error('snapshot timeout')); }, 5000);
    const listener = event => {
      if (event.origin !== location.origin || event.source !== frame.contentWindow) return;
      const message = JSON.parse(event.data);
      if (message.id !== 'browser-check') return;
      clearTimeout(timeout);
      window.removeEventListener('message', listener);
      const sheet = message.result[0];
      resolve({b2: sheet.data[1][1].v, c2: sheet.data[1][2].v});
    };
    window.addEventListener('message', listener);
    frame.contentWindow.postMessage(JSON.stringify({channel:'hmi-fortune-probe-v1',type:'snapshot',id:'browser-check'}), location.origin);
  }));
  // This editor keeps typed input as text, while the formula evaluates it numerically.
  if (snapshot.b2 !== '55' || snapshot.c2 !== 110) throw new Error(JSON.stringify(snapshot));
  // Read through the actual Flutter button and leave its status visible.
  await page.mouse.click(870, 24);
  await page.screenshot({path:'output/playwright/fortune-flutter/web-edited.png'});
  await page.setViewportSize({width:760,height:520});
  await page.screenshot({path:'output/playwright/fortune-flutter/web-narrow.png'});
  await page.setViewportSize({width:1440,height:900});
  return {passed:true, bridge:report, keyboardEdit:snapshot, viewports:[[1440,900],[760,520]]};
}
