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
  ///
  /// Vision picks its script model from the FIRST language: with "en-US" first,
  /// Chinese comes out as Latin garbage; with "zh-Hans" first, Cyrillic suffers.
  /// So CJK languages go first, and if Cyrillic is configured too, a second pass
  /// reads it and replaces overlapping boxes where it found Cyrillic letters.
  static func recognize(_ image: CGImage, accurate: Bool, languages: [String]) throws -> [TextBox] {
    let (cjk, cyrillic, rest) = split(languages)
    if !accurate || cjk.isEmpty { return try pass(image, accurate: accurate, languages: cyrillic + rest + cjk) }
    let primary = try pass(image, accurate: true, languages: cjk + rest)
    guard !cyrillic.isEmpty else { return primary }
    let second = try pass(image, accurate: true, languages: cyrillic + rest)
    return merge(primary, second)
  }

  static func split(_ languages: [String]) -> (cjk: [String], cyrillic: [String], rest: [String]) {
    let isCJK = { (l: String) in ["zh", "ja", "ko", "yue"].contains { l.hasPrefix($0) } }
    let isCyr = { (l: String) in ["ru", "uk"].contains { l.hasPrefix($0) } }
    return (languages.filter(isCJK), languages.filter(isCyr), languages.filter { !isCJK($0) && !isCyr($0) })
  }

  /// Keeps `primary`, except where `second` read Cyrillic over a box without CJK.
  static func merge(_ primary: [TextBox], _ second: [TextBox]) -> [TextBox] {
    var out = primary
    for b in second where b.text.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) {
      let hits = out.indices.filter { overlap(out[$0].rect, b.rect) > 0.3 }
      if hits.contains(where: { hasCJK(out[$0].text) }) { continue }
      let drop = Set(hits)
      out = out.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
      out.append(b)
    }
    return out.sorted { ($0.rect.y, $0.rect.x) < ($1.rect.y, $1.rect.x) }
  }

  static func hasCJK(_ s: String) -> Bool {
    s.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0x3040...0x30FF).contains($0.value) }
  }

  /// Intersection over the smaller box.
  static func overlap(_ a: Rect, _ b: Rect) -> Double {
    let w = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
    let h = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
    guard w > 0, h > 0 else { return 0 }
    return (w * h) / max(1e-9, min(a.w * a.h, b.w * b.h))
  }

  private static func pass(_ image: CGImage, accurate: Bool, languages: [String]) throws -> [TextBox] {
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
