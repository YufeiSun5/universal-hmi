{{flutter_js}}
{{flutter_build_config}}

// The physical Android WebView traps in CanvasKit during frame updates.
// Ship skwasm with the normal CanvasKit fallback for older browsers. Keep
// skwasm on one thread, including hosts that enable cross-origin isolation.
_flutter.loader.load({
  config: {forceSingleThreadedSkwasm: true},
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}}
  }
});
