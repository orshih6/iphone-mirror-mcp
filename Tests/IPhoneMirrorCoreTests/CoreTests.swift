import CoreGraphics
import Foundation
import Testing
@testable import IPhoneMirrorCore

// iPhone-ish content: 330×716 pt at (500, 100) on screen.
let content = Rect(x: 500, y: 100, w: 330, h: 716)
let contentSize = CGSize(width: 330, height: 716)

@Suite struct CoordinateTests {
  @Test func defaultViewKeepsAspect() {
    let v = ViewMapping.make(contentSize: contentSize, region: .unit, width: 320)
    #expect(v.width == 320)
    #expect(v.height == 694)  // 320 * 716 / 330 = 694.3
  }

  @Test func corners() throws {
    let v = ViewMapping.make(contentSize: contentSize, region: .unit, width: 320)
    let origin = try #require(v.screenPoint(x: 0, y: 0, content: content))
    #expect(origin == CGPoint(x: 500, y: 100))
    let mid = try #require(v.screenPoint(x: 160, y: Double(v.height) / 2, content: content))
    #expect(abs(mid.x - 665) < 0.001)
    #expect(abs(mid.y - 458) < 0.001)
  }

  @Test func rejectsOutside() {
    let v = ViewMapping.make(contentSize: contentSize, region: .unit, width: 320)
    #expect(v.screenPoint(x: -1, y: 10, content: content) == nil)
    #expect(v.screenPoint(x: 10, y: -0.5, content: content) == nil)
    #expect(v.screenPoint(x: 320, y: 10, content: content) == nil)
    #expect(v.screenPoint(x: 10, y: Double(v.height), content: content) == nil)
    #expect(v.screenPoint(x: 5000, y: 5000, content: content) == nil)
  }

  @Test func regionZoomMapsBackToTheSameScreenPoint() throws {
    let full = ViewMapping.make(contentSize: contentSize, region: .unit, width: 320)
    // Zoom into the bottom-right quarter of the full image at 400 px wide.
    let region = full.subRegion(Rect(x: 160, y: 347, w: 160, h: 347))
    #expect(abs(region.x - 0.5) < 0.001)
    #expect(abs(region.y - 0.5) < 0.001)
    let zoom = ViewMapping.make(contentSize: contentSize, region: region, width: 400)
    // The top-left of the zoomed image is the center of the full image.
    let a = try #require(zoom.screenPoint(x: 0, y: 0, content: content))
    let b = try #require(full.screenPoint(x: 160, y: 347, content: content))
    #expect(abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01)
  }

  @Test func nestedRegion() {
    let half = ViewMapping.make(contentSize: contentSize, region: Rect(x: 0.5, y: 0, w: 0.5, h: 0.5), width: 300)
    let inner = half.subRegion(Rect(x: 0, y: 0, w: 150, h: Double(half.height)))
    #expect(abs(inner.x - 0.5) < 1e-9 && abs(inner.w - 0.25) < 1e-9 && abs(inner.h - 0.5) < 1e-9)
  }

  @Test func subRegionClips() {
    let v = ViewMapping.make(contentSize: contentSize, region: .unit, width: 320)
    let r = v.subRegion(Rect(x: -100, y: -100, w: 1000, h: 10_000))
    #expect(r == .unit)
    let empty = v.subRegion(Rect(x: 400, y: 0, w: 50, h: 50))
    #expect(empty.w == 0)
  }

  @Test func pointsPerPixel() {
    let v = ViewMapping.make(contentSize: contentSize, region: .unit, width: 320)
    #expect(abs(v.pointsPerPixel(content: content) - 716.0 / Double(v.height)) < 1e-9)
  }

  @Test func phoneShape() {
    #expect(looksLikePhone(CGSize(width: 330, height: 716)))
    #expect(looksLikePhone(CGSize(width: 716, height: 330)))
    #expect(!looksLikePhone(CGSize(width: 640, height: 662)))  // "iPhone in Use" pane
    #expect(!looksLikePhone(.zero))
  }
}

