// Sources/BlackSwanEditCore/TerminalSession.swift
//
// Integrated terminal: spawns a shell in a PTY and streams I/O.
// The UI layer (TerminalPanelController) connects to outputStream
// and sends input via sendInput(_:).

import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - TerminalSession

public final class TerminalSession: @unchecked Sendable {
    private var masterFD: Int32 = -1
    private var process: Process?
    private let outputContinuation: AsyncStream<Data>.Continuation
    public let outputStream: AsyncStream<Data>
    private var readThread: Thread?

    public private(set) var isRunning = false

    public init() {
        var cont: AsyncStream<Data>.Continuation!
        outputStream = AsyncStream { cont = $0 }
        outputContinuation = cont
    }

    deinit {
        terminate()
    }

    // MARK: Launch

    public func launch(
        shell: URL = URL(fileURLWithPath: "/bin/zsh"),
        cwd: URL,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard !isRunning else { return }

        // Open PTY master
        var master: Int32 = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
        guard grantpt(master) == 0, unlockpt(master) == 0 else {
            close(master)
            throw POSIXError(.init(rawValue: errno)!)
        }
        masterFD = master

        // Open PTY slave
        let slaveName = String(cString: ptsname(master))
        let slave = open(slaveName, O_RDWR)
        guard slave >= 0 else { throw POSIXError(.init(rawValue: errno)!) }

        // Spawn process
        let proc = Process()
        proc.executableURL = shell
        proc.currentDirectoryURL = cwd
        proc.environment = env.merging([
            "TERM": "xterm-256color",
            "COLUMNS": "80",
            "LINES": "24"
        ]) { $1 }
        proc.standardInput  = FileHandle(fileDescriptor: slave)
        proc.standardOutput = FileHandle(fileDescriptor: slave)
        proc.standardError  = FileHandle(fileDescriptor: slave)
        proc.terminationHandler = { [weak self] _ in
            self?.isRunning = false
            self?.outputContinuation.finish()
        }
        close(slave)

        try proc.run()
        process = proc
        isRunning = true

        // Start background read loop
        let masterHandle = FileHandle(fileDescriptor: masterFD)
        let cont = outputContinuation
        readThread = Thread {
            while true {
                let data = masterHandle.availableData
                if data.isEmpty { break }
                cont.yield(data)
            }
        }
        readThread?.start()
    }

    // MARK: I/O

    public func sendInput(_ string: String) {
        guard isRunning, masterFD >= 0 else { return }
        var bytes = Array(string.utf8)
        write(masterFD, &bytes, bytes.count)
    }

    public func resize(cols: UInt16, rows: UInt16) {
        guard masterFD >= 0 else { return }
        var ws = winsize()
        ws.ws_col = cols
        ws.ws_row = rows
        ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    public func terminate() {
        process?.terminate()
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        isRunning = false
    }
}

// MARK: - TerminalPanel protocol

public protocol TerminalPanel: AnyObject {
    var session: TerminalSession { get }
    func show()
    func hide()
    func toggle()
}
