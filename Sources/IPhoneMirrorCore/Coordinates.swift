import CoreGraphics

public struct Rect: Equatable, Hashable, Sendable, CustomStringConvertible {
  public var x, y, w, h: Double
  public init(x: Double, y: Double, w: Double, h: Double) {
    self.x = x; self.y = y; self.w = w; self.h = h
  }
  public static let unit = Rect(x: 0, y: 0, w: 1, h: 1)
  public var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
  public var description: String { "\(fmt(x)),\(fmt(y)),\(fmt(w)),\(fmt(h))" }
}

/// What the last image showed: a `region` of the phone content (normalized 0...1,
/// top-left origin) drawn at `width`×`height` pixels. Every tool's x/y is a pixel
/// in that image. Content position on screen is looked up fresh for each action,
/// so moving the window between a screenshot and a tap is harmless.
public struct ViewMapping: Equatable, Sendable {
  public var region: Rect
  public var width: Int
  public var height: Int

  public init(region: Rect, width: Int, height: Int) {
    self.region = region; self.width = width; self.height = height
  }

  /// Height follows the aspect of the region in screen points.
  public static func make(contentSize: CGSize, region: Rect, width: Int) -> ViewMapping {
    let ptsW = region.w * contentSize.width
    let ptsH = region.h * contentSize.height
    let height = ptsW > 0 ? max(1, Int((Double(width) * ptsH / ptsW).rounded())) : width
    return ViewMapping(region: region, width: width, height: height)
  }

  public func contains(x: Double, y: Double) -> Bool {
    x >= 0 && y >= 0 && x < Double(width) && y < Double(height)
  }

  /// Image pixel → normalized phone-content point. nil outside the image.
  public func normalized(x: Double, y: Double) -> (x: Double, y: Double)? {
    guard contains(x: x, y: y) else { return nil }
    return (region.x + x / Double(width) * region.w, region.y + y / Double(height) * region.h)
  }

  /// Image pixel → global screen point (top-left origin, the space CGEvent uses).
  /// nil when the point is not on the phone content.
  public func screenPoint(x: Double, y: Double, content: Rect) -> CGPoint? {
    guard let n = normalized(x: x, y: y), (0..<1).contains(n.x), (0..<1).contains(n.y) else { return nil }
    return CGPoint(x: content.x + n.x * content.w, y: content.y + n.y * content.h)
  }

  /// A rectangle in this image's pixels → the normalized content rect it covers, clipped to the image.
  public func subRegion(_ r: Rect) -> Rect {
    let x0 = min(max(r.x, 0), Double(width)), y0 = min(max(r.y, 0), Double(height))
    let x1 = min(max(r.x + r.w, 0), Double(width)), y1 = min(max(r.y + r.h, 0), Double(height))
    return Rect(
      x: region.x + x0 / Double(width) * region.w,
      y: region.y + y0 / Double(height) * region.h,
      w: (x1 - x0) / Double(width) * region.w,
      h: (y1 - y0) / Double(height) * region.h
    )
  }

  /// Screen points per image pixel, vertically (used to size scroll distances).
  public func pointsPerPixel(content: Rect) -> Double {
    content.h * region.h / Double(height)
  }
}

/// Bounding box of pixels with alpha above `threshold` in an 8-bit RGBA/BGRA buffer
/// (alpha at byte `alphaOffset` of each pixel). The iPhone Mirroring window is a
/// rounded phone shape on a transparent background, so this trims the window frame.
public func alphaBounds(
  _ bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int,
  alphaOffset: Int = 3, threshold: UInt8 = 128
) -> (x: Int, y: Int, w: Int, h: Int)? {
  var minX = width, minY = height, maxX = -1, maxY = -1
  for y in 0..<height {
    let row = y * bytesPerRow
    for x in 0..<width where bytes[row + x * 4 + alphaOffset] > threshold {
      if x < minX { minX = x }
      if x > maxX { maxX = x }
      if y < minY { minY = y }
      if y > maxY { maxY = y }
    }
  }
  guard maxX >= minX, maxY >= minY else { return nil }
  return (minX, minY, maxX - minX + 1, maxY - minY + 1)
}

/// The mirrored phone is portrait or landscape iPhone-shaped; anything else
/// (the square "iPhone in Use" / connect panes) means mirroring is not live.
public func looksLikePhone(_ size: CGSize) -> Bool {
  guard size.width > 0, size.height > 0 else { return false }
  let ratio = max(size.width, size.height) / min(size.width, size.height)
  return (1.6...2.6).contains(ratio)
}