@Suite struct CropTests {
  @Test func alphaBoundsFindsOpaqueArea() throws {
    let w = 20, h = 30, bpr = w * 4
    var px = [UInt8](repeating: 0, count: bpr * h)
    for y in 5..<25 { for x in 3..<17 { px[y * bpr + x * 4 + 3] = 255 } }
    px[0 * bpr + 0 * 4 + 3] = 40  // faint anti-aliased pixel: ignored
    let b = try #require(alphaBounds(px, width: w, height: h, bytesPerRow: bpr))
    #expect(b.x == 3 && b.y == 5 && b.w == 14 && b.h == 20)
  }

  @Test func alphaBoundsEmpty() {
    let px = [UInt8](repeating: 0, count: 4 * 4 * 4)
    #expect(alphaBounds(px, width: 4, height: 4, bytesPerRow: 16) == nil)
  }
}

@Suite struct HashTests {
  let base = Thumb(cells: [UInt8](repeating: 200, count: Thumb.cols * Thumb.rows))

  @Test func identicalIsSame() {
    #expect(base.same(base))
    #expect(base.differingCells(base) == 0)
  }

  @Test func smallNoiseIsSame() {
    var c = base.cells
    for i in stride(from: 0, to: c.count, by: 7) { c[i] = 205 }
    #expect(base.same(Thumb(cells: c)))
  }

  @Test func oneChangedCellIsNotSameButSettled() {
    var c = base.cells
    c[100] = 120
    let t = Thumb(cells: c)
    #expect(!base.same(t))
    #expect(base.settled(t))
  }

  @Test func bigChangeIsNotSettled() {
    var c = base.cells
    for i in 0..<50 { c[i] = 30 }
    #expect(!base.settled(Thumb(cells: c)))
  }

  @Test func sizeMismatch() {
    #expect(base.differingCells(Thumb(cells: [1, 2, 3])) == Int.max)
  }
}

@Suite struct KeyTests {
  @Test func asciiMap() {
    #expect(Keys.ascii["a"]! == (0, false))
    #expect(Keys.ascii["A"]! == (0, true))
    #expect(Keys.ascii["?"]! == (44, true))
    #expect(Keys.ascii[" "]! == (49, false))
  }

  @Test func typable() {
    #expect(Keys.typable("Hello, world! 123"))
    #expect(!Keys.typable("Сайн байна уу"))
    #expect(!Keys.typable("café"))
  }

  @Test func parse() {
    #expect(Keys.parse("return")! == (36, []))
    #expect(Keys.parse("Escape")! == (53, []))
    #expect(Keys.parse("cmd+a")! == (0, .maskCommand))
    #expect(Keys.parse("shift+tab")! == (48, .maskShift))
    #expect(Keys.parse("hyper+a") == nil)
    #expect(Keys.parse("nope") == nil)
  }
}

@Suite struct TextMatchTests {
  let boxes = [
    TextBox(text: "Settings", rect: Rect(x: 40, y: 300, w: 50, h: 12), confidence: 1),
    TextBox(text: "General Settings", rect: Rect(x: 0, y: 100, w: 160, h: 12), confidence: 1),
    TextBox(text: "Notes", rect: Rect(x: 120, y: 300, w: 40, h: 12), confidence: 1),
  ]

  @Test func substringNarrowsToWord() throws {
    let found = TextMatch.find("settings", in: boxes, exact: false)
    #expect(found.count == 2)
    let general = try #require(found.first { $0.text == "General Settings" })
    // "Settings" starts at char 8 of 16 → right half of the box.
    #expect(general.rect.x == 80 && general.rect.w == 80)
  }

  @Test func exactWinsAmbiguity() throws {
    let found = TextMatch.find("Settings", in: boxes, exact: false)
    let hit = try #require(TextMatch.pick("Settings", from: found, boxes: boxes, index: nil))
    #expect(hit.rect.y == 300)
  }

