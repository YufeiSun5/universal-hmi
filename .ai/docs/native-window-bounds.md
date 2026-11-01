# Native window minimum bounds

This change affects only Linux GTK and macOS AppKit window geometry. It does not
change project data, Flutter page layout, permissions, backend lifecycle, or the
minimum supported operating-system version. Windows keeps its existing
DPI-aware 900 × 600 outer-window tracking limit.

## Behavior

- Linux and macOS prefer a 900 × 600 **content** area in logical pixels/points.
  The minimum is reduced when the active display's usable workarea cannot fit
  that content plus the native frame/title bar. This is deliberately not a
  fixed or maximum window size.
- Initial requested content sizes are bounded to the known workarea. Linux
  server-side decoration is only measurable after mapping; its later minimum
  hint accounts for that frame. Placement remains the window manager’s job. Subsequent moves,
  zoom/maximize and fullscreen remain native window-manager operations.
- Linux recalculates the minimum on configure/window-state/display-layout
  events and only republishes geometry hints when their values change. GDK
  workareas already use logical application pixels; no second DPI multiplier is
  applied. External frame size uses native geometry from the same window. Internal
  title-bar/shadow dimensions are cached after GTK completes both window and
  child allocations. A configure event never combines its new dimensions with
  a stale child allocation.
- macOS uses `contentRect(forFrameRect: screen.visibleFrame)` and
  `contentMinSize`. Window-screen and display-configuration observers do not
  replace the Flutter/AppKit delegate and are removed on deallocation.
- A small display may necessarily provide less than 900 × 600. Flutter page
  wrapping, drawers and scrollable content remain necessary; window bounds do
  not make an overflowing page responsive.

## Verification and limits

`python -m unittest discover -s ci -p test_native_window_bounds.py -v` compiles
the actual arithmetic helpers with C++/Swift when their compilers are present,
and checks source wiring. The same test runs in the three-platform backend CI;
the existing Linux/macOS Flutter jobs compile the real runners and package jobs
retain their lifecycle checks. Arithmetic/source checks are **not** a substitute
for native interactive resize, maximization, multi-monitor or DPI acceptance.

Required native manual checks: drag below the preferred minimum on a normal
screen; move to a smaller/high-DPI display; change desktop workarea; maximize,
restore and fullscreen; confirm all visible title-bar actions stay reachable.
GTK/Wayland compositors can vary in workarea reporting and geometry-hint
handling; where no workarea exists GDK returns the monitor geometry.

References: [GTK geometry hints](https://docs.gtk.org/gtk3/method.Window.set_geometry_hints.html),
[GDK workareas](https://docs.gtk.org/gdk3/method.Monitor.get_workarea.html),
[AppKit content minimum](https://developer.apple.com/documentation/appkit/nswindow/contentminsize).
