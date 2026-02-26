// Sources/BlackSwanEditCore/Selection.swift
//
// Selection types for linear and rectangular (column/block) mode.

import Foundation

// MARK: - TextPosition

/// A position in the document as (line, column), both 0-indexed.
public struct TextPosition: Equatable, Hashable, Comparable, Sendable {
    public var line: Int
    /// UTF-16 code-unit column within the line.
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        lhs.line != rhs.line ? lhs.line < rhs.line : lhs.column < rhs.column
    }
}

// MARK: - LinearSelection

/// Standard caret or contiguous selection.
public struct LinearSelection: Equatable, Sendable {
    public var anchor: TextPosition
    public var active: TextPosition

    public var isEmpty: Bool { anchor == active }

    public var start: TextPosition { min(anchor, active) }
    public var end: TextPosition   { max(anchor, active) }

    public init(anchor: TextPosition, active: TextPosition) {
        self.anchor = anchor
        self.active = active
    }

    public init(caret position: TextPosition) {
        self.anchor = position
        self.active = position
    }
}

// MARK: - ColumnSelection

/// Rectangular / block selection (UltraEdit-style column mode).
/// Defines a rectangle by two corners — the anchor and active positions.
/// Every line between top and bottom is included, from leftCol to rightCol.
public struct ColumnSelection: Equatable, Sendable {
    public var anchor: TextPosition
    public var active: TextPosition

    public init(anchor: TextPosition, active: TextPosition) {
        self.anchor = anchor
        self.active = active
    }

    // MARK: Derived Properties

    public var topLine: Int    { min(anchor.line, active.line) }
    public var bottomLine: Int { max(anchor.line, active.line) }
    public var leftCol: Int    { min(anchor.column, active.column) }
    public var rightCol: Int   { max(anchor.column, active.column) }

    /// Width of the column selection in UTF-16 code units.
    public var width: Int { rightCol - leftCol }
    /// Height in lines (inclusive).
    public var height: Int { bottomLine - topLine + 1 }

    /// All lines covered by the selection.
    public var lineRange: ClosedRange<Int> { topLine...bottomLine }
}

// MARK: - EditorSelection

/// Tagged union of the two selection modes.
public enum EditorSelection: Equatable, Sendable {
    case linear(LinearSelection)
    case column(ColumnSelection)

    public var isColumn: Bool {
        if case .column = self { return true }
        return false
    }

    public var isEmpty: Bool {
        switch self {
        case .linear(let s): return s.isEmpty
        case .column(let s): return s.width == 0 && s.height == 1
        }
    }
}

// MARK: - ColumnBlock (clipboard payload)

/// The data copied from a rectangular selection, one row per line.
public struct ColumnBlock: Sendable {
    /// Each element is the raw bytes for one row's column range.
    public var rows: [Data]

    /// Maximum column width (in bytes). Used for padding on paste.
    public var maxWidth: Int { rows.map(\.count).max() ?? 0 }

    public init(rows: [Data]) {
        self.rows = rows
    }

    /// Pad all rows to the same width with spaces.
    public func padded() -> ColumnBlock {
        let w = maxWidth
        return ColumnBlock(rows: rows.map { row in
            if row.count >= w { return row }
            return row + Data(repeating: 0x20, count: w - row.count)
        })
    }
}

// MARK: - ColumnMode Operations on PieceChainBuffer

extension PieceChainBuffer {

    /// Extract rows for a rectangular selection. Returns one Data per line.
    public func extractColumnBlock(_ sel: ColumnSelection) -> ColumnBlock {
        var rows: [Data] = []
        for lineIdx in sel.lineRange {
            guard let lineByteRange = byteRange(forLine: lineIdx) else {
                rows.append(Data())
                continue
            }
            let lineData = bytes(in: lineByteRange)
            // Convert line bytes to UTF-16 for column alignment
            guard let str = String(data: lineData, encoding: .utf8) else {
                rows.append(Data())
                continue
            }
            let utf16 = Array(str.utf16)
            let safeLeft  = min(sel.leftCol,  utf16.count)
            let safeRight = min(sel.rightCol, utf16.count)
            let colSlice = utf16[safeLeft..<safeRight]
            let colStr = String(decoding: Array(colSlice), as: UTF16.self)
            rows.append(Data((colStr ?? "").utf8))
        }
        return ColumnBlock(rows: rows)
    }

