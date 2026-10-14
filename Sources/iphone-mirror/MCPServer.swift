import Foundation
import IPhoneMirrorCore
import MCP

/// Read into the agent's context once per session, so keep it short.
let serverInstructions = """
Controls a real iPhone through the macOS iPhone Mirroring window.
Prefer read_screen / find_text / tap_text over screenshot; screenshot only when icons or layout matter.
x/y are pixels in the LAST screenshot (or the default view if none). Use region to zoom, not a bigger width.
Actions return text only; confirm with wait_for_text instead of a screenshot.
Each capture is reported to the iPhone as a screenshot; some apps react (e.g. share sheets). Chain taps with wait:false to capture less.
Never open banking or payment apps unless the user explicitly asks.
"""

private func obj(_ props: [String: Value], required: [String] = []) -> Value {
  var o: [String: Value] = ["type": "object", "properties": .object(props)]
  if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
  return .object(o)
}

private func prop(_ type: String, _ desc: String? = nil, enumValues: [String]? = nil) -> Value {
  var o: [String: Value] = ["type": .string(type)]
  if let desc { o["description"] = .string(desc) }
  if let enumValues { o["enum"] = .array(enumValues.map { .string($0) }) }
  return .object(o)
}

private let point = obj(["x": prop("number"), "y": prop("number")], required: ["x", "y"])
private let regionProp = obj(
  ["x": prop("number"), "y": prop("number"), "w": prop("number"), "h": prop("number")],
  required: ["x", "y", "w", "h"]
)
private let shotProp = prop("boolean", "Return one small screenshot after the action")
private let waitProp = prop("boolean", "false: skip the settle wait (fewer captures)")
private let normProp = prop("boolean", "x/y are 0..1 fractions of the image")

let tools: [Tool] = [
  Tool(name: "status", description: "Permissions, window and mirroring state.", inputSchema: obj([:])),
  Tool(name: "launch", description: "Open/focus iPhone Mirroring and wait until the phone is shown.", inputSchema: obj([:])),
  Tool(
    name: "screenshot",
    description: "Small JPEG of the phone screen, or \"unchanged\". Sets the coordinate space for x/y.",
    inputSchema: obj([
      "width": prop("integer", "240-600, default 320"),
      "region": regionProp,
      "gray": prop("boolean"),
      "format": prop("string", enumValues: ["jpeg", "png"]),
      "force": prop("boolean", "Send the image even if unchanged"),
    ])
  ),
  Tool(
    name: "read_screen",
    description: "OCR text as JSON items [text,cx,cy,w,h,conf]; cx,cy is the tappable center. No image.",
    inputSchema: obj(["region": regionProp, "fast": prop("boolean", "Faster but Latin-only and less reliable")])
  ),
  Tool(
    name: "find_text", description: "Find text on screen; returns center points.",
    inputSchema: obj(["text": prop("string"), "exact": prop("boolean")], required: ["text"])
  ),
  Tool(
    name: "tap", description: "Tap at x,y.",
    inputSchema: obj(["x": prop("number"), "y": prop("number"), "normalized": normProp, "return_screenshot": shotProp, "wait": waitProp], required: ["x", "y"])
  ),
  Tool(
    name: "tap_text", description: "Tap the center of on-screen text. Errors if 0 or several matches.",
    inputSchema: obj(["text": prop("string"), "index": prop("integer", "0-based, to pick among matches"), "return_screenshot": shotProp, "wait": waitProp], required: ["text"])
  ),
  Tool(
    name: "long_press", description: "Press and hold at x,y.",
    inputSchema: obj(["x": prop("number"), "y": prop("number"), "ms": prop("integer", "default 800"), "normalized": normProp, "return_screenshot": shotProp, "wait": waitProp], required: ["x", "y"])
  ),
  Tool(
    name: "swipe", description: "Drag from one point to another.",
    inputSchema: obj(["from": point, "to": point, "ms": prop("integer", "default 300"), "normalized": normProp, "return_screenshot": shotProp, "wait": waitProp], required: ["from", "to"])
  ),
  Tool(
    name: "scroll", description: "Scroll the screen with the scroll wheel.",
    inputSchema: obj([
      "direction": prop("string", enumValues: ["up", "down", "left", "right"]),
      "amount": prop("number", "image pixels, default half the screen"),
      "return_screenshot": shotProp, "wait": waitProp,
    ], required: ["direction"])
  ),
  Tool(
    name: "type_text", description: "Type text into the focused field (any language).",
    inputSchema: obj([
      "text": prop("string"),
      "method": prop("string", "auto: key codes for ASCII, Unicode events otherwise", enumValues: ["auto", "keys", "unicode", "paste"]),
      "return_screenshot": shotProp, "wait": waitProp,
    ], required: ["text"])
  ),
  Tool(
    name: "press_key", description: "Press return, delete, escape, tab, space, arrows, or cmd+<key>.",
    inputSchema: obj(["key": prop("string"), "return_screenshot": shotProp, "wait": waitProp], required: ["key"])
  ),
  Tool(name: "home", description: "Go to the Home Screen.", inputSchema: obj(["return_screenshot": shotProp, "wait": waitProp])),
  Tool(name: "app_switcher", description: "Open the App Switcher.", inputSchema: obj(["return_screenshot": shotProp, "wait": waitProp])),
  Tool(name: "spotlight", description: "Open Spotlight search.", inputSchema: obj(["return_screenshot": shotProp, "wait": waitProp])),
  Tool(name: "open_app", description: "Open an app by name via Spotlight.", inputSchema: obj(["name": prop("string")], required: ["name"])),
  Tool(
    name: "wait_for_text", description: "Poll OCR until text appears (no images). Stops at once on errors such as a locked Mac.",
    inputSchema: obj(["text": prop("string", "a|b waits for either"), "timeout_ms": prop("integer", "default 5000")], required: ["text"])
  ),
]

