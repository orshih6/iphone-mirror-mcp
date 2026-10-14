import Foundation
import AppKit
import CoreGraphics

/// The kill switch. Checked between every step of an input sequence: if the user
/// presses Esc or moves/clicks the mouse after the action started, the action stops.
final class AbortGuard: @unchecked Sendable {
  private let pid: pid_t
  private let started = Date()

  init(pid: pid_t) {
    self.pid = pid
    UserActivityMonitor.shared.start()
  }

  func check() throws {
    // .hidSystemState reflects the physical keyboard only, not events we post.
    if CGEventSource.keyState(.hidSystemState, key: 53) { throw MirrorError.aborted("Esc pressed") }
    if let what = UserActivityMonitor.shared.activity(since: started) { throw MirrorError.aborted(what) }
    if !Safety.isFrontmost(pid: pid) { throw MirrorError.aborted("iPhone Mirroring lost focus") }
  }

  func sleep(ms: Int) async throws {
    try check()
    try await Task.sleep(for: .milliseconds(ms))
    try check()
  }
}

/// Watches the session's mouse and keyboard events with a listen-only event tap.
/// Every event this tool posts carries `marker` in `eventSourceUserData`, so any
/// event without it came from the user. (Comparing cursor positions does not work:
/// the iOS pointer snaps toward buttons, and macOS counts posted events as hardware.)
final class UserActivityMonitor: @unchecked Sendable {
  static let shared = UserActivityMonitor()
  static let marker: Int64 = 0x6950_6D69  // "iPmi"

  private let lock = NSLock()
  private var started = false
  private var last: (Date, String)?

  func start() {
    lock.lock()
    defer { lock.unlock() }
    guard !started else { return }
    started = true
    let thread = Thread { UserActivityMonitor.runTap() }
    thread.name = "iphone-mirror.user-activity"
    thread.start()
  }

  func activity(since: Date) -> String? {
    lock.lock()
    defer { lock.unlock() }
    guard let (at, what) = last, at > since else { return nil }
    return what
  }

  fileprivate func record(_ what: String) {
    lock.lock()
    last = (Date(), what)
    lock.unlock()
  }

  private static func runTap() {
    let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .scrollWheel, .keyDown]
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
      eventsOfInterest: mask, callback: userActivityCallback, userInfo: nil
    ) else {
      Log.info("kill switch: could not create event tap; only Esc will abort")
      return
    }
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    CFRunLoopRun()
  }
}

private func userActivityCallback(
  _: CGEventTapProxy, type: CGEventType, event: CGEvent, _: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  if event.getIntegerValueField(.eventSourceUserData) != UserActivityMonitor.marker {
    switch type {
    case .keyDown:
      if event.getIntegerValueField(.keyboardEventKeycode) == 53 { UserActivityMonitor.shared.record("Esc pressed") }
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      break
    default:
      UserActivityMonitor.shared.record("mouse moved")
    }
  }
  return Unmanaged.passUnretained(event)
}

public enum Safety {
  /// Frontmost = owner of the top-most normal window on screen. This reads the
  /// window server directly, so it is correct even without an AppKit run loop.
  static func isFrontmost(pid: pid_t) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] else { return false }
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
      return (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid
    }
    return false
  }

  /// The lock screen / screensaver is a loginwindow window above everything else.
  public static func macLocked() -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
    return list.contains {
      ($0[kCGWindowOwnerName as String] as? String) == "loginwindow" && ($0[kCGWindowLayer as String] as? Int ?? 0) > 1000
    }
  }

  /// Brings iPhone Mirroring to the front, or throws without sending any input.
  static func activate(bundleID: String, pid: pid_t) async throws {
    if macLocked() { throw MirrorError.macLocked }
    if isFrontmost(pid: pid) { return }
    NSRunningApplication(processIdentifier: pid)?.activate()
    if await waitFrontmost(pid: pid, ms: 800) { return }
    if let url = WindowLocator.appURL(bundleID) {
      let cfg = NSWorkspace.OpenConfiguration()
      cfg.activates = true
      NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
    }
    if await waitFrontmost(pid: pid, ms: 1500) { return }
    throw MirrorError.notFrontmost
  }

  private static func waitFrontmost(pid: pid_t, ms: Int) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(ms) / 1000)
    while Date() < deadline {
      if isFrontmost(pid: pid) {
        try? await Task.sleep(for: .milliseconds(120))  // let the window take key status
        return true
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return false
  }

  /// True when `name` refers to a blocked app. Matches either way round, so
  /// blocking "Example Bank" also refuses "example bank app" and "Example Bank".
  public static func isBlocked(_ name: String, blocked: [String]) -> Bool {
    let n = TextMatch.normalize(name)
    guard !n.isEmpty else { return false }
    return blocked.map(TextMatch.normalize).contains { b in
      !b.isEmpty && (n.contains(b) || (n.count >= 4 && b.contains(n)))
    }
  }
}