    /// Delete the column range and return a ColumnBlock of what was removed.
    @discardableResult
    public func deleteColumnRange(_ sel: ColumnSelection) -> ColumnBlock {
        let block = extractColumnBlock(sel)
        // Process lines in reverse order to preserve byte offsets
        for lineIdx in sel.lineRange.reversed() {
            guard let lineByteRange = byteRange(forLine: lineIdx) else { continue }
            let lineData = bytes(in: lineByteRange)
            guard let str = String(data: lineData, encoding: .utf8) else { continue }
            let utf16 = Array(str.utf16)
            let safeLeft  = min(sel.leftCol,  utf16.count)
            let safeRight = min(sel.rightCol, utf16.count)
            if safeLeft >= safeRight { continue }

            // Rebuild line without the column range
            var newUtf16 = Array(utf16[0..<safeLeft]) + Array(utf16[safeRight...])
            let newStr = String(decoding: newUtf16, as: UTF16.self)
            let newData = Data(newStr.utf8)
            let regionStart = lineByteRange.lowerBound + UInt64(
                String(decoding: Array(utf16[0..<safeLeft]), as: UTF16.self).utf8.count
            )
            let regionEnd = lineByteRange.lowerBound + UInt64(
                String(decoding: Array(utf16[0..<safeRight]), as: UTF16.self).utf8.count
            )
            delete(range: regionStart..<regionEnd)
        }
        return block
    }

    /// Insert a ColumnBlock at (startLine, col), padding shorter lines.
    public func insertColumnBlock(_ block: ColumnBlock, at col: Int, startLine: Int) {
        let paddedBlock = block.padded()
        for (i, row) in paddedBlock.rows.enumerated() {
            let targetLine = startLine + i
            guard let lineByteRange = byteRange(forLine: targetLine) else { continue }
            let lineData = bytes(in: lineByteRange)
            guard let str = String(data: lineData, encoding: .utf8) else { continue }
            let utf16 = Array(str.utf16)
            let insertCol = min(col, utf16.count)
            // Byte offset of the insert column within the line
            let prefix = String(decoding: Array(utf16[0..<insertCol]), as: UTF16.self)
            let insertOffset = lineByteRange.lowerBound + UInt64(prefix.utf8.count)
            insert(row, at: insertOffset)
        }
    }

    /// Fill selection with a repeated byte sequence.
    public func fillColumn(_ sel: ColumnSelection, with fill: String) {
        let fillData = Data(fill.utf8)
        for lineIdx in sel.lineRange.reversed() {
            guard let lineByteRange = byteRange(forLine: lineIdx) else { continue }
            let lineData = bytes(in: lineByteRange)
            guard let str = String(data: lineData, encoding: .utf8) else { continue }
            let utf16 = Array(str.utf16)
            let safeLeft  = min(sel.leftCol,  utf16.count)
            let safeRight = min(sel.rightCol, utf16.count)
            let prefix = String(decoding: Array(utf16[0..<safeLeft]), as: UTF16.self)
            let colPrefix = String(decoding: Array(utf16[0..<safeRight]), as: UTF16.self)
            let regionStart = lineByteRange.lowerBound + UInt64(prefix.utf8.count)
            let regionEnd   = lineByteRange.lowerBound + UInt64(colPrefix.utf8.count)
            if regionEnd > regionStart { delete(range: regionStart..<regionEnd) }
            insert(fillData, at: regionStart)
        }
    }

    /// Insert sequential decimal or hex numbers into each row of the selection.
    public func insertSequentialNumbers(
        _ sel: ColumnSelection,
        start: Int, step: Int, radix: Int
    ) {
        var current = start
        for lineIdx in sel.lineRange {
            let numStr = radix == 16 ? String(current, radix: 16).uppercased() : "\(current)"
            fillColumn(ColumnSelection(
                anchor: TextPosition(line: lineIdx, column: sel.leftCol),
                active: TextPosition(line: lineIdx, column: sel.leftCol)
            ), with: numStr)
            current += step
        }
    }

    /// Sum numeric values in each row of a column selection.
    public func sumNumericColumn(_ sel: ColumnSelection) -> Double {
        var total = 0.0
        let block = extractColumnBlock(sel)
        for row in block.rows {
            if let str = String(data: row, encoding: .utf8),
               let v = Double(str.trimmingCharacters(in: .whitespaces)) {
                total += v
            }
        }
        return total
    }
}