private struct Args {
  let raw: [String: Value]

  func string(_ k: String) -> String? { raw[k]?.stringValue }
  func bool(_ k: String) -> Bool { raw[k]?.boolValue ?? (raw[k]?.stringValue == "true") }
  func int(_ k: String) -> Int? { number(raw[k]).map { Int($0) } }
  func double(_ k: String) -> Double? { number(raw[k]) }

  func require(_ k: String) throws -> String {
    guard let s = string(k), !s.isEmpty else { throw MirrorError.badArgument("missing \"\(k)\"") }
    return s
  }

  func requireNumber(_ k: String) throws -> Double {
    guard let v = double(k) else { throw MirrorError.badArgument("missing number \"\(k)\"") }
    return v
  }

  func pt(_ k: String) throws -> (Double, Double) {
    if let o = raw[k]?.objectValue, let x = number(o["x"]), let y = number(o["y"]) { return (x, y) }
    if let a = raw[k]?.arrayValue, a.count == 2, let x = number(a[0]), let y = number(a[1]) { return (x, y) }
    throw MirrorError.badArgument("\"\(k)\" must be {x, y}")
  }

  func region() throws -> Rect? {
    guard let v = raw["region"], v != .null else { return nil }
    if let o = v.objectValue, let x = number(o["x"]), let y = number(o["y"]), let w = number(o["w"]), let h = number(o["h"]) {
      return Rect(x: x, y: y, w: w, h: h)
    }
    if let a = v.arrayValue, a.count == 4, let x = number(a[0]), let y = number(a[1]), let w = number(a[2]), let h = number(a[3]) {
      return Rect(x: x, y: y, w: w, h: h)
    }
    throw MirrorError.badArgument("\"region\" must be {x, y, w, h}")
  }

  private func number(_ v: Value?) -> Double? {
    guard let v else { return nil }
    if let d = v.doubleValue { return d }
    if let i = v.intValue { return Double(i) }
    if let s = v.stringValue { return Double(s) }
    return nil
  }
}

private func text(_ s: String) -> Tool.Content { .text(text: s, annotations: nil, _meta: nil) }