  @Test func ambiguousWithoutExact() {
    let b = [boxes[1], TextBox(text: "Reset Settings", rect: Rect(x: 0, y: 200, w: 140, h: 12), confidence: 1)]
    let found = TextMatch.find("settings", in: b, exact: false)
    #expect(TextMatch.pick("settings", from: found, boxes: b, index: nil) == nil)
    #expect(TextMatch.pick("settings", from: found, boxes: b, index: 1)?.text == "Reset Settings")
    #expect(TextMatch.pick("settings", from: found, boxes: b, index: 5) == nil)
  }

  @Test func caseAndDiacritics() {
    #expect(TextMatch.find("CAFE", in: [TextBox(text: "Café", rect: .unit, confidence: 1)], exact: true).count == 1)
    #expect(TextMatch.find("сайн", in: [TextBox(text: "Сайн байна уу", rect: .unit, confidence: 1)], exact: false).count == 1)
  }
}

@Suite struct SafetyTests {
  @Test func blocked() {
    let list = ["Example Bank", "PayPal"]
    #expect(Safety.isBlocked("example bank", blocked: list))
    #expect(Safety.isBlocked("Example Bank app", blocked: list))
    #expect(Safety.isBlocked("paypal", blocked: list))
    #expect(Safety.isBlocked("Example", blocked: list))  // partial name of a blocked app
    #expect(!Safety.isBlocked("Notes", blocked: list))
    #expect(!Safety.isBlocked("Pa", blocked: list))
    #expect(!Safety.isBlocked("anything", blocked: []))
  }
}

@Suite struct ConfigTests {
  @Test func partialConfigKeepsDefaults() throws {
    let json = #"{"blocked_apps":["Example Bank"],"default_width":400,"crop_insets":{"top":28}}"#
    let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    #expect(c.blockedApps == ["Example Bank"])
    #expect(c.defaultWidth == 400)
    #expect(c.cropInsets.top == 28 && c.cropInsets.left == 0)
    #expect(c.bundleID == "com.apple.ScreenContinuity")
    #expect(c.jpegQuality == 50)
  }

  @Test func missingFileIsDefault() throws {
    #expect(try Config.load(path: "/nonexistent/config.json") == Config())
  }

  @Test func invalidFileThrows() throws {
    let path = NSTemporaryDirectory() + "iphone-mirror-bad-config.json"
    try Data("{not json".utf8).write(to: URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(throws: MirrorError.self) { try Config.load(path: path) }
  }
}

@Suite struct OCRMergeTests {
  @Test func splitsScripts() {
    let (cjk, cyr, rest) = OCR.split(["en-US", "zh-Hans", "ru-RU"])
    #expect(cjk == ["zh-Hans"] && cyr == ["ru-RU"] && rest == ["en-US"])
  }

  @Test func cyrillicReplacesGarbleButNotChinese() {
    let garbled = TextBox(text: "Xyhnn 3pyyn", rect: Rect(x: 0.1, y: 0.1, w: 0.3, h: 0.05), confidence: 0.3)
    let chinese = TextBox(text: "红蜻蜓延隆专卖店", rect: Rect(x: 0.1, y: 0.3, w: 0.5, h: 0.05), confidence: 1)
    let cyr = TextBox(text: "Хүний эрүүл", rect: Rect(x: 0.1, y: 0.1, w: 0.3, h: 0.05), confidence: 0.9)
    let cyrOverChinese = TextBox(text: "Ьа", rect: Rect(x: 0.1, y: 0.3, w: 0.2, h: 0.05), confidence: 0.5)
    let out = OCR.merge([garbled, chinese], [cyr, cyrOverChinese])
    #expect(out.map(\.text) == ["Хүний эрүүл", "红蜻蜓延隆专卖店"])
  }
}
