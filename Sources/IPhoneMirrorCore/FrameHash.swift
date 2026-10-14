/// A tiny grayscale thumbnail used as a perceptual hash. An 8×8 dHash is too coarse
/// for a phone screen (a toggle flip or one typed letter would not register), so
/// this keeps 24×48 cells and compares them with a per-cell tolerance.
public struct Thumb: Equatable, Sendable {
  public static let cols = 24, rows = 48
  public let cells: [UInt8]

  public init(cells: [UInt8]) { self.cells = cells }

  /// Number of cells whose brightness differs by more than `threshold` (0...255).
  public func differingCells(_ other: Thumb, threshold: Int = 12) -> Int {
    guard cells.count == other.cells.count else { return Int.max }
    var n = 0
    for i in cells.indices where abs(Int(cells[i]) - Int(other.cells[i])) > threshold { n += 1 }
    return n
  }

  /// Same screen for "unchanged": no cell moved.
  public func same(_ other: Thumb) -> Bool { differingCells(other) == 0 }

  /// Settled for "wait for stable": tolerates a blinking cursor or a spinner tick.
  public func settled(_ other: Thumb) -> Bool { differingCells(other) <= 2 }
}
