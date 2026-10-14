import AppKit
import ApplicationServices
import CoreGraphics

/// Low-level CGEvent posting. Callers are responsible for the safety checks in
/// `Safety` (frontmost app, point inside the phone) before anything here runs.
enum Input {
  private static func source() -> CGEventSource? { CGEventSource(stateID: .combinedSessionState) }

  /// Tags the event as ours so the kill switch can tell it from the user's input.
  private static func post(_ e: CGEvent) {
    e.setIntegerValueField(.eventSourceUserData, value: UserActivityMonitor.marker)
    e.post(tap: .cghidEventTap)
    posted.increment()
  }

  /// Counts posted events, so a failed action can tell whether anything reached the phone.
  static let posted = Counter()

  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
  }

  static func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

  /// Moves the cursor with a posted event. CGWarpMouseCursorPosition would also work,
  /// but it suppresses mouse events for ~250 ms, so the next action's moves get dropped.
  static func moveCursor(_ p: CGPoint) {
    mouse(.mouseMoved, p)
  }

  static func mouse(_ type: CGEventType, _ p: CGPoint, delta: CGPoint = .zero) {
    guard let e = CGEvent(mouseEventSource: source(), mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
    e.setIntegerValueField(.mouseEventClickState, value: 1)
    // Receivers that track relative motion (like iPhone Mirroring's touch translation) read these.
    e.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
    e.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
    post(e)
  }

  static func tap(_ p: CGPoint, holdMs: Int, guard g: AbortGuard) async throws {
    mouse(.mouseMoved, p); 
    try await g.sleep(ms: 40)
    mouse(.leftMouseDown, p)
    // Hold in short slices so Esc / a mouse move can cut a long press short.
    var held = 0
    while held < holdMs {
      let slice = min(50, holdMs - held)
      do { try await g.sleep(ms: slice) } catch { mouse(.leftMouseUp, p); throw error }
      held += slice
    }
    mouse(.leftMouseUp, p)
  }

  static func drag(from a: CGPoint, to b: CGPoint, ms: Int, guard g: AbortGuard) async throws {
    mouse(.mouseMoved, a)
    try await g.sleep(ms: 30)
    mouse(.leftMouseDown, a)
    let steps = max(4, ms / 16)
    var last = a
    for i in 1...steps {
      let t = Double(i) / Double(steps)
      let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
      do { try await g.sleep(ms: max(1, ms / steps)) } catch { mouse(.leftMouseUp, last); throw error }
      mouse(.leftMouseDragged, p, delta: CGPoint(x: p.x - last.x, y: p.y - last.y)); last = p
    }
    try? await Task.sleep(for: .milliseconds(30))
    mouse(.leftMouseUp, b)
  }

  /// Plain mouse-wheel scroll in pixel units at `p`. iPhone Mirroring ignores
  /// trackpad-style events (continuous, with began/changed/ended phases), so none are set.
  static func scroll(at p: CGPoint, dx: Double, dy: Double, guard g: AbortGuard) async throws {
    mouse(.mouseMoved, p)
    try await g.sleep(ms: 60)
    let steps = max(1, Int((max(abs(dx), abs(dy)) / 20).rounded(.up)))
    for _ in 0..<steps {
      guard let e = CGEvent(
        scrollWheelEvent2Source: source(), units: .pixel, wheelCount: 2,
        wheel1: Int32((dy / Double(steps)).rounded()), wheel2: Int32((dx / Double(steps)).rounded()), wheel3: 0
      ) else { continue }
      e.location = p
      post(e)
      try await g.sleep(ms: 16)
    }
  }

  static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
      guard let e = CGEvent(keyboardEventSource: source(), virtualKey: code, keyDown: down) else { continue }
      e.flags = flags
      post(e)
    }
  }

  /// Modifier key down, key with flags, modifier up: what a real keyboard sends.
  static func chord(_ code: CGKeyCode, modifier: CGKeyCode, flags: CGEventFlags) {
    for (k, down, f) in [(modifier, true, flags), (code, true, flags), (code, false, flags), (modifier, false, CGEventFlags())] {
      guard let e = CGEvent(keyboardEventSource: source(), virtualKey: k, keyDown: down) else { continue }
      e.flags = f
      post(e)
    }
  }

  /// Types with real key codes (US layout). iPhone Mirroring forwards hardware keys,
  /// so this is the most faithful path for ASCII.
  static func typeKeys(_ text: String, guard g: AbortGuard) async throws {
    for ch in text {
      guard let (code, shift) = Keys.ascii[ch] else { continue }
      key(code, flags: shift ? .maskShift : [])
      try await g.sleep(ms: 12)
    }
  }

  /// Keyboard events carrying a Unicode string (no key code).
  static func typeUnicode(_ text: String, guard g: AbortGuard) async throws {
    for ch in text {
      let units = Array(String(ch).utf16)
      for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: source(), virtualKey: 0, keyDown: down) else { continue }
        e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        post(e)
      }
      try await g.sleep(ms: 12)
    }
  }

  /// Puts `text` on the Mac clipboard, presses ⌘V, then restores the old clipboard.
  /// Works for any script (e.g. Mongolian Cyrillic) regardless of the iPhone's keyboard layout.
  static func paste(_ text: String, pid: pid_t, guard g: AbortGuard) async throws {
    let pb = NSPasteboard.general
    let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
      item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
    }
    pb.clearContents()
    pb.setString(text, forType: .string)
    defer {
      pb.clearContents()
      let items = saved.map { pairs -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (t, d) in pairs { item.setData(d, forType: t) }
        return item
      }
      if !items.isEmpty { pb.writeObjects(items) }
    }
    try await g.sleep(ms: 150)
    // A synthetic ⌘V arrives on the iPhone as a bare "v", so press the app's own
    // Edit › Paste item; fall back to a full ⌘-down / V / ⌘-up chord.
    if !pressMenuItem(pid: pid, title: "Paste") {
      chord(Keys.v, modifier: Keys.command, flags: .maskCommand)
    }
    // The iPhone pulls the clipboard asynchronously; give it time before restoring.
    try? await Task.sleep(for: .milliseconds(900))
  }

  /// Presses a menu item by title through Accessibility. Searches every menu.
  static func pressMenuItem(pid: pid_t, title: String) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    var bar: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success,
          let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
    // swiftlint:disable:next force_cast
    return pressMenu(bar as! AXUIElement, title: title, depth: 0)
  }

  private static func pressMenu(_ el: AXUIElement, title: String, depth: Int) -> Bool {
    guard depth < 5 else { return false }
    var kids: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
          let children = kids as? [AXUIElement] else { return false }
    for child in children {
      var role: CFTypeRef?, t: CFTypeRef?
      AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
      AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &t)
      if (role as? String) == kAXMenuItemRole, (t as? String) == title {
        return AXUIElementPerformAction(child, kAXPressAction as CFString) == .success
      }
      if pressMenu(child, title: title, depth: depth + 1) { return true }
    }
    return false
  }
}

