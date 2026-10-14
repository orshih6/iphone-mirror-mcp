import AppKit
@preconcurrency import ScreenCaptureKit

struct LocatedWindow: @unchecked Sendable {
  let window: SCWindow
  /// Global screen points, top-left origin.
  let frame: CGRect
  let pid: pid_t
}

enum WindowLocator {
  static func runningApp(_ bundleID: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
  }

  static func appURL(_ bundleID: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
  }

  static func locate(_ bundleID: String) async throws -> LocatedWindow {
    try Permissions.requireScreen()
    guard let app = runningApp(bundleID) else {
      throw appURL(bundleID) == nil ? MirrorError.appNotInstalled(bundleID) : MirrorError.appNotRunning
    }
    let content: SCShareableContent
    do {
      content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    } catch {
      throw MirrorError.captureFailed("ScreenCaptureKit: \(error.localizedDescription)")
    }
    let windows = content.windows.filter {
      $0.owningApplication?.processID == app.processIdentifier
        && $0.windowLayer == 0 && $0.frame.width > 50 && $0.frame.height > 50
    }
    guard !windows.isEmpty else { throw MirrorError.windowNotFound }
    guard let best = windows.filter(\.isOnScreen).max(by: { area($0.frame) < area($1.frame) }) else {
      throw MirrorError.windowMinimized
    }
    return LocatedWindow(window: best, frame: best.frame, pid: app.processIdentifier)
  }

  private static func area(_ r: CGRect) -> CGFloat { r.width * r.height }
}
