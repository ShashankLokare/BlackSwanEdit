// Sources/BlackSwanEditCore/LanguageService.swift
//
// Language detection, token-rule loading, and incremental tokenisation
// for syntax highlighting.

import Foundation

// MARK: - Token types

public struct TokenRule: Codable, Sendable {
    public var id: String          // e.g. "keyword", "string", "comment"
    public var pattern: String     // regex pattern
    public var flags: [String]     // e.g. ["dotall"]
}

public struct LanguageDef: Codable, Sendable {
    public var name: String
    public var fileExtensions: [String]
    public var shebangs: [String]
    public var tokenRules: [TokenRule]
    public var foldStart: String?
    public var foldEnd: String?
    public var foldIndent: Bool
    public var embeddedRegions: [EmbeddedRegion]
}

public struct EmbeddedRegion: Codable, Sendable {
    public var startPattern: String
    public var endPattern: String
    public var languageName: String
}

// MARK: - Token

public struct Token: Sendable {
    public var typeID: String
    public var byteRange: Range<UInt64>
}

// MARK: - LanguageService protocol

public protocol LanguageService: AnyObject {
    /// All loaded language definitions (populated from bundle + user langdir).
    var languages: [LanguageDef] { get }

    /// Detect language for a given file URL / content header.
    func detect(for url: URL, contentPrefix: Data) -> LanguageDef?

    /// Tokenise a single line given its prior state.
    func tokenise(line: Data, language: LanguageDef, priorState: TokeniserState) -> (tokens: [Token], newState: TokeniserState)

    /// Load additional language definitions from a directory of `.nelang` JSON files.
    func loadLanguages(from directory: URL) throws
}

// MARK: - TokeniserState

/// Serialisable state carried from one line to the next (handles multi-line constructs).
public struct TokeniserState: Equatable, Sendable {
    public enum Context: String, Codable, Sendable {
        case normal, blockComment, multilineString
    }
    public var context: Context = .normal
    public var depth: Int = 0        // e.g. nested block-comment depth

    public static let initial = TokeniserState()
}

// MARK: - DefaultLanguageService

public final class DefaultLanguageService: LanguageService {
    public private(set) var languages: [LanguageDef] = []
    private var compiledRules: [String: [(id: String, regex: NSRegularExpression)]] = [:]

    public init() {
        loadBuiltins()
    }

    private func loadBuiltins() {
        // Load .nelang files bundled inside Resources/Languages
        if let dir = Bundle.module.url(forResource: "Languages", withExtension: nil) {
            try? loadLanguages(from: dir)
        }
    }

    public func loadLanguages(from directory: URL) throws {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for item in items where item.pathExtension == "nelang" {
            let data = try Data(contentsOf: item)
            let lang = try JSONDecoder().decode(LanguageDef.self, from: data)
            languages.removeAll { $0.name == lang.name }
            languages.append(lang)
            compiledRules[lang.name] = compileRules(lang.tokenRules)
        }
    }

    public func detect(for url: URL, contentPrefix: Data) -> LanguageDef? {
        let ext = url.pathExtension.lowercased()
        if let byExt = languages.first(where: { $0.fileExtensions.contains(ext) }) {
            return byExt
        }
        // Shebang detection
        if contentPrefix.starts(with: [0x23, 0x21]) { // "#!"
            let header = String(data: contentPrefix.prefix(128), encoding: .utf8) ?? ""
            return languages.first { lang in lang.shebangs.contains { header.contains($0) } }
        }
        return nil
    }

    public func tokenise(
        line: Data,
        language: LanguageDef,
        priorState: TokeniserState
    ) -> (tokens: [Token], newState: TokeniserState) {
        guard let str = String(data: line, encoding: .utf8) else {
            return ([], priorState)
        }
        let rules = compiledRules[language.name] ?? []
        var tokens: [Token] = []
        let nsStr = str as NSString
        for (id, regex) in rules {
            let range = NSRange(location: 0, length: nsStr.length)
            regex.enumerateMatches(in: str, range: range) { result, _, _ in
                guard let result = result else { return }
                let r = result.range
                guard r.location != NSNotFound,
                      let swiftRange = Range(r, in: str),
                      let byteStart = swiftRange.lowerBound.samePosition(in: str.utf8),
                      let byteEnd   = swiftRange.upperBound.samePosition(in: str.utf8)
                else { return }
                let bs = str.utf8.distance(from: str.utf8.startIndex, to: byteStart)
                let be = str.utf8.distance(from: str.utf8.startIndex, to: byteEnd)
                tokens.append(Token(typeID: id, byteRange: UInt64(bs)..<UInt64(be)))
            }
        }
        // Simplified state transition — a full implementation would track block comments
        return (tokens, priorState)
    }

    private func compileRules(_ rules: [TokenRule]) -> [(id: String, regex: NSRegularExpression)] {
        rules.compactMap { rule in
            var opts: NSRegularExpression.Options = []
            if rule.flags.contains("dotall") { opts.insert(.dotMatchesLineSeparators) }
            if rule.flags.contains("caseInsensitive") { opts.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: opts) else { return nil }
            return (rule.id, regex)
        }
    }
}
