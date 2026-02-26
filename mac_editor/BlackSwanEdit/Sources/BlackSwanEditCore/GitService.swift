// Sources/BlackSwanEditCore/GitService.swift
//
// Git integration via shelling out to `/usr/bin/git`.
// All operations are async and non-blocking.

import Foundation

// MARK: - GitFileStatus

public struct GitFileStatus: Sendable {
    public enum State: Sendable {
        case modified, added, deleted, renamed, untracked, ignored, conflicted
    }
    public var fileURL: URL
    public var state: State
    public var isStaged: Bool
}

// MARK: - GitService protocol

public protocol GitService: AnyObject {
    /// Find the git root for a given path, or nil if not in a repo.
    func repoRoot(for url: URL) async -> URL?
    /// List all changed files.
    func status(repoRoot: URL) async throws -> [GitFileStatus]
    /// Return unified diff for a file.
    func diff(file: URL, staged: Bool, repoRoot: URL) async throws -> String
    /// Stage files.
    func stage(files: [URL], repoRoot: URL) async throws
    /// Unstage files.
    func unstage(files: [URL], repoRoot: URL) async throws
    /// Commit staged changes.
    func commit(message: String, repoRoot: URL) async throws
}

// MARK: - DefaultGitService

public final class DefaultGitService: GitService {
    private let gitPath: String

    public init(gitPath: String = "/usr/bin/git") {
        self.gitPath = gitPath
    }

    // MARK: Repo detection

    public func repoRoot(for url: URL) async -> URL? {
        let result = await shell(
            args: ["-C", url.path, "rev-parse", "--show-toplevel"],
            cwd: url
        )
        guard result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path)
    }

    // MARK: Status

    public func status(repoRoot: URL) async throws -> [GitFileStatus] {
        let result = await shell(
            args: ["-C", repoRoot.path, "status", "--porcelain=v1", "-z"],
            cwd: repoRoot
        )
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(result.stderr)
        }
        return parseStatus(result.stdout, repoRoot: repoRoot)
    }

    private func parseStatus(_ output: String, repoRoot: URL) -> [GitFileStatus] {
        // Porcelain v1 format: XY<space>filename\0
        var results: [GitFileStatus] = []
        let entries = output.components(separatedBy: "\0").filter { !$0.isEmpty }
        for entry in entries {
            guard entry.count >= 3 else { continue }
            let xy = String(entry.prefix(2))
            let path = String(entry.dropFirst(3))
            let fileURL = repoRoot.appendingPathComponent(path)
            let x = xy.first ?? " "
            let y = xy.dropFirst().first ?? " "
            let state: GitFileStatus.State
            switch (x, y) {
            case ("M", _), (_, "M"): state = .modified
            case ("A", _):           state = .added
            case ("D", _), (_, "D"): state = .deleted
            case ("R", _):           state = .renamed
            case ("?", "?"):         state = .untracked
            case ("!", "!"):         state = .ignored
            case ("U", _), (_, "U"): state = .conflicted
            default:                 state = .modified
            }
            let isStaged = x != " " && x != "?"
            results.append(GitFileStatus(fileURL: fileURL, state: state, isStaged: isStaged))
        }
        return results
    }

    // MARK: Diff

    public func diff(file: URL, staged: Bool, repoRoot: URL) async throws -> String {
        var args = ["-C", repoRoot.path, "diff"]
        if staged { args.append("--cached") }
        args.append("--")
        args.append(file.path)
        let result = await shell(args: args, cwd: repoRoot)
        guard result.exitCode == 0 else { throw GitError.commandFailed(result.stderr) }
        return result.stdout
    }

    // MARK: Stage / Unstage

    public func stage(files: [URL], repoRoot: URL) async throws {
        let paths = files.map(\.path)
        let result = await shell(args: ["-C", repoRoot.path, "add", "--"] + paths, cwd: repoRoot)
        guard result.exitCode == 0 else { throw GitError.commandFailed(result.stderr) }
    }

    public func unstage(files: [URL], repoRoot: URL) async throws {
        let paths = files.map(\.path)
        let result = await shell(args: ["-C", repoRoot.path, "restore", "--staged", "--"] + paths, cwd: repoRoot)
        guard result.exitCode == 0 else { throw GitError.commandFailed(result.stderr) }
    }

    // MARK: Commit

    public func commit(message: String, repoRoot: URL) async throws {
        let result = await shell(args: ["-C", repoRoot.path, "commit", "-m", message], cwd: repoRoot)
        guard result.exitCode == 0 else { throw GitError.commandFailed(result.stderr) }
    }

    // MARK: - Shell helper

    private struct ShellResult: Sendable {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    private func shell(args: [String], cwd: URL) async -> ShellResult {
        await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: gitPath)
            proc.arguments = args
            proc.currentDirectoryURL = cwd
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError  = errPipe
            do {
                try proc.run()
                proc.waitUntilExit()
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: ShellResult(stdout: out, stderr: err, exitCode: proc.terminationStatus))
            } catch {
                continuation.resume(returning: ShellResult(stdout: "", stderr: error.localizedDescription, exitCode: -1))
            }
        }
    }
}

// MARK: - GitError

public enum GitError: Error, LocalizedError {
    case commandFailed(String)
    public var errorDescription: String? {
        if case .commandFailed(let msg) = self { return "Git error: \(msg)" }
        return nil
    }
}
