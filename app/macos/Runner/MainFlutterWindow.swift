import Cocoa
import FlutterMacOS

// NSScreen visibleFrame and NSWindow content sizes use logical points.
func hmiMinimumContentSize(available: NSSize) -> NSSize {
  NSSize(width: max(1, min(900, available.width)),
         height: max(1, min(600, available.height)))
}

class MainFlutterWindow: NSWindow {
  private var geometryObservers: [NSObjectProtocol] = []

  private func updateMinimumContentSize() {
    guard let targetScreen = screen ?? NSScreen.main else { return }
    let available = contentRect(forFrameRect: targetScreen.visibleFrame).size
    let minimum = hmiMinimumContentSize(available: available)
    if contentMinSize != minimum {
      contentMinSize = minimum
    }
  }

  deinit {
    geometryObservers.forEach(NotificationCenter.default.removeObserver)
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    updateMinimumContentSize()
    // Clamp only the initial restored size. Normal movement, maximize and
    // fullscreen remain AppKit operations; monitor changes update only the min.
    if let targetScreen = screen ?? NSScreen.main {
      let available = contentRect(forFrameRect: targetScreen.visibleFrame).size
      let current = contentRect(forFrameRect: frame).size
      setContentSize(NSSize(width: min(available.width, max(contentMinSize.width, current.width)),
                            height: min(available.height, max(contentMinSize.height, current.height))))
      setFrame(constrainFrameRect(frame, to: targetScreen), display: true)
    }
    let center = NotificationCenter.default
    geometryObservers = [
      center.addObserver(forName: NSWindow.didChangeScreenNotification,
                         object: self, queue: .main) { [weak self] _ in
        self?.updateMinimumContentSize()
      },
      center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                         object: nil, queue: .main) { [weak self] _ in
        self?.updateMinimumContentSize()
      }
    ]

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
