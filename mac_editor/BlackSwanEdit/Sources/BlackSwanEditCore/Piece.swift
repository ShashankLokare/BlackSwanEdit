// Sources/BlackSwanEditCore/Piece.swift
//
// The atomic unit of the piece-chain document model.

import Foundation

/// Points into either the read-only orignal buffer or the append-only add-buffer.
public struct Piece: Equatable, Sendable {
    public enum Source: UInt8, Sendable { case original, add }

    public var source: Source
    /// Byte offset within the source buffer.
    public var start: UInt64
    /// Number of bytes in this piece.
    public var length: UInt64

    // ---- Cache fields (recomputed lazily) ----
    /// -1 = dirty/unknown; ≥ 0 = valid cached value
    public var cachedNewlineCount: Int = -1

    public init(source: Source, start: UInt64, length: UInt64) {
        self.source = source
        self.start = start
        self.length = length
    }
}

extension Piece: CustomStringConvertible {
    public var description: String {
        "\(source)[\(start)..<\(start + length)]"
    }
}
