import Foundation

public enum MirrorError: Error, CustomStringConvertible, Sendable {
  case permission(name: String, host: String)
  case appNotInstalled(String)
  case appNotRunning
  case windowNotFound
  case windowMinimized
  case notMirroring(String)
  case notFrontmost
  case macLocked
  case outsidePhone(x: Double, y: Double, width: Int, height: Int)
  case aborted(String)
  case noMatch(String, seen: [String])
  case ambiguous(String, matches: [String])
  case blocked(String)
  case badArgument(String)
  case badConfig(String)
  case captureFailed(String)
  case timeout(String)

  public var description: String {
    switch self {
    case let .permission(name, host):
      return "\(name) permission missing. Grant it to \"\(host)\" in System Settings › Privacy & Security › \(name), then restart \(host)."
    case let .appNotInstalled(id):
      return "iPhone Mirroring (\(id)) is not installed. It needs macOS 15+ and a supported iPhone."
    case .appNotRunning:
      return "iPhone Mirroring is not running. Call launch first."
    case .windowNotFound:
      return "iPhone Mirroring window not found."
    case .windowMinimized:
      return "iPhone Mirroring window is minimized or on another Space."
    case let .notMirroring(detail):
      return "iPhone is not being mirrored (locked, in use, not nearby, or connecting)." + (detail.isEmpty ? "" : " Window says: \"\(detail)\"")
    case .macLocked:
      return "The Mac's screen is locked; macOS allows no capture or input until it is unlocked. Nothing was sent."
    case .notFrontmost:
      return "Could not bring iPhone Mirroring to the front; no input was sent."
    case let .outsidePhone(x, y, w, h):
      return "Point (\(fmt(x)),\(fmt(y))) is outside the phone image (\(w)x\(h)); nothing was clicked."
    case let .aborted(why):
      return "aborted by user (\(why))"
    case let .noMatch(text, seen):
      return "No text matching \"\(text)\"." + (seen.isEmpty ? "" : " Visible: " + seen.prefix(20).joined(separator: " | "))
    case let .ambiguous(text, matches):
      return "\(matches.count) matches for \"\(text)\"; pass index (0-based): " + matches.enumerated().map { "\($0.offset)=\($0.element)" }.joined(separator: " ")
    case let .blocked(name):
      return "\"\(name)\" is in blocked_apps; refusing."
    case let .badArgument(msg), let .badConfig(msg), let .captureFailed(msg), let .timeout(msg):
      return msg
    }
  }
}

func fmt(_ v: Double) -> String {
  v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
}
