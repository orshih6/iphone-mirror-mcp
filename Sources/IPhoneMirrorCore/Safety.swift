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

/// Watches the session's mouse and keyboard events with an event tap.
/// Every event this tool posts carries `marker` in `eventSourceUserData`, so any
/// event without it came from the user. (Comparing cursor positions does not work:
/// the iOS pointer snaps toward buttons, and macOS counts posted events as hardware.)
///
/// While focus is borrowed in background mode (`hold`), the user's keys, clicks and
/// scrolls are held back instead of reaching the phone, then replayed to their own app
/// by `release`. Esc still aborts. A hold always expires, so input is never stuck.
final class UserActivityMonitor: @unchecked Sendable {
  static let shared = UserActivityMonitor()
  static let marker: Int64 = 0x6950_6D69  // "iPmi"

  private let lock = NSLock()
  private var started: Date?
  private var last: (Date, String)?
  private var holdUntil: Date?
  private var held: [CGEvent] = []
  fileprivate var tap: CFMachPort?

  func start() {
    lock.lock()
    defer { lock.unlock() }
    guard started == nil else { return }
    started = Date()
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

  /// Seconds since the user last moved the mouse or pressed a key. Before the tap has
  /// seen anything, counts from when it started, so a fresh process cannot call the user idle.
  func idleSeconds() -> TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    let since = max(last?.0 ?? .distantPast, started ?? Date())
    return Date().timeIntervalSince(since)
  }

  /// Holds the user's input for at most `seconds`.
  func hold(seconds: Double) {
    lock.lock()
    holdUntil = Date().addingTimeInterval(seconds)
    lock.unlock()
  }

  /// Ends the hold and replays what was held to whatever app is now frontmost.
  func release() {
    lock.lock()
    let events = held
    held = []
    holdUntil = nil
    lock.unlock()
    for e in events { e.post(tap: .cghidEventTap) }
    if !events.isEmpty { Log.info("replayed \(events.count) held user events") }
  }

  /// Called from the tap for a user event. Returns false when the event is held back.
  /// Releases and modifier changes alone are not activity (`activity: false`), but are
  /// held with the rest so a held key-down is never replayed without its key-up.
  fileprivate func user(_ type: CGEventType, _ event: CGEvent, activity: Bool) -> Bool {
    let isEsc = type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53
    lock.lock()
    defer { lock.unlock() }
    guard let until = holdUntil, until > Date() else {
      if activity { last = (Date(), isEsc ? "Esc pressed" : type == .keyDown ? "key pressed" : "mouse moved") }
      return true
    }
    if isEsc {
      last = (Date(), "Esc pressed")
    } else if ![.mouseMoved, .leftMouseDragged, .rightMouseDragged].contains(type), let copy = event.copy() {
      held.append(copy)  // a moved cursor needs no replay
    }
    return false
  }

  private static func runTap() {
    let types: [CGEventType] = [
      .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .leftMouseDragged,
      .rightMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged,
    ]
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    // An active tap at the HID level can hold events back before any app sees them
    // (iPhone Mirroring reads input below the session level); fall back to watching only.
    let tap = CGEvent.tapCreate(
      tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: mask, callback: userActivityCallback, userInfo: nil
    ) ?? CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
      eventsOfInterest: mask, callback: userActivityCallback, userInfo: nil
    )
    guard let tap else {
      Log.info("kill switch: could not create event tap; only Esc will abort")
      return
    }
    shared.tap = tap
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    CFRunLoopRun()
  }
}

private func userActivityCallback(
  _: CGEventTapProxy, type: CGEventType, event: CGEvent, _: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  switch type {
  case .tapDisabledByTimeout, .tapDisabledByUserInput:
    if let tap = UserActivityMonitor.shared.tap { CGEvent.tapEnable(tap: tap, enable: true) }
  default:
    if event.getIntegerValueField(.eventSourceUserData) != UserActivityMonitor.marker {
      let activity = ![.keyUp, .flagsChanged, .leftMouseUp, .rightMouseUp].contains(type)
      if !UserActivityMonitor.shared.user(type, event, activity: activity) { return nil }
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
    Log.info("activate: plain activate() ignored; reopening iPhone Mirroring")
    if let url = WindowLocator.appURL(bundleID) {
      let cfg = NSWorkspace.OpenConfiguration()
      cfg.activates = true
      NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
    }
    if await waitFrontmost(pid: pid, ms: 1500) { return }
    throw MirrorError.notFrontmost
  }

  /// Text iPhone Mirroring shows instead of the phone (its own lock screen, "connecting", …),
  /// read through Accessibility. The live phone view exposes no text, so nil means mirroring.
  /// Its lock screen has a Mac password field: input must never be sent there.
  static func windowMessage(pid: pid_t) -> String? {
    var windows: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windows) == .success,
          let list = windows as? [AXUIElement] else { return nil }
    var texts: [String] = []
    func walk(_ el: AXUIElement, _ depth: Int) {
      guard depth < 6 else { return }
      var role: CFTypeRef?, value: CFTypeRef?
      AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
      if (role as? String) == kAXStaticTextRole, AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
         let t = value as? String, !t.isEmpty { texts.append(t) }
      var kids: CFTypeRef?
      if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success, let children = kids as? [AXUIElement] {
        for c in children { walk(c, depth + 1) }
      }
    }
    for w in list { walk(w, 0) }
    return texts.isEmpty ? nil : texts.joined(separator: " ")
  }

  /// Pid of the app that owns the top-most normal window.
  static func frontmostPid() -> pid_t? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] else { return nil }
    return list.first { ($0[kCGWindowLayer as String] as? Int) == 0 }
      .flatMap { $0[kCGWindowOwnerPID as String] as? Int }.map(pid_t.init)
  }

  /// Gives focus back to the app the user was in. Plain `activate()` is ignored when
  /// the caller is not the active app, so this uses the (deprecated) forcing option.
  static func handBack(to pid: pid_t) async {
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
    app.activate(options: .activateIgnoringOtherApps)
    _ = await waitFrontmost(pid: pid, ms: 600)
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
