// Sources/BlackSwanEditCore/RemoteFileService.swift
//
// SFTP remote file service — protocol + stub implementation.
// Full implementation will use NMSSH (libssh2 wrapper) in V2.
// Credentials are stored in macOS Keychain via Security framework.

import Foundation
import Security

// MARK: - RemoteFileEntry

public struct RemoteFileEntry: Sendable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: UInt64
    public var modifiedDate: Date

    public init(name: String, path: String, isDirectory: Bool, size: UInt64, modifiedDate: Date) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedDate = modifiedDate
    }
}

// MARK: - RemoteFileService protocol

public protocol RemoteFileService: AnyObject {
    var isConnected: Bool { get }

    func connect(host: String, port: UInt16, username: String, password: String) async throws
    func connectWithKeychain(host: String, port: UInt16, username: String) async throws
    func listDirectory(path: String) async throws -> [RemoteFileEntry]
    func readFile(path: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Data
    func writeFile(data: Data, path: String) async throws
    func disconnect()
}

// MARK: - KeychainCredentialStore

public enum KeychainCredentialStore {
    public static func store(host: String, username: String, password: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: host,
            kSecAttrAccount: username,
            kSecValueData: Data(password.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [CFString: Any] = [kSecValueData: Data(password.utf8)]
            SecItemUpdate(query as CFDictionary, update as CFDictionary)
        } else if status != errSecSuccess {
            throw KeychainError.storeFailed(status)
        }
    }

    public static func retrieve(host: String, username: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: host,
            kSecAttrAccount: username,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.notFound
        }
        return password
    }

    public static func delete(host: String, username: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: host,
            kSecAttrAccount: username
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public enum KeychainError: Error {
    case storeFailed(OSStatus)
    case notFound
}

// MARK: - StubRemoteFileService (replace with NMSSH in V2)

/// Stub that throws `.notImplemented` for all operations.
/// Replace this with an NMSSH-backed implementation.
public final class StubRemoteFileService: RemoteFileService {
    public private(set) var isConnected = false

    public init() {}

    public func connect(host: String, port: UInt16, username: String, password: String) async throws {
        throw RemoteFileError.notImplemented
    }
    public func connectWithKeychain(host: String, port: UInt16, username: String) async throws {
        let password = try KeychainCredentialStore.retrieve(host: host, username: username)
        try await connect(host: host, port: port, username: username, password: password)
    }
    public func listDirectory(path: String) async throws -> [RemoteFileEntry] {
        throw RemoteFileError.notImplemented
    }
    public func readFile(path: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        throw RemoteFileError.notImplemented
    }
    public func writeFile(data: Data, path: String) async throws {
        throw RemoteFileError.notImplemented
    }
    public func disconnect() { isConnected = false }
}

public enum RemoteFileError: Error, LocalizedError {
    case notImplemented
    case connectionFailed(String)
    case authenticationFailed
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented: return "SFTP not yet implemented (V2 feature)"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authenticationFailed: return "Authentication failed"
        case .fileNotFound(let path): return "File not found: \(path)"
        }
    }
}
