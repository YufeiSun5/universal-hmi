'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../app/web/flutter_bootstrap.js'), 'utf8')
  .replace('{{flutter_js}}', '').replace('{{flutter_build_config}}', '')
  .replace('{{flutter_service_worker_version}}', '"test-version"');

function fixture(pathname) {
  const calls = [];
  class Context {
    constructor(parent = 'FLT-CANVAS-CONTAINER') {
      this.canvas = {width: 800, height: 600, parentElement: {tagName: parent}};
    }
    drawImage(...args) { calls.push(['draw', ...args]); return 'drawn'; }
    clearRect(...args) { calls.push(['clear', ...args]); }
  }
  let settings;
  const scope = {CanvasRenderingContext2D: Context, location: {pathname},
    _flutter: {loader: {load: options => { settings = options; return Promise.resolve(); }}}};
  scope.window = scope;
  const context = vm.createContext(scope);
  const run = () => vm.runInContext(source, context);
  run();
  return {Context, calls, run, settings};
}
const fullFrame = [{}, 0, 100, 800, 600, 0, 0, 800, 600];
{
  const f = fixture('/kp/'), ctx = new f.Context();
  for (let frame = 0; frame < 3; frame++) {
    assert.equal(ctx.drawImage(...fullFrame), 'drawn');
    assert.deepEqual(f.calls.slice(-2).map(c => c[0]), ['clear', 'draw']);
  }
  assert.deepEqual(f.calls[0], ['clear', 0, 0, 800, 600]);
  f.run(); f.calls.length = 0; ctx.drawImage(...fullFrame);
  assert.equal(f.calls.length, 2, 'loading bootstrap twice must not stack wrappers');
  assert.equal(f.settings.serviceWorkerSettings, undefined);
  assert.equal(f.settings.config.forceSingleThreadedSkwasm, true);
  assert.equal(f.settings.config.canvasKitForceCpuOnly, undefined);
}
{
  const f = fixture('/');
  new f.Context('DIV').drawImage(...fullFrame); // map/other canvas
  const ctx = new f.Context();
  ctx.drawImage({}, 0, 0); // ordinary image, not a complete frame copy
  ctx.drawImage({}, 0, 0, 800, 600, 1, 0, 800, 600); // partial copy
  ctx.drawImage({}, 0, 0, 800, 600, 0, 0, 400, 300); // scaled image
  assert.ok(f.calls.every(c => c[0] === 'draw'));
  assert.equal(f.settings.serviceWorkerSettings.serviceWorkerVersion, 'test-version');
}
console.log('PASS: full transparent frame replacement, repeat loads, map/image isolation, KP startup and normal worker');
