// Sources/BlackSwanEditCore/SearchService.swift
//
// Search / Replace service: in-memory for small files, streaming for large files.
// Project-level "Find in Files" streams results asynchronously.

import Foundation

// MARK: - Search types

public struct SearchOptions: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let caseSensitive  = SearchOptions(rawValue: 1 << 0)
    public static let regex          = SearchOptions(rawValue: 1 << 1)
    public static let multiline      = SearchOptions(rawValue: 1 << 2)
    public static let wholeWord      = SearchOptions(rawValue: 1 << 3)
    public static let wrapAround     = SearchOptions(rawValue: 1 << 4)
    public static let inColumnBlock  = SearchOptions(rawValue: 1 << 5)
}

public struct SearchMatch: Sendable {
    public var byteRange: Range<UInt64>
    public var lineRange: Range<Int>
    /// Populated only for regex matches.
    public var captureGroups: [Range<UInt64>]

    public init(byteRange: Range<UInt64>, lineRange: Range<Int>, captureGroups: [Range<UInt64>] = []) {
        self.byteRange = byteRange
        self.lineRange = lineRange
        self.captureGroups = captureGroups
    }
}

public struct FileSearchResult: Sendable {
    public var fileURL: URL
    public var matches: [SearchMatch]
}

// MARK: - SearchService protocol

public protocol SearchService: AnyObject {
    /// Find all matches in a single buffer.
    func findAll(
        pattern: String,
        options: SearchOptions,
        in buffer: PieceChainBuffer
    ) async throws -> [SearchMatch]

    /// Replace all matches using a replacement template (supports $1 capture groups).
    /// Returns the number of replacements made.
    func replaceAll(
        matches: [SearchMatch],
        template: String,
        in buffer: PieceChainBuffer
    ) async throws -> Int

    /// Project-level search streaming results file-by-file.
    func findInFiles(
        pattern: String,
        options: SearchOptions,
        in directories: [URL],
        excluding globs: [String]
    ) -> AsyncThrowingStream<FileSearchResult, Error>
}

// MARK: - DefaultSearchService

public final class DefaultSearchService: SearchService {

    private static let streamingThreshold: Int = 100 * 1024 * 1024  // 100 MB
    private static let chunkSize: Int = 4 * 1024 * 1024             // 4 MB
    private static let chunkOverlap: Int = 4096                     // for cross-boundary matches

    public init() {}

    // MARK: findAll

    public func findAll(
        pattern: String,
        options: SearchOptions,
        in buffer: PieceChainBuffer
    ) async throws -> [SearchMatch] {
        let byteLen = buffer.byteLength
        if byteLen < UInt64(Self.streamingThreshold) {
            return try inMemorySearch(pattern: pattern, options: options, buffer: buffer)
        } else {
            return try await streamingSearch(pattern: pattern, options: options, buffer: buffer)
        }
    }

    private func inMemorySearch(
        pattern: String,
        options: SearchOptions,
        buffer: PieceChainBuffer
    ) throws -> [SearchMatch] {
        let data = buffer.allBytes()
        guard let str = String(data: data, encoding: .utf8) else { return [] }
        return try regexMatches(in: str, byteData: data, pattern: pattern, options: options, baseOffset: 0, buffer: buffer)
    }

    private func streamingSearch(
        pattern: String,
        options: SearchOptions,
        buffer: PieceChainBuffer
    ) async throws -> [SearchMatch] {
        var results: [SearchMatch] = []
        let total = buffer.byteLength
        var pos: UInt64 = 0
        var overlap: Data = Data()

        while pos < total {
            let chunkEnd = min(pos + UInt64(Self.chunkSize), total)
            let chunk = overlap + buffer.bytes(in: pos..<chunkEnd)

            // Convert to string for regex; skip invalid UTF-8 with replacement
            let str = String(bytes: chunk, encoding: .utf8) ?? String(chunk.map { Character(UnicodeScalar($0)) })

            let baseOffset = pos - UInt64(overlap.count)
            let matches = try regexMatches(in: str, byteData: chunk, pattern: pattern, options: options, baseOffset: baseOffset, buffer: buffer)
            results.append(contentsOf: matches)

            // Prepare overlap for next iteration
            let overlapStart = chunk.count > Self.chunkOverlap ? chunk.count - Self.chunkOverlap : 0
            overlap = Data(chunk[overlapStart...])
            pos = chunkEnd
        }

        return deduplicate(results)
    }

