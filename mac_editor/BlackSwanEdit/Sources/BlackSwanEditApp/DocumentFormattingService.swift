import Foundation
import BlackSwanEditCore

enum DocumentFormattingError: LocalizedError {
    case invalidUTF8
    case unsupported
    case formatterMissing(String)
    case formatterFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "The document is not valid UTF-8."
        case .unsupported:
            return "No formatter is available for this file type."
        case .formatterMissing(let tool):
            return "\(tool) is not installed."
        case .formatterFailed(let message):
            return message
        }
    }
}

final class DocumentFormattingService {
    static let shared = DocumentFormattingService()

    private init() {}

    func format(document: LocalDocumentBuffer) async throws {
        let snapshot = await MainActor.run { document.buffer.bytes(in: 0..<document.buffer.byteLength) }
        guard let content = String(data: snapshot, encoding: .utf8) else {
            throw DocumentFormattingError.invalidUTF8
        }

        let formatted = try formatText(
            content,
            fileURL: document.fileURL,
            languageOverride: document.languageOverride
        )

        guard formatted != content else { return }

        await MainActor.run {
            document.buffer.delete(range: 0..<document.buffer.byteLength)
            document.buffer.insert(Data(formatted.utf8), at: 0)
            document.markDirty()
        }
    }

    private func formatText(_ text: String, fileURL: URL?, languageOverride: String?) throws -> String {
        let ext = fileURL?.pathExtension.lowercased() ?? inferredExtension(for: languageOverride)

        if ext == "json" {
            return try formatJSON(text)
        }
        if ["xml", "xhtml", "svg"].contains(ext) {
            return try formatXML(text)
        }
        if ["py", "pyw"].contains(ext) {
            return try runExternalFormatter(command: "black", args: ["--quiet", "-"], input: text)
        }
        if ["sh", "bash", "zsh"].contains(ext) {
            return try runExternalFormatter(command: "shfmt", args: [], input: text)
        }
        if ["toml"].contains(ext) {
            return try runExternalFormatter(command: "taplo", args: ["fmt", "-"], input: text)
        }
        if ["js", "mjs", "cjs", "jsx", "ts", "tsx", "jsonc", "yaml", "yml", "html", "htm", "css", "scss", "less", "md", "markdown"].contains(ext) {
            let stdinPath = fileURL?.path ?? "document.\(ext)"
            return try runExternalFormatter(command: "prettier", args: ["--stdin-filepath", stdinPath], input: text)
        }

        throw DocumentFormattingError.unsupported
    }

    private func inferredExtension(for languageOverride: String?) -> String {
        switch languageOverride {
        case "Python": return "py"
        case "Shell Script": return "sh"
        case "JavaScript": return "js"
        case "JavaScript (JSX)": return "jsx"
        case "TypeScript": return "ts"
        case "JSON": return "json"
        case "XML": return "xml"
        case "YAML": return "yaml"
        case "Ruby": return "rb"
        case "TOML": return "toml"
        case "Markdown": return "md"
        default: return ""
        }
    }

    private func formatJSON(_ text: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let formattedData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard var formatted = String(data: formattedData, encoding: .utf8) else {
            throw DocumentFormattingError.invalidUTF8
        }
        if !formatted.hasSuffix("\n") {
            formatted.append("\n")
        }
        return formatted
    }

    private func formatXML(_ text: String) throws -> String {
        let doc = try XMLDocument(xmlString: text, options: [.documentTidyXML])
        let data = doc.xmlData(options: [.nodePrettyPrint])
        guard var formatted = String(data: data, encoding: .utf8) else {
            throw DocumentFormattingError.invalidUTF8
        }
        if !formatted.hasSuffix("\n") {
            formatted.append("\n")
        }
        return formatted
    }

    private func runExternalFormatter(command: String, args: [String], input: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        do {
            try process.run()
        } catch {
            throw DocumentFormattingError.formatterMissing(command)
        }

        let inputData = Data(input.utf8)
        stdinPipe.fileHandleForWriting.write(inputData)
        try? stdinPipe.fileHandleForWriting.close()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DocumentFormattingError.formatterFailed(message?.isEmpty == false ? message! : "Formatter failed for \(command).")
        }

        guard let output = String(data: stdoutData, encoding: .utf8) else {
            throw DocumentFormattingError.invalidUTF8
        }
        return output
    }
}
