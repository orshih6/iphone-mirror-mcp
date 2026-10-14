import AppKit
import CoreGraphics
import Foundation

public struct ShotOptions: Sendable {
  public var width: Int?
  public var region: Rect?
  public var gray = false
  public var png = false
  public var force = false
  public init(width: Int? = nil, region: Rect? = nil, gray: Bool = false, png: Bool = false, force: Bool = false) {
    self.width = width; self.region = region; self.gray = gray; self.png = png; self.force = force
  }
}

public enum Shot: Sendable {
  case unchanged
  case image(data: Data, mimeType: String, width: Int, height: Int)
}

public struct ActOptions: Sendable {
  /// Return one small screenshot after the action.
  public var returnShot = false
  /// Wait until the screen settles. Costs a few captures, and each capture is
  /// reported to the iPhone as a screenshot.
  public var wait = true
  public init(returnShot: Bool = false, wait: Bool = true) {
    self.returnShot = returnShot; self.wait = wait
  }
}

public struct ActionResult: Sendable {
  public var text: String
  public var shot: Shot?
}

public enum TypeMethod: String, Sendable { case auto, keys, unicode, paste }
public enum Direction: String, Sendable { case up, down, left, right }

/// All tool behaviour, shared by the MCP server and the CLI. One instance keeps the
/// "last screenshot" view so coordinates always refer to the image Claude last saw.
public actor Controller {
  public let config: Config
  private var view: ViewMapping?
  private var lastShot: (key: String, thumb: Thumb)?
  /// Phone content inside the window, in window points, keyed by window size.
  private var contentCache: (size: CGSize, rect: CGRect)?

  public init(config: Config) { self.config = config }

  /// Back to the default full view, as if no screenshot had been taken.
  public func resetView() { view = nil }

  // MARK: - Frames

  private struct Frame {
    let win: LocatedWindow
    let image: CGImage
    /// Image pixels.
    let contentPx: CGRect
    /// Global screen points.
    let content: Rect
  }

  private func frame(scale: Double? = nil, requirePhone: Bool = true) async throws -> Frame {
    // macOS refuses window capture while the lock screen is up, with an unhelpful error.
    if Safety.macLocked() { throw MirrorError.macLocked }
    let win = try await WindowLocator.locate(config.bundleID)
    let image = try await Capture.window(win, scale: scale)
    let s = Double(image.width) / win.frame.width
    let local: CGRect
    if let c = contentCache, c.size == win.frame.size {
      local = c.rect
    } else {
      let px = Capture.contentBounds(image)
      let i = config.cropInsets
      local = CGRect(
        x: px.minX / s + i.left, y: px.minY / s + i.top,
        width: px.width / s - i.left - i.right, height: px.height / s - i.top - i.bottom
      )
      contentCache = (win.frame.size, local)
    }
    let contentPx = CGRect(x: local.minX * s, y: local.minY * s, width: local.width * s, height: local.height * s)
    let f = Frame(
      win: win, image: image, contentPx: contentPx,
      content: Rect(x: win.frame.minX + local.minX, y: win.frame.minY + local.minY, w: local.width, h: local.height)
    )
    if requirePhone, !looksLikePhone(local.size) {
      throw MirrorError.notMirroring(windowText(image))
    }
    return f
  }

  private func windowText(_ image: CGImage) -> String {
    let lines = (try? OCR.recognize(image, accurate: false, languages: config.ocrLanguages)) ?? []
    return String(lines.map(\.text).joined(separator: " ").prefix(160))
  }

  private var defaultWidth: Int { clampWidth(config.defaultWidth) }
  private func clampWidth(_ w: Int) -> Int { min(max(w, 240), 600) }

  /// The view coordinates currently refer to: the last screenshot, else the default full view.
  private func currentView(_ f: Frame) -> ViewMapping {
    currentView(Geometry(win: f.win, content: f.content))
  }

  // MARK: - status / launch

  public func status() async -> String {
    var out: [String] = []
    let host = Permissions.hostApp()
    let sr = Permissions.screenRecording, ax = Permissions.accessibility
    out.append("permissions: screen_recording=\(sr ? "ok" : "MISSING") accessibility=\(ax ? "ok" : "MISSING")"
      + (sr && ax ? "" : " (grant to \"\(host)\")"))
    guard WindowLocator.appURL(config.bundleID) != nil else {
      out.append("app: not installed (\(config.bundleID))")
      return out.joined(separator: "\n")
    }
    guard WindowLocator.runningApp(config.bundleID) != nil else {
      out.append("app: not running")
      return out.joined(separator: "\n")
    }
    out.append("app: running")
    if Safety.macLocked() {
      out.append("mac: screen locked; capture and input are unavailable until it is unlocked")
      return out.joined(separator: "\n")
    }
    guard sr else { return out.joined(separator: "\n") }
    do {
      let f = try await frame(requirePhone: false)
      let w = f.win.frame
      out.append("window: \(Int(w.width))x\(Int(w.height)) at \(Int(w.minX)),\(Int(w.minY))\(Safety.isFrontmost(pid: f.win.pid) ? " frontmost" : "")")
      if looksLikePhone(CGSize(width: f.content.w, height: f.content.h)) {
        let isDefault = view == nil
        let v = currentView(f)
        out.append("phone: mirroring, \(Int(f.content.w))x\(Int(f.content.h)) pt; coordinates: \(v.width)x\(v.height) image px\(isDefault ? " (default view)" : "")")
      } else {
        let text = windowText(f.image)
        out.append("phone: not mirroring (locked, in use, not nearby, or connecting)" + (text.isEmpty ? "" : " — window says \"\(text)\""))
      }
    } catch {
      out.append("window: \(error)")
    }
    return out.joined(separator: "\n")
  }

  public func launch() async throws -> String {
    if WindowLocator.runningApp(config.bundleID) == nil {
      guard let url = WindowLocator.appURL(config.bundleID) else { throw MirrorError.appNotInstalled(config.bundleID) }
      let cfg = NSWorkspace.OpenConfiguration()
      try await launchApp(url, cfg)
    }
    let deadline = Date().addingTimeInterval(15)
    var lastError: Error = MirrorError.windowNotFound
    while Date() < deadline {
      do {
        let f = try await frame(requirePhone: false)
        try? await Safety.activate(bundleID: config.bundleID, pid: f.win.pid)
        if looksLikePhone(CGSize(width: f.content.w, height: f.content.h)) {
          let v = currentView(f)
          return "ok: mirroring, view \(v.width)x\(v.height)"
        }
        lastError = MirrorError.notMirroring(windowText(f.image))
      } catch let e as MirrorError {
        if case .permission = e { throw e }
        lastError = e
      }
      try await Task.sleep(for: .milliseconds(500))
    }
    throw lastError
  }

  // MARK: - screenshot / OCR

  public func screenshot(_ o: ShotOptions) async throws -> Shot {
    let f = try await frame()
    let base = currentView(f)
    let region = o.region.map(base.subRegion) ?? .unit
    guard region.w > 0.001, region.h > 0.001 else { throw MirrorError.badArgument("region is empty or outside the image") }
    let width = clampWidth(o.width ?? defaultWidth)
    let v = ViewMapping.make(contentSize: CGSize(width: f.content.w, height: f.content.h), region: region, width: width)
    guard let crop = Capture.crop(f.image, content: f.contentPx, region: region) else {
      throw MirrorError.captureFailed("crop failed")
    }
    view = v
    let thumb = Capture.thumb(crop)
    let key = "\(region)|\(width)|\(o.gray)|\(o.png)"
    if !o.force, let last = lastShot, last.key == key, last.thumb.same(thumb) {
      Log.info("screenshot unchanged \(v.width)x\(v.height)")
      return .unchanged
    }
    lastShot = (key, thumb)
    guard let small = Capture.scaled(crop, width: v.width, height: v.height, gray: o.gray),
          let data = Capture.encode(small, png: o.png, quality: config.jpegQuality) else {
      throw MirrorError.captureFailed("encode failed")
    }
    Log.info("screenshot \(v.width)x\(v.height) \(o.png ? "png" : "jpeg")\(o.gray ? " gray" : "") \(data.count) bytes")
    return .image(data: data, mimeType: o.png ? "image/png" : "image/jpeg", width: v.width, height: v.height)
  }

  /// OCR of the current view (or a sub-rect of it), boxes in view image pixels.
  private func ocr(region: Rect? = nil, accurate: Bool) async throws -> (ViewMapping, [TextBox]) {
    let f = try await frame()
    let v = currentView(f)
    let sub = region ?? Rect(x: 0, y: 0, w: Double(v.width), h: Double(v.height))
    let norm = v.subRegion(sub)
    guard norm.w > 0.001, norm.h > 0.001, let crop = Capture.crop(f.image, content: f.contentPx, region: norm) else {
      throw MirrorError.badArgument("region is empty or outside the image")
    }
    // The clipped sub-rect in image pixels, to map boxes back.
    let sx = (norm.x - v.region.x) / v.region.w * Double(v.width)
    let sy = (norm.y - v.region.y) / v.region.h * Double(v.height)
    let sw = norm.w / v.region.w * Double(v.width)
    let sh = norm.h / v.region.h * Double(v.height)
    let boxes = try OCR.recognize(crop, accurate: accurate, languages: config.ocrLanguages).map { b in
      TextBox(text: b.text, rect: Rect(x: sx + b.rect.x * sw, y: sy + b.rect.y * sh, w: b.rect.w * sw, h: b.rect.h * sh),
              confidence: b.confidence)
    }
    return (v, boxes)
  }

  public func readScreen(region: Rect?, accurate: Bool) async throws -> String {
    let (v, boxes) = try await ocr(region: region, accurate: accurate)
    // cx,cy is the box center (the same point find_text reports and tap expects).
    // Fast mode reports the same confidence for every line, so it is only sent for accurate.
    let items = boxes.map { b in
      let c = b.center
      let base = "\(json(b.text)),\(c.x),\(c.y),\(Int(b.rect.w.rounded())),\(Int(b.rect.h.rounded()))"
      return accurate ? "[\(base),\(Int((b.confidence * 100).rounded()))]" : "[\(base)]"
    }
    let fields = accurate ? #"["text","cx","cy","w","h","conf"]"# : #"["text","cx","cy","w","h"]"#
    return "{\"view\":[\(v.width),\(v.height)],\"fields\":\(fields),\"items\":[\(items.joined(separator: ","))]}"
  }

  /// Fast OCR first; retries in accurate mode when nothing matches.
  private func matches(_ text: String, exact: Bool) async throws -> (ViewMapping, [TextBox], [TextBox]) {
    var (v, boxes) = try await ocr(accurate: false)
    var found = TextMatch.find(text, in: boxes, exact: exact)
    if found.isEmpty {
      (v, boxes) = try await ocr(accurate: true)
      found = TextMatch.find(text, in: boxes, exact: exact)
    }
    return (v, boxes, found)
  }

  public func findText(_ text: String, exact: Bool) async throws -> String {
    let (v, _, found) = try await matches(text, exact: exact)
    if found.isEmpty { return "no match" }
    let list = found.map { "[\(json($0.text)),\($0.center.x),\($0.center.y)]" }
    return "{\"view\":[\(v.width),\(v.height)],\"matches\":[\(list.joined(separator: ","))]}"
  }

  /// `text` may list alternatives separated by "|"; the first one seen wins.
  public func waitForText(_ text: String, timeoutMs: Int) async throws -> String {
    let wanted = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    func hit(_ boxes: [TextBox]) -> TextBox? {
      for w in wanted { if let h = TextMatch.find(w, in: boxes, exact: false).first { return h } }
      return nil
    }
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    repeat {
      let (_, boxes) = try await ocr(accurate: false)
      if let h = hit(boxes) { return "found \(json(h.text)) at \(h.center.x),\(h.center.y)" }
      if CGEventSource.keyState(.hidSystemState, key: 53) { throw MirrorError.aborted("Esc pressed") }
      try await Task.sleep(for: .milliseconds(250))
    } while Date() < deadline
    // Fast OCR misreads small or stylised text; one accurate pass before giving up.
    let (_, boxes) = try await ocr(accurate: true)
    if let h = hit(boxes) { return "found \(json(h.text)) at \(h.center.x),\(h.center.y)" }
    throw MirrorError.timeout("timeout: \"\(text)\" not seen in \(timeoutMs) ms. Visible: " + boxes.map(\.text).prefix(25).joined(separator: " | "))
  }

  // MARK: - input

  /// Where the phone is on screen, without capturing when the window size is unchanged.
  /// Every capture is reported to the iPhone as a screenshot (apps such as Pinduoduo
  /// react to that), so input actions avoid capturing whenever they can.
  private struct Geometry {
    let win: LocatedWindow
    let content: Rect
  }

  private func geometry() async throws -> Geometry {
    let win = try await WindowLocator.locate(config.bundleID)
    if let c = contentCache, c.size == win.frame.size, looksLikePhone(c.rect.size) {
      return Geometry(win: win, content: Rect(
        x: win.frame.minX + c.rect.minX, y: win.frame.minY + c.rect.minY, w: c.rect.width, h: c.rect.height
      ))
    }
    let f = try await frame()
    return Geometry(win: f.win, content: f.content)
  }

  private func currentView(_ g: Geometry) -> ViewMapping {
    let v = view ?? ViewMapping(region: .unit, width: defaultWidth, height: 0)
    let fresh = ViewMapping.make(contentSize: CGSize(width: g.content.w, height: g.content.h), region: v.region, width: v.width)
    view = fresh
    return fresh
  }

  /// Every input action goes through here: permissions, frontmost, kill switch,
  /// cursor restore, then (unless `o.wait` is false) wait until the screen settles.
  private func act(_ geo: Geometry, _ o: ActOptions, _ body: (AbortGuard) async throws -> Void) async throws -> ActionResult {
    try Permissions.requireAccessibility()
    let saved = Input.cursor()
    // Another app can grab focus between activation and the first event (e.g. the
    // terminal that launched us). If nothing was sent yet, take focus back once and retry.
    for attempt in 0..<2 {
      try await Safety.activate(bundleID: config.bundleID, pid: geo.win.pid)
      let before = Input.posted.value
      do {
        try await body(AbortGuard(pid: geo.win.pid))
        break
      } catch let MirrorError.aborted(why) where why.contains("lost focus") && attempt == 0 && Input.posted.value == before {
        Log.info("focus lost before any input; retrying")
        continue
      } catch {
        if config.restoreMouse { Input.moveCursor(saved) }
        throw error
      }
    }
    if config.restoreMouse { Input.moveCursor(saved) }
    if o.wait { await waitStable() }
    let shot = o.returnShot ? try await screenshot(ShotOptions(force: true)) : nil
    return ActionResult(text: "ok", shot: shot)
  }

  private func point(_ v: ViewMapping, _ geo: Geometry, x: Double, y: Double, normalized: Bool) throws -> CGPoint {
    let (ix, iy) = normalized ? (x * Double(v.width), y * Double(v.height)) : (x, y)
    guard let p = v.screenPoint(x: ix, y: iy, content: geo.content) else {
      throw MirrorError.outsidePhone(x: ix, y: iy, width: v.width, height: v.height)
    }
    return p
  }

  private func waitStable() async {
    try? await Task.sleep(for: .milliseconds(80))
    let deadline = Date().addingTimeInterval(Double(config.stableTimeoutMs) / 1000)
    var prev = await quickThumb()
    while Date() < deadline {
      try? await Task.sleep(for: .milliseconds(config.stableIntervalMs))
      let cur = await quickThumb()
      if let p = prev, let c = cur, p.settled(c) { return }
      prev = cur
    }
  }

  private func quickThumb() async -> Thumb? {
    guard let f = try? await frame(scale: 0.5, requirePhone: false),
          let crop = Capture.crop(f.image, content: f.contentPx, region: .unit) else { return nil }
    return Capture.thumb(crop)
  }

  public func tap(x: Double, y: Double, normalized: Bool, _ o: ActOptions = .init()) async throws -> ActionResult {
    let geo = try await geometry()
    let p = try point(currentView(geo), geo, x: x, y: y, normalized: normalized)
    return try await act(geo, o) { g in try await Input.tap(p, holdMs: 60, guard: g) }
  }

  public func tapText(_ text: String, index: Int?, _ o: ActOptions = .init()) async throws -> ActionResult {
    if Safety.isBlocked(text, blocked: config.blockedApps) { throw MirrorError.blocked(text) }
    let (v, boxes, found) = try await matches(text, exact: false)
    if found.isEmpty { throw MirrorError.noMatch(text, seen: boxes.map(\.text)) }
    guard let hit = TextMatch.pick(text, from: found, boxes: boxes, index: index) else {
      if let index { throw MirrorError.badArgument("index \(index) out of range (0..<\(found.count))") }
      throw MirrorError.ambiguous(text, matches: found.map { "\($0.text)@\($0.center.x),\($0.center.y)" })
    }
    let geo = try await geometry()
    let c = hit.center
    guard let p = v.screenPoint(x: Double(c.x), y: Double(c.y), content: geo.content) else {
      throw MirrorError.outsidePhone(x: Double(c.x), y: Double(c.y), width: v.width, height: v.height)
    }
    var r = try await act(geo, o) { g in try await Input.tap(p, holdMs: 60, guard: g) }
    r.text = "ok: tapped \(json(hit.text)) at \(c.x),\(c.y)"
    return r
  }

  public func longPress(x: Double, y: Double, ms: Int, normalized: Bool, _ o: ActOptions = .init()) async throws -> ActionResult {
    let geo = try await geometry()
    let p = try point(currentView(geo), geo, x: x, y: y, normalized: normalized)
    return try await act(geo, o) { g in try await Input.tap(p, holdMs: max(ms, 100), guard: g) }
  }

  public func swipe(from: (Double, Double), to: (Double, Double), ms: Int, normalized: Bool, _ o: ActOptions = .init()) async throws -> ActionResult {
    let geo = try await geometry()
    let v = currentView(geo)
    let a = try point(v, geo, x: from.0, y: from.1, normalized: normalized)
    let b = try point(v, geo, x: to.0, y: to.1, normalized: normalized)
    return try await act(geo, o) { g in try await Input.drag(from: a, to: b, ms: max(ms, 50), guard: g) }
  }

  /// `amount` is in image pixels (default: half the view height).
  public func scroll(_ dir: Direction, amount: Double?, _ o: ActOptions = .init()) async throws -> ActionResult {
    let geo = try await geometry()
    let v = currentView(geo)
    let p = try point(v, geo, x: Double(v.width) / 2, y: Double(v.height) / 2, normalized: false)
    // Measured on iOS 26: a wheel delta of N points moves content ~0.74 N, so scale up
    // to make `amount` the distance the content actually moves.
    let pts = (amount ?? Double(v.height) / 2) * v.pointsPerPixel(content: geo.content) * 1.35
    // Negative wheel deltas reveal content further down / to the right.
    let (dx, dy): (Double, Double) = switch dir {
    case .down: (0, -pts)
    case .up: (0, pts)
    case .right: (-pts, 0)
    case .left: (pts, 0)
    }
    return try await act(geo, o) { g in try await Input.scroll(at: p, dx: dx, dy: dy, guard: g) }
  }

  public func typeText(_ text: String, method: TypeMethod, _ o: ActOptions = .init()) async throws -> ActionResult {
    let geo = try await geometry()
    // iPhone Mirroring's Edit › Paste is disabled, so non-ASCII goes as Unicode key events.
    let m: TypeMethod = method == .auto ? (Keys.typable(text) ? .keys : .unicode) : method
    var r = try await act(geo, o) { g in
      switch m {
      case .keys, .auto: try await Input.typeKeys(text, guard: g)
      case .unicode: try await Input.typeUnicode(text, guard: g)
      case .paste: try await Input.paste(text, pid: geo.win.pid, guard: g)
      }
    }
    r.text = "ok (\(m.rawValue))"
    return r
  }

  public func pressKey(_ spec: String, _ o: ActOptions = .init()) async throws -> ActionResult {
    guard let (code, flags) = Keys.parse(spec) else {
      throw MirrorError.badArgument("unknown key \"\(spec)\"; use return, delete, escape, tab, space, up, down, left, right, or cmd+<key>")
    }
    let geo = try await geometry()
    return try await act(geo, o) { g in try g.check(); Input.key(code, flags: flags) }
  }

  public enum MenuAction: Sendable { case home, appSwitcher, spotlight }

  /// Uses the iPhone Mirroring menu item when Accessibility can find it, else ⌘1/⌘2/⌘3.
  public func menu(_ action: MenuAction, _ o: ActOptions = .init()) async throws -> ActionResult {
    let (title, key): (String, CGKeyCode) = switch action {
    case .home: (config.menuHome, 18)
    case .appSwitcher: (config.menuAppSwitcher, 19)
    case .spotlight: (config.menuSpotlight, 20)
    }
    let geo = try await geometry()
    let how = Box("menu")
    func press() async throws -> ActionResult {
      try await act(geo, o) { g in
        try g.check()
        if !Input.pressMenuItem(pid: geo.win.pid, title: title) {
          how.value = "shortcut"
          Input.key(key, flags: .maskCommand)
        }
      }
    }
    // iOS drops the request when it arrives mid-animation (e.g. right after Home).
    // Spotlight and the App Switcher always change the screen, so retry once if it didn't.
    // The "before" frame must be taken once the screen is still; mid-animation it
    // would differ from the result even when the press was ignored.
    var before: Thumb?
    if action != .home {
      await waitStable()
      before = await quickThumb()
    }
    var r = try await press()
    for _ in 0..<2 {
      guard let b = before, let after = await quickThumb(), b.settled(after) else { break }
      Log.info("\(title) had no visible effect; retrying")
      try await Task.sleep(for: .milliseconds(700))
      r = try await press()
    }
    // Spotlight's search field takes focus after its animation; typed keys before that are lost.
    if action == .spotlight { try await Task.sleep(for: .milliseconds(600)) }
    Log.info("\(title) via \(how.value)")
    return r
  }

  public func openApp(_ name: String) async throws -> ActionResult {
    if Safety.isBlocked(name, blocked: config.blockedApps) { throw MirrorError.blocked(name) }
    // Spotlight sometimes swallows a step (timing inside iOS). Ending exactly where we
    // started means nothing opened: retry once, then say so instead of reporting "ok".
    let start = await quickThumb()
    for attempt in 1...2 {
      let r = try await openAppOnce(name)
      // "settled", not "same": a live widget on the Home Screen changes a cell or two.
      guard let start, let now = await quickThumb(), start.settled(now) else { return r }
      Log.info("open_app \(name): screen unchanged after attempt \(attempt)")
    }
    throw MirrorError.timeout("\"\(name)\" did not open (screen unchanged after 2 attempts)")
  }

  private func openAppOnce(_ name: String) async throws -> ActionResult {
    _ = try await menu(.spotlight)
    _ = try await typeText(name, method: .auto)
    // Spotlight fills its results asynchronously: wait until the name is listed in two
    // polls in a row, let the Top Hit settle, then Return opens it. (Tapping a match is
    // unreliable: Home Screen labels stay readable through Spotlight's translucent
    // background, including this app's own icon label.)
    let deadline = Date().addingTimeInterval(4)
    var seenBefore = false, ready = false
    while Date() < deadline, !ready {
      try await Task.sleep(for: .milliseconds(300))
      let (_, boxes) = try await ocr(accurate: true)
      let seen = !TextMatch.find(name, in: boxes, exact: true).isEmpty
      ready = seen && seenBefore
      seenBefore = seen
    }
    guard ready else { throw MirrorError.timeout("Spotlight shows no app named \"\(name)\"; nothing was opened") }
    try await Task.sleep(for: .milliseconds(500))
    var r = try await pressKey("return")
    r.text = "ok: opened \(json(name)) via Spotlight"
    return r
  }
}

/// A mutable value shared with a closure that runs inside the actor.
private final class Box<T>: @unchecked Sendable {
  var value: T
  init(_ value: T) { self.value = value }
}

private func launchApp(_ url: URL, _ cfg: NSWorkspace.OpenConfiguration) async throws {
  try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
    NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
      if let error { c.resume(throwing: MirrorError.captureFailed("could not open iPhone Mirroring: \(error.localizedDescription)")) } else { c.resume() }
    }
  }
}

func json(_ s: String) -> String {
  guard let d = try? JSONEncoder().encode(s), let out = String(data: d, encoding: .utf8) else { return "\"\"" }
  return out
}
