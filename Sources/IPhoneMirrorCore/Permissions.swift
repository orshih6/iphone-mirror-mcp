import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

public enum Permissions {
  public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
  public static var accessibility: Bool { AXIsProcessTrusted() }

  /// Shows the system prompts (and adds the host app to both lists in System Settings).
  public static func request() {
    if !screenRecording { _ = CGRequestScreenCaptureAccess() }
    if !accessibility {
      _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
  }

  static func requireScreen() throws {
    if !screenRecording { throw MirrorError.permission(name: "Screen Recording", host: hostApp()) }
  }

  static func requireAccessibility() throws {
    if !accessibility { throw MirrorError.permission(name: "Accessibility", host: hostApp()) }
  }

  /// macOS grants these permissions to the app that launched us (Terminal, iTerm,
  /// Ghostty, VS Code, Claude…), not to this binary. Walk up the process tree to name it.
  public static func hostApp() -> String {
    var pid = getpid()
    for _ in 0..<16 {
      if let path = processPath(pid), let r = path.range(of: ".app/") {
        let app = path[..<r.lowerBound]
        return String(app.split(separator: "/").last ?? Substring(app))
      }
      guard let parent = parentPID(pid), parent > 1, parent != pid else { break }
      pid = parent
    }
    return "the terminal app running Claude Code"
  }

  private static func processPath(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(cString: buf)
  }

  /// sysctl rather than proc_pidinfo: it also works across root-owned hops like `login`.
  private static func parentPID(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
  }
}
