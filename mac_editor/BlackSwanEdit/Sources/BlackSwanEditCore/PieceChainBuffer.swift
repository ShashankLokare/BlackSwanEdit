// Sources/BlackSwanEditCore/PieceChainBuffer.swift
//
// Core document model: piece-chain backed by either mmap (large files)
// or in-memory Data (small files). All public methods are safe to call
// from any thread; internal mutation must happen on the owner's serial queue.

import Foundation

// MARK: - Snapshot (for Undo/Redo)

public struct PieceChainSnapshot: Sendable {
    fileprivate let pieces: [Piece]
    fileprivate let addBufferLength: UInt64
    public let generation: UInt64
}

// MARK: - PieceChainBuffer

public final class PieceChainBuffer {

    // ---- Backing stores ----
    private var originalSource: BufferSource
    private var addBuffer: Data

    // ---- Piece chain ----
    private var pieces: [Piece]

    // ---- Fenwick trees (1-indexed over pieces) ----
    /// Cumulative byte lengths of pieces.
    private var byteTree: FenwickTree<UInt64>
    /// Cumulative newline counts of pieces.
    private var newlineTree: FenwickTree<Int>

    // ---- Metadata ----
    private var _generation: UInt64 = 0
    public var generation: UInt64 { _generation }

    // ---- Configuration ----
    /// Threshold in bytes above which the buffer was loaded via mmap.
    public let isLargeFileMode: Bool

    // MARK: Init — small file (in-memory)

    public init(data: Data) {
        originalSource = .memory(data)
        addBuffer = Data()
        let initialPiece = Piece(source: .original, start: 0, length: UInt64(data.count))
        pieces = data.isEmpty ? [] : [initialPiece]
        byteTree = FenwickTree(count: max(pieces.count, 1))
        newlineTree = FenwickTree(count: max(pieces.count, 1))
        isLargeFileMode = false
        rebuildTrees()
    }

    // MARK: Init — large file (mmap)

    public init(mappedFile: MappedFile) throws {
        originalSource = .mapped(mappedFile)
        addBuffer = Data()
        let len = mappedFile.length
        let initialPiece = len > 0 ? Piece(source: .original, start: 0, length: len) : nil
        pieces = initialPiece.map { [$0] } ?? []
        byteTree = FenwickTree(count: max(pieces.count, 1))
        newlineTree = FenwickTree(count: max(pieces.count, 1))
        isLargeFileMode = true
        rebuildTrees()
    }

    // MARK: Public Properties

    public var byteLength: UInt64 {
        pieces.isEmpty ? 0 : byteTree.prefixSum(upTo: pieces.count)
    }

    /// Approximate line count (exact after full scan; may be stale during lazy computation).
    public var lineCount: Int {
        let nl = pieces.isEmpty ? 0 : newlineTree.prefixSum(upTo: pieces.count)
        return nl + 1  // number of lines = newlines + 1
    }

    // MARK: Byte Access

    /// Returns a `Data` copy of the given byte range. Expensive for huge ranges.
    public func bytes(in range: Range<UInt64>) -> Data {
        precondition(range.upperBound <= byteLength)
        var result = Data(capacity: Int(range.upperBound - range.lowerBound))
        iteratePieces(overlapping: range) { pieceRange, source in
            source.copy(into: &result, from: pieceRange)
        }
        return result
    }

    /// Full document as Data (ONLY for small files; large files should stream).
    public func allBytes() -> Data {
        return bytes(in: 0..<byteLength)
    }

    // MARK: Line API

    /// O(log n): Returns the absolute byte offset for the beginning of the given logical line.
    private func lineStartOffset(forLine line: Int) -> UInt64? {
        guard line >= 0 && line < lineCount else { return nil }
        if line == 0 {
            return 0
        }
        // Find piece index where the (line-1)-th newline lives
        let pieceIdx = newlineTree.lowerBound(line)  // 1-indexed
        guard pieceIdx <= pieces.count else { return nil }
        let pieceStart = pieceIdx > 1 ? byteTree.prefixSum(upTo: pieceIdx - 1) : 0
        let newlinesBefore = pieceIdx > 1 ? newlineTree.prefixSum(upTo: pieceIdx - 1) : 0
        let neededInPiece = line - newlinesBefore
        return pieceStart + offsetOfNewline(index: neededInPiece, in: pieces[pieceIdx - 1]) + 1
    }

    /// O(log n): byte range [start, end) for the given logical line (0-indexed).
    public func byteRange(forLine line: Int) -> Range<UInt64>? {
        guard let start = lineStartOffset(forLine: line) else { return nil }
        let end: UInt64
        if let nextStart = lineStartOffset(forLine: line + 1) {
            end = nextStart
        } else {
            end = byteLength
        }
        return start..<end
    }

    /// O(log n): which logical line (0-indexed) contains byte offset.
    public func line(containing offset: UInt64) -> Int {
        guard offset < byteLength else { return max(0, lineCount - 1) }
        var remaining = offset
        var accNewlines = 0
        for (idx, piece) in pieces.enumerated() {
            if remaining < piece.length {
                // count newlines within this piece up to `remaining`
                let src = source(for: piece)
                accNewlines += src.count(byte: 0x0a, in: piece.start..<(piece.start + remaining))
                return accNewlines
            }
            accNewlines += newlineCount(for: idx)
            remaining -= piece.length
        }
        return max(0, lineCount - 1)
    }

    // MARK: Edit API

