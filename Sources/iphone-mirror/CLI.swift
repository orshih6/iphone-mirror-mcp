import Foundation
import IPhoneMirrorCore

let usage = """
iphone-mirror — see and control an iPhone through the macOS iPhone Mirroring window

USAGE
  iphone-mirror <command> [args] [--flags]

COMMANDS
  status                         permissions, window and mirroring state
  permissions                    show the macOS permission prompts for the host app
  launch                         open/focus iPhone Mirroring, wait for the phone
  screenshot [-o FILE]           save a screenshot   --width N --region x,y,w,h --gray --png
  read [--fast]                  OCR text as JSON [text,cx,cy,w,h,conf]   --region x,y,w,h
  find TEXT [--exact]            find text, print center points
  tap X Y [--normalized]         tap a point
  tap-text TEXT [--index N]      tap on-screen text
  long-press X Y [--ms 800]      press and hold
  swipe X1 Y1 X2 Y2 [--ms 300]   drag between two points
  scroll up|down|left|right      [--amount PIXELS]
  type TEXT [--method M]         M = auto | keys | unicode | paste
  key NAME                       return, delete, escape, tab, space, up, down, left, right, cmd+<key>
  home | app-switcher | spotlight
  open-app NAME                  open an app via Spotlight
  wait-text TEXT [--timeout MS]  wait until text appears ("a|b" waits for either)
  run "STEP" "STEP" ...           run several steps in one process, e.g. run "tap 160 644 --no-wait" "sleep 300" "home"
  sleep MS                       pause (useful inside run)
  mcp                            run the MCP server on stdio

Actions accept --no-wait to skip waiting for the screen to settle (fewer captures).

Coordinates are pixels in a screenshot taken with the same --width (default 320).
Config: \(Config.defaultPath)
"""

struct ParsedArgs {
  var positional: [String] = []
  var flags: [String: String] = [:]

  init(_ argv: [String]) {
    let valueFlags: Set = ["o", "width", "region", "index", "ms", "amount", "method", "timeout"]
    var i = 0
    while i < argv.count {
      let a = argv[i]
      if a.hasPrefix("-"), a.count > 1, Double(a) == nil {
        let name = String(a.drop(while: { $0 == "-" }))
        if valueFlags.contains(name), i + 1 < argv.count {
          flags[name] = argv[i + 1]; i += 2; continue
        }
        flags[name] = "true"
      } else {
        positional.append(a)
      }
      i += 1
    }
  }

  func has(_ k: String) -> Bool { flags[k] != nil }
  func int(_ k: String) -> Int? { flags[k].flatMap(Int.init) }
  func double(_ k: String) -> Double? { flags[k].flatMap(Double.init) }

  func num(_ i: Int) throws -> Double {
    guard i < positional.count, let v = Double(positional[i]) else {
      throw MirrorError.badArgument("expected a number at argument \(i + 1)")
    }
    return v
  }

  func str(_ i: Int, _ what: String) throws -> String {
    guard i < positional.count else { throw MirrorError.badArgument("missing \(what)") }
    return positional[i...].joined(separator: " ")
  }

  func region() throws -> Rect? {
    guard let r = flags["region"] else { return nil }
    let p = r.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard p.count == 4 else { throw MirrorError.badArgument("--region must be x,y,w,h") }
    return Rect(x: p[0], y: p[1], w: p[2], h: p[3])
  }
}

func runCLI(_ argv: [String], controller c: Controller) async -> Int32 {
  guard let cmd = argv.first else { print(usage); return 0 }
  let a = ParsedArgs(Array(argv.dropFirst()))
  let opts = ActOptions(wait: !a.has("no-wait"))
  do {
    switch cmd {
    case "help", "-h", "--help":
      print(usage)
    case "run":
      // Several steps in one process: geometry is cached, so taps need no capture.
      for step in a.positional {
        await c.resetView()  // each step uses the CLI's full-view coordinates, like a separate call
        let code = await runCLI(splitWords(step), controller: c)
        if code != 0 { return code }
      }
    case "sleep":
      try await Task.sleep(for: .milliseconds(Int(try a.num(0))))
    case "status":
      print(await c.status())
    case "permissions":
      Permissions.request()
      print("Requested Screen Recording and Accessibility for \"\(Permissions.hostApp())\". Enable both in System Settings › Privacy & Security, then restart that app.")
    case "launch":
      print(try await c.launch())
    case "screenshot":
      let o = ShotOptions(width: a.int("width"), region: try a.region(), gray: a.has("gray"), png: a.has("png"), force: true)
      guard case let .image(data, _, w, h) = try await c.screenshot(o) else { return 1 }
      let path = a.flags["o"] ?? (a.has("png") ? "iphone.png" : "iphone.jpg")
      try data.write(to: URL(fileURLWithPath: path))
      print("\(path) \(w)x\(h) \(data.count) bytes")
    case "read":
      print(try await c.readScreen(region: try a.region(), accurate: !a.has("fast")))
    case "find":
      print(try await c.findText(try a.str(0, "text"), exact: a.has("exact")))
    case "tap":
      print(try await c.tap(x: try a.num(0), y: try a.num(1), normalized: a.has("normalized"), opts).text)
    case "tap-text":
      print(try await c.tapText(try a.str(0, "text"), index: a.int("index"), opts).text)
    case "long-press":
      print(try await c.longPress(x: try a.num(0), y: try a.num(1), ms: a.int("ms") ?? 800,
                                  normalized: a.has("normalized"), opts).text)
    case "swipe":
      print(try await c.swipe(from: (try a.num(0), try a.num(1)), to: (try a.num(2), try a.num(3)),
                              ms: a.int("ms") ?? 300, normalized: a.has("normalized"), opts).text)
    case "scroll":
      guard let d = Direction(rawValue: try a.str(0, "direction")) else {
        throw MirrorError.badArgument("direction must be up, down, left or right")
      }
      print(try await c.scroll(d, amount: a.double("amount"), opts).text)
    case "type":
      guard let m = TypeMethod(rawValue: a.flags["method"] ?? "auto") else {
        throw MirrorError.badArgument("--method must be auto, keys, unicode or paste")
      }
      print(try await c.typeText(try a.str(0, "text"), method: m, opts).text)
    case "key":
      print(try await c.pressKey(try a.str(0, "key name"), opts).text)
    case "home":
      print(try await c.menu(.home, opts).text)
    case "app-switcher":
      print(try await c.menu(.appSwitcher, opts).text)
    case "spotlight":
      print(try await c.menu(.spotlight, opts).text)
    case "open-app":
      print(try await c.openApp(try a.str(0, "app name")).text)
    case "wait-text":
      print(try await c.waitForText(try a.str(0, "text"), timeoutMs: a.int("timeout") ?? 5000))
    default:
      FileHandle.standardError.write(Data("unknown command \"\(cmd)\"\n\n\(usage)\n".utf8))
      return 2
    }
    return 0
  } catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    return 1
  }
}

/// Splits a step like `tap-text "My orders" --index 1` into words, honoring quotes.
func splitWords(_ s: String) -> [String] {
  var words: [String] = [], cur = "", quote: Character?
  for ch in s {
    if let q = quote {
      if ch == q { quote = nil } else { cur.append(ch) }
    } else if ch == "\"" || ch == "'" {
      quote = ch
    } else if ch == " " {
      if !cur.isEmpty { words.append(cur); cur = "" }
    } else {
      cur.append(ch)
    }
  }
  if !cur.isEmpty { words.append(cur) }
  return words
}
