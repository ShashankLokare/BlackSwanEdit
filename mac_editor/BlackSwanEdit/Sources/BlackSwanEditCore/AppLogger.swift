// Sources/BlackSwanEditCore/AppLogger.swift
import Foundation

public final class AppLogger: @unchecked Sendable {
    public static let shared = AppLogger()
    private let logFileURL: URL
    private let queue = DispatchQueue(label: "com.blackswanedit.logger")

    private init() {
        let mgr = FileManager.default
        let libraryDir = mgr.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let logDir = libraryDir.appendingPathComponent("Logs/BlackSwanEdit")
        try? mgr.createDirectory(at: logDir, withIntermediateDirectories: true)
        logFileURL = logDir.appendingPathComponent("app.log")
        
        log("--- BlackSwanEdit Launched ---")
    }

    public func log(_ message: String, level: String = "INFO") {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(level)] \(message)\n"
        print(line, terminator: "")
        queue.async {
            if let data = line.data(using: .utf8) {
                if let fh = try? FileHandle(forWritingTo: self.logFileURL) {
                    if #available(macOS 10.15.4, *) {
                        try? fh.seekToEnd()
                    } else {
                        fh.seekToEndOfFile()
                    }
                    fh.write(data)
                    try? fh.close()
                } else {
                    try? data.write(to: self.logFileURL)
                }
            }
        }
    }
}