    /// Insert `bytes` at byte offset. O(log n) to locate piece + O(1) append.
    public func insert(_ bytes: Data, at offset: UInt64) {
        precondition(offset <= byteLength)
        _generation &+= 1

        let addStart = UInt64(addBuffer.count)
        addBuffer.append(bytes)
        let newPiece = Piece(source: .add, start: addStart, length: UInt64(bytes.count))

        if pieces.isEmpty {
            pieces = [newPiece]
            rebuildTrees()
            return
        }

        let (pieceIdx, pieceOffset) = locatePiece(at: offset)

        if pieceOffset == 0 {
            // Insert before piece
            pieces.insert(newPiece, at: pieceIdx)
        } else if pieceOffset == pieces[pieceIdx].length {
            // Insert after piece
            pieces.insert(newPiece, at: pieceIdx + 1)
        } else {
            // Split piece at pieceOffset
            let original = pieces[pieceIdx]
            var left = Piece(source: original.source, start: original.start, length: pieceOffset)
            var right = Piece(source: original.source, start: original.start + pieceOffset, length: original.length - pieceOffset)
            left.cachedNewlineCount = -1
            right.cachedNewlineCount = -1
            pieces.replaceSubrange(pieceIdx...pieceIdx, with: [left, newPiece, right])
        }
        rebuildTrees()
    }

    /// Delete bytess in `range`. O(log n) to locate + occasional O(k) piece scan.
    public func delete(range: Range<UInt64>) {
        guard !range.isEmpty else { return }
        precondition(range.upperBound <= byteLength)
        _generation &+= 1

        let (startPiece, startOffset) = locatePiece(at: range.lowerBound)
        let (endPiece, endOffset) = locatePiece(at: range.upperBound)

        var newPieces: [Piece] = []
        newPieces.append(contentsOf: pieces[0..<startPiece])

        // Left remainder of startPiece
        if startOffset > 0 {
            var p = pieces[startPiece]
            p.length = startOffset
            p.cachedNewlineCount = -1
            newPieces.append(p)
        }

        // Right remainder of endPiece
        if endOffset < pieces[endPiece].length {
            var p = pieces[endPiece]
            p.start += endOffset
            p.length -= endOffset
            p.cachedNewlineCount = -1
            newPieces.append(p)
        }

        if endPiece + 1 <= pieces.count - 1 {
            newPieces.append(contentsOf: pieces[(endPiece + 1)...])
        }

        pieces = newPieces
        rebuildTrees()
    }

    // MARK: Snapshot / Undo

    public func makeSnapshot() -> PieceChainSnapshot {
        PieceChainSnapshot(pieces: pieces, addBufferLength: UInt64(addBuffer.count), generation: _generation)
    }

    public func restore(snapshot: PieceChainSnapshot) {
        pieces = snapshot.pieces
        _generation = snapshot.generation
        rebuildTrees()
    }

    // MARK: - Private Helpers

    private func source(for piece: Piece) -> BufferSource {
        switch piece.source {
        case .original: return originalSource
        case .add: return .memory(addBuffer)
        }
    }

    /// Returns (pieceIndex, byteOffsetWithinPiece) for the given absolute offset.
    private func locatePiece(at offset: UInt64) -> (Int, UInt64) {
        guard !pieces.isEmpty else { return (0, 0) }
        // Use Fenwick tree to find piece via O(log n) lowerBound
        let pieceIdx: Int
        if offset == 0 {
            return (0, 0)
        }
        // Find first piece where cumulative length >= offset+1
        let lb = byteTree.lowerBound(offset + 1)  // 1-indexed
        pieceIdx = min(lb - 1, pieces.count - 1)
        let pieceStart = pieceIdx > 0 ? byteTree.prefixSum(upTo: pieceIdx) : 0
        return (pieceIdx, offset - pieceStart)
    }

    private func iteratePieces(overlapping range: Range<UInt64>, _ body: (Range<UInt64>, BufferSource) -> Void) {
        var pos: UInt64 = 0
        for piece in pieces {
            let pieceEnd = pos + piece.length
            if pieceEnd <= range.lowerBound { pos = pieceEnd; continue }
            if pos >= range.upperBound { break }
            let overlapStart = max(pos, range.lowerBound)
            let overlapEnd = min(pieceEnd, range.upperBound)
            let innerStart = piece.start + (overlapStart - pos)
            let innerEnd = innerStart + (overlapEnd - overlapStart)
            body(innerStart..<innerEnd, source(for: piece))
            pos = pieceEnd
        }
    }

    /// Count newlines in pieces[idx]; update cache.
    private func newlineCount(for idx: Int) -> Int {
        if pieces[idx].cachedNewlineCount >= 0 { return pieces[idx].cachedNewlineCount }
        let p = pieces[idx]
        let count = source(for: p).count(byte: 0x0a, in: p.start..<(p.start + p.length))
        pieces[idx].cachedNewlineCount = count
        return count
    }

    /// Byte offset within the piece where the n-th newline (1-indexed) ends.
    private func offsetOfNewline(index: Int, in piece: Piece) -> UInt64 {
        if let offset = source(for: piece).offset(of: 0x0a, occurrence: index, in: piece.start..<(piece.start + piece.length)) {
            return offset
        }
        return piece.length - 1
    }

    private func rebuildTrees() {
        byteTree = FenwickTree(count: max(pieces.count, 1))
        newlineTree = FenwickTree(count: max(pieces.count, 1))
        for (i, piece) in pieces.enumerated() {
            byteTree.update(at: i + 1, delta: piece.length)
            newlineTree.update(at: i + 1, delta: newlineCount(for: i))
        }
    }
}
