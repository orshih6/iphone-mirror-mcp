import CoreGraphics
import Foundation
import Vision

public struct TextBox: Sendable, Equatable {
  public var text: String
  /// Image pixels of the current view.
  public var rect: Rect
  public var confidence: Double

  public init(text: String, rect: Rect, confidence: Double) {
    self.text = text; self.rect = rect; self.confidence = confidence
  }

  public var center: (x: Int, y: Int) { (Int((rect.x + rect.w / 2).rounded()), Int((rect.y + rect.h / 2).rounded())) }
}

enum OCR {
  /// Boxes are returned normalized to `image`, top-left origin.
  static func recognize(_ image: CGImage, accurate: Bool, languages: [String]) throws -> [TextBox] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = accurate ? .accurate : .fast
    request.usesLanguageCorrection = accurate
    if let supported = try? request.supportedRecognitionLanguages() {
      let wanted = languages.filter(supported.contains)
      if !wanted.isEmpty { request.recognitionLanguages = wanted }
    }
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { obs in
      guard let top = obs.topCandidates(1).first else { return nil }
      let b = obs.boundingBox
      return TextBox(
        text: top.string,
        rect: Rect(x: b.minX, y: 1 - b.maxY, w: b.width, h: b.height),
        confidence: Double(top.confidence)
      )
    }
  }
}

public enum TextMatch {
  public static func normalize(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Boxes matching `query`, each narrowed to the matched substring (estimated from
  /// character positions) so a word inside a longer line is tapped at the word.
  public static func find(_ query: String, in boxes: [TextBox], exact: Bool) -> [TextBox] {
    let q = normalize(query)
    guard !q.isEmpty else { return [] }
    return boxes.compactMap { box in
      let t = normalize(box.text)
      if exact { return t == q ? box : nil }
      guard let range = t.range(of: q) else { return nil }
      let n = Double(t.count)
      let start = Double(t.distance(from: t.startIndex, to: range.lowerBound))
      var narrowed = box
      narrowed.rect.x = box.rect.x + box.rect.w * start / n
      narrowed.rect.w = box.rect.w * Double(q.count) / n
      return narrowed
    }
  }

  /// When several boxes contain the query but exactly one equals it, that one is meant.
  public static func pick(_ query: String, from matches: [TextBox], boxes: [TextBox], index: Int?) -> TextBox? {
    if let index { return matches.indices.contains(index) ? matches[index] : nil }
    if matches.count == 1 { return matches[0] }
    let exact = find(query, in: boxes, exact: true)
    return exact.count == 1 ? exact[0] : nil
  }
}