public enum Keys {
  static let v: CGKeyCode = 9
  static let command: CGKeyCode = 55

  public static let named: [String: CGKeyCode] = [
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
    "escape": 53, "esc": 53, "forwarddelete": 117,
    "left": 123, "right": 124, "down": 125, "up": 126,
  ]

  /// US ANSI layout: character → (key code, needs shift).
  public static let ascii: [Character: (CGKeyCode, Bool)] = {
    var m: [Character: (CGKeyCode, Bool)] = [:]
    let plain: [(Character, CGKeyCode)] = [
      ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
      ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19),
      ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28),
      ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38),
      ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47),
      ("`", 50), (" ", 49), ("\n", 36), ("\t", 48),
    ]
    for (c, k) in plain { m[c] = (k, false) }
    for c in "abcdefghijklmnopqrstuvwxyz" { m[Character(c.uppercased())] = (m[c]!.0, true) }
    let shifted: [(Character, Character)] = [
      ("!", "1"), ("@", "2"), ("#", "3"), ("$", "4"), ("%", "5"), ("^", "6"), ("&", "7"), ("*", "8"),
      ("(", "9"), (")", "0"), ("_", "-"), ("+", "="), ("{", "["), ("}", "]"), ("|", "\\"), (":", ";"),
      ("\"", "'"), ("<", ","), (">", "."), ("?", "/"), ("~", "`"),
    ]
    for (s, base) in shifted { m[s] = (m[base]!.0, true) }
    return m
  }()

  public static func typable(_ text: String) -> Bool { text.allSatisfy { ascii[$0] != nil } }

  /// "return", "cmd+a", "shift+tab" → key code + modifier flags.
  public static func parse(_ spec: String) -> (CGKeyCode, CGEventFlags)? {
    var parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
    guard let last = parts.popLast(), !last.isEmpty else { return nil }
    var flags: CGEventFlags = []
    for p in parts {
      switch p {
      case "cmd", "command": flags.insert(.maskCommand)
      case "shift": flags.insert(.maskShift)
      case "opt", "option", "alt": flags.insert(.maskAlternate)
      case "ctrl", "control": flags.insert(.maskControl)
      default: return nil
      }
    }
    if let code = named[last] { return (code, flags) }
    if last.count == 1, let (code, shift) = ascii[Character(last)] {
      return (code, shift ? flags.union(.maskShift) : flags)
    }
    return nil
  }
}
