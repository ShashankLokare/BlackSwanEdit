// Sources/BlackSwanEditCore/ProjectService.swift
//
// Manages the project model: a named grouping of root paths persisted
// to .neditor/project.json inside the project's first root directory.

import Foundation

// MARK: - ProjectModel

public struct ProjectModel: Codable, Sendable {
    public var version: Int = 1
    public var name: String
    public var rootPaths: [String]
    public var excludeGlobs: [String]
    public var openFiles: [String]
    public var activeFile: String?
    public var encoding: String = "utf-8"
    public var lineEnding: String = "lf"
    public var searchFavorites: [SearchFavorite]

    public init(name: String, rootPaths: [String]) {
        self.name = name
        self.rootPaths = rootPaths
        excludeGlobs = ["*.o", ".build/**", "node_modules/**", ".git/**"]
        openFiles = []
        searchFavorites = []
    }

    public var rootURLs: [URL] { rootPaths.map { URL(fileURLWithPath: $0) } }
}

// MARK: - ProjectService protocol

public protocol ProjectService: AnyObject {
    var currentProject: ProjectModel? { get }
    func open(projectAt url: URL) throws
    func create(name: String, rootURL: URL) throws -> ProjectModel
    func save() throws
    func addFavorite(_ fav: SearchFavorite)
    func removeFavorite(id: UUID)
}

// MARK: - DefaultProjectService

public final class DefaultProjectService: ProjectService {
    public private(set) var currentProject: ProjectModel?
    private var projectFileURL: URL?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var saveWorkItem: DispatchWorkItem?

    public init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func open(projectAt url: URL) throws {
        let data = try Data(contentsOf: url)
        currentProject = try decoder.decode(ProjectModel.self, from: data)
        projectFileURL = url
    }

    public func create(name: String, rootURL: URL) throws -> ProjectModel {
        let model = ProjectModel(name: name, rootPaths: [rootURL.path])
        let dir = rootURL.appendingPathComponent(".neditor")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("project.json")
        let data = try encoder.encode(model)
        try data.write(to: file, options: .atomic)
        currentProject = model
        projectFileURL = file
        return model
    }

    public func save() throws {
        guard let project = currentProject, let url = projectFileURL else { return }
        let data = try encoder.encode(project)
        try data.write(to: url, options: .atomic)
    }

    /// Debounced save — coalesces rapid changes.
    public func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in try? self?.save() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
    }

    public func addFavorite(_ fav: SearchFavorite) {
        currentProject?.searchFavorites.append(fav)
        scheduleSave()
    }

    public func removeFavorite(id: UUID) {
        currentProject?.searchFavorites.removeAll { $0.id == id }
        scheduleSave()
    }
}