    private func regexMatches(
        in str: String,
        byteData: Data,
        pattern: String,
        options: SearchOptions,
        baseOffset: UInt64,
        buffer: PieceChainBuffer
    ) throws -> [SearchMatch] {
        var reOptions: NSRegularExpression.Options = []
        if !options.contains(.caseSensitive) { reOptions.insert(.caseInsensitive) }
        if options.contains(.multiline) { reOptions.insert(.anchorsMatchLines) }

        let safePattern: String
        if options.contains(.regex) {
            safePattern = options.contains(.wholeWord) ? "\\b\(pattern)\\b" : pattern
        } else {
            safePattern = options.contains(.wholeWord)
                ? "\\b\(NSRegularExpression.escapedPattern(for: pattern))\\b"
                : NSRegularExpression.escapedPattern(for: pattern)
        }

        let regex = try NSRegularExpression(pattern: safePattern, options: reOptions)
        let nsStr = str as NSString
        let range = NSRange(location: 0, length: nsStr.length)
        var results: [SearchMatch] = []

        regex.enumerateMatches(in: str, options: [], range: range) { result, _, _ in
            guard let result = result else { return }
            let r = result.range
            guard r.location != NSNotFound else { return }

            // Map NSRange (UTF-16) back to byte offsets
            let swiftRange = Range(r, in: str)!
            let byteStart = str.utf8.distance(from: str.utf8.startIndex, to: swiftRange.lowerBound.samePosition(in: str.utf8)!)
            let byteEnd   = str.utf8.distance(from: str.utf8.startIndex, to: swiftRange.upperBound.samePosition(in: str.utf8)!)

            let absStart = baseOffset + UInt64(byteStart)
            let absEnd   = baseOffset + UInt64(byteEnd)

            var captures: [Range<UInt64>] = []
            for g in 1..<result.numberOfRanges {
                let cr = result.range(at: g)
                if cr.location != NSNotFound, let swiftCR = Range(cr, in: str) {
                    let cs = str.utf8.distance(from: str.utf8.startIndex, to: swiftCR.lowerBound.samePosition(in: str.utf8)!)
                    let ce = str.utf8.distance(from: str.utf8.startIndex, to: swiftCR.upperBound.samePosition(in: str.utf8)!)
                    captures.append((baseOffset + UInt64(cs))..<(baseOffset + UInt64(ce)))
                }
            }

            let startLine = buffer.line(containing: absStart)
            let endOffset = absEnd > 0 ? absEnd - 1 : 0
            let endLine = buffer.line(containing: endOffset)
            let lineRange = startLine..<(endLine + 1)

            results.append(SearchMatch(byteRange: absStart..<absEnd, lineRange: lineRange, captureGroups: captures))
        }
        return results
    }

    private func deduplicate(_ matches: [SearchMatch]) -> [SearchMatch] {
        var seen = Set<Range<UInt64>>()
        return matches.filter { seen.insert($0.byteRange).inserted }
    }

    // MARK: replaceAll

    public func replaceAll(
        matches: [SearchMatch],
        template: String,
        in buffer: PieceChainBuffer
    ) async throws -> Int {
        // Apply replacements in reverse order so byte offsets stay valid
        let sorted = matches.sorted { $0.byteRange.lowerBound > $1.byteRange.lowerBound }
        var count = 0
        for match in sorted {
            let replacement = applyTemplate(template, to: match, buffer: buffer)
            buffer.delete(range: match.byteRange)
            buffer.insert(Data(replacement.utf8), at: match.byteRange.lowerBound)
            count += 1
        }
        return count
    }

    private func applyTemplate(_ template: String, to match: SearchMatch, buffer: PieceChainBuffer) -> String {
        var result = template
        for (i, captureRange) in match.captureGroups.enumerated() {
            let captureData = buffer.bytes(in: captureRange)
            let captureStr = String(data: captureData, encoding: .utf8) ?? ""
            result = result.replacingOccurrences(of: "$\(i + 1)", with: captureStr)
        }
        return result
    }

    // MARK: findInFiles

    public func findInFiles(
        pattern: String,
        options: SearchOptions,
        in directories: [URL],
        excluding globs: [String]
    ) -> AsyncThrowingStream<FileSearchResult, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) { [self] in
                do {
                    let fm = FileManager.default
                    let enumeratorOptions: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
                    for dir in directories {
                        guard let enumerator = fm.enumerator(
                            at: dir,
                            includingPropertiesForKeys: [.isRegularFileKey],
                            options: enumeratorOptions
                        ) else { continue }

                        for case let fileURL as URL in enumerator {
                            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                            let data = (try? Data(contentsOf: fileURL)) ?? Data()
                            let buf = PieceChainBuffer(data: data)
                            let matches = try await self.findAll(pattern: pattern, options: options, in: buf)
                            if !matches.isEmpty {
                                continuation.yield(FileSearchResult(fileURL: fileURL, matches: matches))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - SearchFavorite

public struct SearchFavorite: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var pattern: String
    public var template: String
    public var optionsRaw: UInt32

    public var options: SearchOptions { SearchOptions(rawValue: optionsRaw) }

    public init(name: String, pattern: String, template: String, options: SearchOptions) {
        id = UUID()
        self.name = name
        self.pattern = pattern
        self.template = template
        optionsRaw = options.rawValue
    }
}
