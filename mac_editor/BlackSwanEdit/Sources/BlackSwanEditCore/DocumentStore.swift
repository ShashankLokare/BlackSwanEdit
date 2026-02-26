// Sources/BlackSwanEditCore/DocumentStore.swift
//
// DocumentStore manages the lifecycle of all open documents.
// It is the single source of truth for all open DocumentBuffers.

import Foundation
import Combine

// MARK: - DocumentBuffer protocol

/// High-level document abstraction used by the editor UI.
public protocol DocumentBuffer: AnyObject {
    var id: UUID { get }
    var fileURL: URL? { get }
    var isDirty: Bool { get }
    var encoding: String.Encoding { get }
    var lineEnding: LineEnding { get }
    var isLargeFileMode: Bool { get }
    var buffer: PieceChainBuffer { get }

    func save(to url: URL) throws
    func reload() throws
}

// MARK: - LineEnding

public enum LineEnding: String, Sendable {
    case lf   = "\n"
    case crlf = "\r\n"
    case cr   = "\r"

    public static func detect(from data: Data) -> LineEnding {
        for i in 0..<min(data.count - 1, 8192) {
            if data[i] == 0x0d {
                if i + 1 < data.count && data[i + 1] == 0x0a { return .crlf }
                return .cr
            }
            if data[i] == 0x0a { return .lf }
        }
        return .lf
    }
}

// MARK: - LocalDocumentBuffer

public final class LocalDocumentBuffer: DocumentBuffer, ObservableObject {
    public let id = UUID()
    public private(set) var fileURL: URL?
    @Published public private(set) var isDirty = false
    @Published public var languageOverride: String? = nil
    @Published public var isHexMode = false
    @Published public var cursorLine: Int = 0
    @Published public var cursorColumn: Int = 0
    @Published public var cursorByteOffset: UInt64 = 0
    public let encoding: String.Encoding
    public let lineEnding: LineEnding
    public let isLargeFileMode: Bool
    public let buffer: PieceChainBuffer

    // Undo stack
    private var undoStack: [PieceChainSnapshot] = []
    private var redoStack: [PieceChainSnapshot] = []
    private static let maxUndoDepth = 10_000

    /// Large file mode threshold in bytes.
    public static let largeFileModeThreshold: UInt64 = 100 * 1024 * 1024  // 100 MB

    // MARK: Init

    public init(url: URL) throws {
        fileURL = url
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? UInt64) ?? 0

        // Limit sampling to avoid massive allocations
        let sampleData = try Data(contentsOf: url, options: .mappedRead).prefix(8192)
        encoding = Self.detectEncoding(bom: Array(sampleData.prefix(4))) ?? .utf8

        if fileSize >= LocalDocumentBuffer.largeFileModeThreshold {
            isLargeFileMode = true
            let mapped = try MappedFile(url: url)
            buffer = try PieceChainBuffer(mappedFile: mapped)
        } else {
            isLargeFileMode = false
            let data = try Data(contentsOf: url)
            buffer = PieceChainBuffer(data: data)
        }

        lineEnding = LineEnding.detect(from: Data(sampleData))
    }

    public init(text: String = "") {
        fileURL = nil
        encoding = .utf8
        lineEnding = .lf
        isLargeFileMode = false
        buffer = PieceChainBuffer(data: Data(text.utf8))
    }

    // MARK: Edit

    public func insert(_ text: String, at offset: UInt64) {
        pushUndo()
        buffer.insert(Data(text.utf8), at: offset)
        isDirty = true
        redoStack.removeAll()
    }

    public func delete(range: Range<UInt64>) {
        pushUndo()
        buffer.delete(range: range)
        isDirty = true
        redoStack.removeAll()
    }

    // MARK: Undo / Redo
    
    public func markDirty() {
        isDirty = true
    }

    public func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(buffer.makeSnapshot())
        buffer.restore(snapshot: snapshot)
        isDirty = true
    }

    public func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(buffer.makeSnapshot())
        buffer.restore(snapshot: snapshot)
        isDirty = true
    }

    private func pushUndo() {
        undoStack.append(buffer.makeSnapshot())
        if undoStack.count > Self.maxUndoDepth {
            undoStack.removeFirst()
        }
    }

    // MARK: Save (atomic)

    public func save(to url: URL) throws {
        let tmpURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")

        // Stream-write through piece chain to avoid huge in-memory allocation
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tmpURL)
        defer { try? fh.close() }

        let chunkSize: UInt64 = 4 * 1024 * 1024  // 4 MB
        var pos: UInt64 = 0
        let total = buffer.byteLength
        while pos < total {
            let end = min(pos + chunkSize, total)
            let chunk = buffer.bytes(in: pos..<end)
            fh.write(chunk)
            pos = end
        }
        try fh.synchronize()

        // Atomic rename
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
        fileURL = url
        isDirty = false
    }

    public func reload() throws {
        guard let url = fileURL else { return }
        let data = try Data(contentsOf: url)
        // Replace buffer in-place (simple: treat as full replace)
        buffer.delete(range: 0..<buffer.byteLength)
        buffer.insert(data, at: 0)
        isDirty = false
        undoStack.removeAll()
        redoStack.removeAll()
    }

    // MARK: Encoding Detection

    private static func detectEncoding(bom: [UInt8]) -> String.Encoding? {
        if bom.prefix(3) == [0xEF, 0xBB, 0xBF] { return .utf8 }
        if bom.prefix(2) == [0xFF, 0xFE] { return .utf16LittleEndian }
        if bom.prefix(2) == [0xFE, 0xFF] { return .utf16BigEndian }
        return nil
    }
}

// MARK: - DocumentStore

@MainActor
public final class DocumentStore: ObservableObject {
    public static let shared = DocumentStore()
    private init() {}

    @Published public private(set) var documents: [LocalDocumentBuffer] = []
    @Published public var activeDocument: LocalDocumentBuffer?

    public func open(url: URL) throws -> LocalDocumentBuffer {
        if let existing = documents.first(where: { $0.fileURL == url }) {
            activeDocument = existing
            return existing
        }
        let doc = try LocalDocumentBuffer(url: url)
        documents.append(doc)
        activeDocument = doc
        return doc
    }

    public func newDocument() -> LocalDocumentBuffer {
        let doc = LocalDocumentBuffer()
        documents.append(doc)
        activeDocument = doc
        return doc
    }

    public func newDocument(text: String) -> LocalDocumentBuffer {
        let doc = LocalDocumentBuffer(text: text)
        documents.append(doc)
        activeDocument = doc
        return doc
    }

    public func close(document: LocalDocumentBuffer) {
        documents.removeAll { $0.id == document.id }
        if activeDocument?.id == document.id {
            activeDocument = documents.last
        }
    }
}
