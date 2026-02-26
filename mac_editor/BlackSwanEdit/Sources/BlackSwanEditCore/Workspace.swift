import Foundation
import Combine

/// A single node in the file tree (can be a file or a folder).
public struct FileNode: Identifiable, Hashable, Sendable {
    public let id: URL
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public var children: [FileNode]?

    public init(url: URL, isDirectory: Bool, children: [FileNode]? = nil) {
        self.id = url
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.children = children
    }
}

/// Manages a root directory, scanning files recursively into a tree structure.
@MainActor
public final class Workspace: ObservableObject {
    public static let shared = Workspace()
    
    @Published public private(set) var rootURL: URL?
    @Published public private(set) var rootNodes: [FileNode] = []
    
    // Config
    private let ignoredNames: Set<String> = [".git", ".DS_Store", "build", ".build", ".swiftpm"]
    
    private init() {}
    
    public func openFolder(at url: URL) {
        self.rootURL = url
        self.rootNodes = self.scanDirectory(url: url)
    }
    
    private func scanDirectory(url: URL) -> [FileNode] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        
        var nodes: [FileNode] = []
        for itemURL in items {
            let name = itemURL.lastPathComponent
            if name.hasPrefix(".") || ignoredNames.contains(name) {
                continue
            }
            
            let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir {
                let children = scanDirectory(url: itemURL)
                nodes.append(FileNode(url: itemURL, isDirectory: true, children: children.isEmpty ? nil : children))
            } else {
                nodes.append(FileNode(url: itemURL, isDirectory: false, children: nil))
            }
        }
        
        // Sort: folders first, then alphabetically
        nodes.sort { a, b in
            if a.isDirectory && !b.isDirectory { return true }
            if !a.isDirectory && b.isDirectory { return false }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        
        return nodes
    }
}
