import Foundation

/// Logs to stderr (never stdout — that is the MCP channel) and to
/// ~/Library/Logs/iphone-mirror-mcp/iphone-mirror.log.
public enum Log {
  private final class Sink: @unchecked Sendable {
    let lock = NSLock()
    var file: FileHandle?

    init() {
      let dir = NSHomeDirectory() + "/Library/Logs/iphone-mirror-mcp"
      let path = dir + "/iphone-mirror.log"
      let fm = FileManager.default
      try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
      if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 5_000_000 {
        try? fm.removeItem(atPath: path)
      }
      if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
      file = FileHandle(forWritingAtPath: path)
      _ = try? file?.seekToEnd()
    }
  }

  private static let sink = Sink()
  nonisolated(unsafe) public static var quiet = false

  public static func info(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let data = Data(line.utf8)
    sink.lock.lock()
    defer { sink.lock.unlock() }
    if !quiet { FileHandle.standardError.write(data) }
    sink.file?.write(data)
  }
}
