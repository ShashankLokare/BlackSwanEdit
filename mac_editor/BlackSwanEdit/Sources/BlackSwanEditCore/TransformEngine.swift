import Foundation

public enum TransformType {
    case uppercase
    case lowercase
    case trimTrailingWhitespace
    case sortLines
}

public enum TransformError: Error {
    case fileTooLargeForSorting
    case writeFailed
}

/// Executes heavy file-wide string transformations safely.
public final class TransformEngine {
    
    public init() {}
    
    /// Applies a transformation to the buffer.
    /// For sequential modifications (Uppercase/Trim), runs a streaming read-write on a background thread.
    /// For Sorting, requires loading lines into memory (MVP) or throws if file is > 10MB.
    public func apply(transform: TransformType, to buffer: PieceChainBuffer) async throws {
        let maxSortableBytes: UInt64 = 10 * 1024 * 1024 // 10 MB limit for MVP simple sorting
        
        switch transform {
        case .sortLines:
            if buffer.byteLength > maxSortableBytes {
                throw TransformError.fileTooLargeForSorting
            }
            try await performSort(on: buffer)
        case .uppercase, .lowercase, .trimTrailingWhitespace:
            try await performStreamingTransform(transform, on: buffer)
        }
    }
    
    private func performSort(on buffer: PieceChainBuffer) async throws {
        // Simple in-memory sort for MVP
        let data = buffer.bytes(in: 0..<buffer.byteLength)
        guard let string = String(data: data, encoding: .utf8) else { return }
        
        let lines = string.components(separatedBy: .newlines)
        let sortedLines = lines.sorted()
        let sortedString = sortedLines.joined(separator: "\n")
        
        await MainActor.run {
            buffer.delete(range: 0..<buffer.byteLength)
            buffer.insert(Data(sortedString.utf8), at: 0)
        }
    }
    
    private func performStreamingTransform(_ type: TransformType, on buffer: PieceChainBuffer) async throws {
        let chunkSize: UInt64 = 4 * 1024 * 1024 // 4 MB
        let totalBytes = buffer.byteLength
        
        // 1. Create temporary file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempURL)
        
        // 2. Stream chunks and apply transform
        var offset: UInt64 = 0
        while offset < totalBytes {
            let length = min(chunkSize, totalBytes - offset)
            let chunkData = buffer.bytes(in: offset..<(offset + length))
            
            if let str = String(data: chunkData, encoding: .utf8) {
                let transformedStr: String
                switch type {
                case .uppercase:
                    transformedStr = str.uppercased()
                case .lowercase:
                    transformedStr = str.lowercased()
                case .trimTrailingWhitespace:
                    transformedStr = str.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression)
                default:
                    transformedStr = str
                }
                
                if let tData = transformedStr.data(using: .utf8) {
                    fileHandle.write(tData)
                }
            }
            offset += length
        }
        
        try fileHandle.close()
        
        // 3. Atomically swap buffer contents
        // We read from the mapped temp file and replace the root node.
        // For MVP: load temp into new AddBuffer if small enough, or re-init PieceChainBuffer.
        // Simpler for MVP since we control the buffer: Just delete all and insert everything. 
        // In reality, we would swap out the backing store mapped file paths.
        let finalData = try Data(contentsOf: tempURL, options: .mappedIfSafe)
        
        await MainActor.run {
            buffer.delete(range: 0..<buffer.byteLength)
            buffer.insert(finalData, at: 0)
        }
        
        try? FileManager.default.removeItem(at: tempURL)
    }
}
