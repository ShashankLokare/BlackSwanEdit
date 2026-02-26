// Sources/BlackSwanEditCore/BufferSource.swift
//
// Abstraction over the two backing stores: an on-disk mmap region (large files)
// and an in-memory Data buffer (small files / the add-buffer).

import Foundation
import System

/// Backing storage for a Piece's source.
public enum BufferSource {
    case memory(Data)
    case mapped(MappedFile)

    public var length: UInt64 {
        switch self {
        case .memory(let d): return UInt64(d.count)
        case .mapped(let m): return m.length
        }
    }

    /// Copy bytes from this source into destination.
    public func copy(into dest: inout Data, from range: Range<UInt64>) {
        switch self {
        case .memory(let d):
            let slice = d[Int(range.lowerBound)..<Int(range.upperBound)]
            dest.append(contentsOf: slice)
        case .mapped(let m):
            m.copy(into: &dest, from: range)
        }
    }

    public func data(in range: Range<UInt64>) -> Data {
        var result = Data(capacity: Int(range.upperBound - range.lowerBound))
        copy(into: &result, from: range)
        return result
    }
    
    public func count(byte: UInt8, in range: Range<UInt64>) -> Int {
        switch self {
        case .memory(let d):
            var c = 0
            d.withUnsafeBytes { ptr in
                guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
                let start = Int(range.lowerBound)
                for i in 0..<Int(range.count) {
                    if base[start + i] == byte { c += 1 }
                }
            }
            return c
        case .mapped(let m):
            return m.count(byte: byte, in: range)
        }
    }
    
    public func offset(of byte: UInt8, occurrence: Int, in range: Range<UInt64>) -> UInt64? {
        switch self {
        case .memory(let d):
            var found = 0
            var result: UInt64? = nil
            d.withUnsafeBytes { ptr in
                guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
                let start = Int(range.lowerBound)
                for i in 0..<Int(range.count) {
                    if base[start + i] == byte {
                        found += 1
                        if found == occurrence {
                            result = UInt64(i)
                            break
                        }
                    }
                }
            }
            return result
        case .mapped(let m):
            return m.offset(of: byte, occurrence: occurrence, in: range)
        }
    }
}

// MARK: - MappedFile

/// A read-only memory-mapped file using POSIX mmap.
public final class MappedFile {
    private let pointer: UnsafeRawPointer
    public let length: UInt64

    public init(url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
        let size = UInt64(st.st_size)
        guard size > 0 else {
            // Empty file — use a dummy non-null pointer
            pointer = UnsafeRawPointer(bitPattern: 0x1)!
            length = 0
            return
        }

        let raw = mmap(nil, Int(size), PROT_READ, MAP_SHARED | MAP_NOCACHE, fd, 0)
        guard raw != MAP_FAILED else { throw POSIXError(.init(rawValue: errno)!) }
        pointer = UnsafeRawPointer(raw!)
        length = size
    }

    deinit {
        if length > 0 { munmap(UnsafeMutableRawPointer(mutating: pointer), Int(length)) }
    }

    public func copy(into dest: inout Data, from range: Range<UInt64>) {
        let start = pointer.advanced(by: Int(range.lowerBound))
        dest.append(start.assumingMemoryBound(to: UInt8.self), count: Int(range.upperBound - range.lowerBound))
    }
    
    public func count(byte: UInt8, in range: Range<UInt64>) -> Int {
        let ptr = pointer.advanced(by: Int(range.lowerBound)).assumingMemoryBound(to: UInt8.self)
        var c = 0
        for i in 0..<Int(range.count) {
            if ptr[i] == byte { c += 1 }
        }
        return c
    }
    
    public func offset(of byte: UInt8, occurrence: Int, in range: Range<UInt64>) -> UInt64? {
        let ptr = pointer.advanced(by: Int(range.lowerBound)).assumingMemoryBound(to: UInt8.self)
        var found = 0
        for i in 0..<Int(range.count) {
            if ptr[i] == byte {
                found += 1
                if found == occurrence { return UInt64(i) }
            }
        }
        return nil
    }
}
