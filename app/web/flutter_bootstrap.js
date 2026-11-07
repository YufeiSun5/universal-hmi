{{flutter_js}}
{{flutter_build_config}}

// Flutter 3.35's CanvasKit fallback copies complete frames with drawImage
// without clearing its on-screen canvas. Chromium 110 (bundled with KP)
// takes this path, so transparent overlays retain pixels from prior frames.
// Clear only Flutter's full-frame canvas copies. Map canvases, ordinary image
// drawing and the modern ImageBitmap/skwasm paths are unaffected.
(() => {
  const prototype = window.CanvasRenderingContext2D?.prototype;
  if (!prototype || prototype.hmiFullFrameClear) return;
  const drawImage = prototype.drawImage;
  prototype.drawImage = function (...args) {
    const canvas = this.canvas;
    if (canvas.parentElement?.tagName === 'FLT-CANVAS-CONTAINER' &&
        args.length === 9 && args[5] === 0 && args[6] === 0 &&
        args[7] === canvas.width && args[8] === canvas.height) {
      this.clearRect(0, 0, canvas.width, canvas.height);
    }
    return drawImage.apply(this, args);
  };
  Object.defineProperty(prototype, 'hmiFullFrameClear', {value: true});
})();

// The physical Android WebView traps in CanvasKit during frame updates.
// Ship skwasm with the normal CanvasKit fallback for older browsers. Keep
// skwasm on one thread, including hosts that enable cross-origin isolation.
_flutter.loader.load({
  config: {forceSingleThreadedSkwasm: true},
  // KP is online and authenticated: do not block entry on the offline worker,
  // which precaches both JS and WASM although the browser needs only one.
  serviceWorkerSettings: location.pathname.startsWith('/kp/') ? undefined : {
    serviceWorkerVersion: {{flutter_service_worker_version}}
  },
  onEntrypointLoaded: async engineInitializer => {
    try {
      const runner = await engineInitializer.initializeEngine();
      await runner.runApp();
    } catch (error) { window.hmiLoading?.fail(); }
  }
}).catch(() => window.hmiLoading?.fail());
