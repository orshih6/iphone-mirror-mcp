import AppKit
import Foundation
import IPhoneMirrorCore

let version = "0.1.0"

// A window-server connection for ScreenCaptureKit; never shows a Dock icon.
NSApplication.shared.setActivationPolicy(.prohibited)

var argv = Array(CommandLine.arguments.dropFirst())
// Installed as `iphone-mirror-mcp` with no arguments → act as the MCP server.
if argv.isEmpty, URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "iphone-mirror-mcp" {
  argv = ["mcp"]
}
if argv.first == "--version" {
  print(version)
  exit(0)
}

let config: Config
do {
  config = try Config.load()
} catch {
  FileHandle.standardError.write(Data("error: \(error)\n".utf8))
  exit(1)
}
let controller = Controller(config: config)

if argv.first == "mcp" {
  do {
    try await runMCP(controller: controller, version: version)
  } catch {
    Log.info("mcp server stopped: \(error)")
    exit(1)
  }
} else {
  Log.quiet = true  // the CLI prints its own results and errors
  exit(await runCLI(argv, controller: controller))
}