private func content(_ shot: Shot) -> [Tool.Content] {
  switch shot {
  case .unchanged:
    return [text("unchanged")]
  case let .image(data, mime, w, h):
    return [text("\(w)x\(h) \(data.count / 1024)KB"), .image(data: data.base64EncodedString(), mimeType: mime, annotations: nil, _meta: nil)]
  }
}

private func content(_ r: ActionResult) -> [Tool.Content] {
  [text(r.text)] + (r.shot.map { content($0).filter { if case .image = $0 { true } else { false } } } ?? [])
}

private func call(_ c: Controller, _ name: String, _ a: Args) async throws -> [Tool.Content] {
  let o = ActOptions(returnShot: a.bool("return_screenshot"), wait: a.raw["wait"]?.boolValue ?? true)
  switch name {
  case "status":
    return [text(await c.status())]
  case "launch":
    return [text(try await c.launch())]
  case "screenshot":
    let o = ShotOptions(width: a.int("width"), region: try a.region(), gray: a.bool("gray"),
                        png: a.string("format") == "png", force: a.bool("force"))
    return content(try await c.screenshot(o))
  case "read_screen":
    // Accurate is the default: garbled fast-mode text costs more tokens than the extra latency.
    let accurate = a.raw["accurate"]?.boolValue ?? !a.bool("fast")
    return [text(try await c.readScreen(region: try a.region(), accurate: accurate))]
  case "find_text":
    return [text(try await c.findText(try a.require("text"), exact: a.bool("exact")))]
  case "tap":
    return content(try await c.tap(x: try a.requireNumber("x"), y: try a.requireNumber("y"), normalized: a.bool("normalized"), o))
  case "tap_text":
    return content(try await c.tapText(try a.require("text"), index: a.int("index"), o))
  case "long_press":
    return content(try await c.longPress(x: try a.requireNumber("x"), y: try a.requireNumber("y"), ms: a.int("ms") ?? 800,
                                         normalized: a.bool("normalized"), o))
  case "swipe":
    return content(try await c.swipe(from: try a.pt("from"), to: try a.pt("to"), ms: a.int("ms") ?? 300,
                                     normalized: a.bool("normalized"), o))
  case "scroll":
    guard let dir = Direction(rawValue: try a.require("direction")) else {
      throw MirrorError.badArgument("direction must be up, down, left or right")
    }
    return content(try await c.scroll(dir, amount: a.double("amount"), o))
  case "type_text":
    guard let m = TypeMethod(rawValue: a.string("method") ?? "auto") else {
      throw MirrorError.badArgument("method must be auto, keys, unicode or paste")
    }
    return content(try await c.typeText(try a.require("text"), method: m, o))
  case "press_key":
    return content(try await c.pressKey(try a.require("key"), o))
  case "home":
    return content(try await c.menu(.home, o))
  case "app_switcher":
    return content(try await c.menu(.appSwitcher, o))
  case "spotlight":
    return content(try await c.menu(.spotlight, o))
  case "open_app":
    return content(try await c.openApp(try a.require("name")))
  case "wait_for_text":
    return [text(try await c.waitForText(try a.require("text"), timeoutMs: a.int("timeout_ms") ?? 5000))]
  default:
    throw MirrorError.badArgument("unknown tool \(name)")
  }
}

func runMCP(controller: Controller, version: String) async throws {
  let server = Server(
    name: "iphone-mirror",
    version: version,
    instructions: serverInstructions,
    capabilities: .init(tools: .init(listChanged: false))
  )
  await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
  await server.withMethodHandler(CallTool.self) { params in
    let start = Date()
    defer { Log.info("tool \(params.name) \(Int(Date().timeIntervalSince(start) * 1000)) ms") }
    do {
      return .init(content: try await call(controller, params.name, Args(raw: params.arguments ?? [:])), isError: false)
    } catch {
      Log.info("tool \(params.name) error: \(error)")
      return .init(content: [text("error: \(error)")], isError: true)
    }
  }
  try await server.start(transport: StdioTransport())
  Log.info("mcp server started (v\(version))")
  await server.waitUntilCompleted()
}
