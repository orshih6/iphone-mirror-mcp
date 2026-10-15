import Foundation

/// Optional user configuration, read from `~/.config/iphone-mirror-mcp/config.json`
/// (or the path in `IPHONE_MIRROR_CONFIG`). Every key is optional.
public struct Config: Sendable, Equatable {
  public var bundleID = "com.apple.ScreenContinuity"
  /// Default screenshot width in pixels (clamped to 240...600).
  public var defaultWidth = 320
  /// JPEG quality 1...100.
  public var jpegQuality = 50
  /// App names `open_app` and `tap_text` refuse to touch (case-insensitive).
  public var blockedApps: [String] = []
  /// Extra trim, in window points, applied after the automatic crop of the window frame.
  public var cropInsets = Insets()
  /// Vision languages. Fast OCR is Latin-only; Cyrillic needs `accurate: true` and e.g. "ru-RU".
  public var ocrLanguages = ["en-US"]
  /// Titles of the iPhone Mirroring menu items; used before falling back to ⌘1/⌘2/⌘3.
  public var menuHome = "Home Screen"
  public var menuAppSwitcher = "App Switcher"
  public var menuSpotlight = "Spotlight"
  public var stableIntervalMs = 150
  public var stableTimeoutMs = 2000
  public var restoreMouse = true
  /// Let the user keep working on the Mac: menu actions and captures never take focus;
  /// taps, swipes and typing borrow it for a moment, then hand it back to the user's app.
  public var background = true
  /// Background mode waits until the user has not touched the mouse or keyboard for this long.
  public var idleMs = 700

  public struct Insets: Sendable, Equatable, Decodable {
    public var top = 0.0, left = 0.0, bottom = 0.0, right = 0.0
    public init() {}
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      top = try c.decodeIfPresent(Double.self, forKey: .top) ?? 0
      left = try c.decodeIfPresent(Double.self, forKey: .left) ?? 0
      bottom = try c.decodeIfPresent(Double.self, forKey: .bottom) ?? 0
      right = try c.decodeIfPresent(Double.self, forKey: .right) ?? 0
    }
    enum CodingKeys: String, CodingKey { case top, left, bottom, right }
  }

  public init() {}

  public static var defaultPath: String {
    if let p = ProcessInfo.processInfo.environment["IPHONE_MIRROR_CONFIG"], !p.isEmpty { return p }
    return NSHomeDirectory() + "/.config/iphone-mirror-mcp/config.json"
  }

  /// Missing file → defaults. Unreadable or invalid file → error, because it may hold `blocked_apps`.
  public static func load(path: String = defaultPath) throws -> Config {
    guard FileManager.default.fileExists(atPath: path) else { return Config() }
    do {
      return try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
      throw MirrorError.badConfig("\(path): \(error)")
    }
  }
}

extension Config: Decodable {
  enum CodingKeys: String, CodingKey {
    case bundleID = "bundle_id", defaultWidth = "default_width", jpegQuality = "jpeg_quality"
    case blockedApps = "blocked_apps", cropInsets = "crop_insets", ocrLanguages = "ocr_languages"
    case menuHome = "menu_home", menuAppSwitcher = "menu_app_switcher", menuSpotlight = "menu_spotlight"
    case stableIntervalMs = "stable_interval_ms", stableTimeoutMs = "stable_timeout_ms"
    case restoreMouse = "restore_mouse", background, idleMs = "idle_ms"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Config()
    bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? d.bundleID
    defaultWidth = try c.decodeIfPresent(Int.self, forKey: .defaultWidth) ?? d.defaultWidth
    jpegQuality = try c.decodeIfPresent(Int.self, forKey: .jpegQuality) ?? d.jpegQuality
    blockedApps = try c.decodeIfPresent([String].self, forKey: .blockedApps) ?? d.blockedApps
    cropInsets = try c.decodeIfPresent(Insets.self, forKey: .cropInsets) ?? d.cropInsets
    ocrLanguages = try c.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? d.ocrLanguages
    menuHome = try c.decodeIfPresent(String.self, forKey: .menuHome) ?? d.menuHome
    menuAppSwitcher = try c.decodeIfPresent(String.self, forKey: .menuAppSwitcher) ?? d.menuAppSwitcher
    menuSpotlight = try c.decodeIfPresent(String.self, forKey: .menuSpotlight) ?? d.menuSpotlight
    stableIntervalMs = try c.decodeIfPresent(Int.self, forKey: .stableIntervalMs) ?? d.stableIntervalMs
    stableTimeoutMs = try c.decodeIfPresent(Int.self, forKey: .stableTimeoutMs) ?? d.stableTimeoutMs
    restoreMouse = try c.decodeIfPresent(Bool.self, forKey: .restoreMouse) ?? d.restoreMouse
    background = try c.decodeIfPresent(Bool.self, forKey: .background) ?? d.background
    idleMs = try c.decodeIfPresent(Int.self, forKey: .idleMs) ?? d.idleMs
  }
}
