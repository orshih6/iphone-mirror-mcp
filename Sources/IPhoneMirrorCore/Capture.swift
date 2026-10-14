import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

enum Capture {
  /// Captures only the iPhone Mirroring window (never the display), at `scale`
  /// pixels per point. `scale: nil` uses the display's native scale.
  static func window(_ w: LocatedWindow, scale: Double? = nil) async throws -> CGImage {
    let filter = SCContentFilter(desktopIndependentWindow: w.window)
    let s = scale ?? Double(filter.pointPixelScale)
    let cfg = SCStreamConfiguration()
    cfg.width = max(1, Int((w.frame.width * s).rounded()))
    cfg.height = max(1, Int((w.frame.height * s).rounded()))
    cfg.showsCursor = false
    cfg.ignoreShadowsSingleWindow = true
    cfg.shouldBeOpaque = false
    do {
      return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    } catch {
      throw MirrorError.captureFailed("window capture failed: \(error.localizedDescription)")
    }
  }

  /// Phone content rect in image pixels: transparent window frame trimmed off.
  static func contentBounds(_ image: CGImage) -> CGRect {
    let w = image.width, h = image.height, bpr = w * 4
    var bytes = [UInt8](repeating: 0, count: bpr * h)
    let drawn = bytes.withUnsafeMutableBytes { buf -> Bool in
      guard let ctx = CGContext(
        data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return false }
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    let full = CGRect(x: 0, y: 0, width: w, height: h)
    guard drawn, let b = alphaBounds(bytes, width: w, height: h, bytesPerRow: bpr) else { return full }
    return CGRect(x: b.x, y: b.y, width: b.w, height: b.h)
  }

  /// Crops `region` (normalized within `content`, image pixels) out of `image`.
  static func crop(_ image: CGImage, content: CGRect, region: Rect) -> CGImage? {
    let r = CGRect(
      x: content.minX + region.x * content.width,
      y: content.minY + region.y * content.height,
      width: region.w * content.width,
      height: region.h * content.height
    ).integral
    return image.cropping(to: r)
  }

  static func scaled(_ image: CGImage, width: Int, height: Int, gray: Bool) -> CGImage? {
    let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
    let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    guard let ctx = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: info
    ) else { return nil }
    ctx.interpolationQuality = .high
    ctx.setFillColor(gray ? CGColor(gray: 0, alpha: 1) : CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
  }

  static func encode(_ image: CGImage, png: Bool, quality: Int) -> Data? {
    let data = NSMutableData()
    let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
    guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
    let q = Double(min(max(quality, 1), 100)) / 100
    let props = png ? nil : [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary
    CGImageDestinationAddImage(dest, image, props)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
  }

  static func thumb(_ image: CGImage) -> Thumb {
    let cols = Thumb.cols, rows = Thumb.rows
    var cells = [UInt8](repeating: 0, count: cols * rows)
    cells.withUnsafeMutableBytes { buf in
      guard let ctx = CGContext(
        data: buf.baseAddress, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
      ) else { return }
      ctx.interpolationQuality = .medium
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: rows))
    }
    return Thumb(cells: cells)
  }
}
