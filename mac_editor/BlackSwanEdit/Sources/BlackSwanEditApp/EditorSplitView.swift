import SwiftUI
import BlackSwanEditCore

struct EditorSplitView: View {
    @ObservedObject var workspace = Workspace.shared
    @ObservedObject var documentStore = DocumentStore.shared
    @ObservedObject var uiState = EditorUIState.shared
    
    var body: some View {
        HStack(spacing: 0) {
            if uiState.sidebarVisible {
                Group {
                    if uiState.searchResultsVisible {
                        SearchResultsSidebarView()
                    } else if uiState.sourceControlVisible {
                        SourceControlSidebarView()
                    } else {
                        SidebarView(workspace: workspace, documentStore: documentStore)
                    }
                }
                .frame(width: 250)
                Divider()
            }
            
            VStack(spacing: 0) {
                // Tab Bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 1) {
                        ForEach(documentStore.documents, id: \.id) { doc in
                            let isActive = (doc.id == documentStore.activeDocument?.id)
                            HStack {
                                Text(doc.fileURL?.lastPathComponent ?? "Untitled")
                                    .font(.system(size: 13, weight: isActive ? .bold : .regular))
                                    .foregroundColor(isActive ? .primary : .secondary)
                                if doc.isDirty {
                                    Circle()
                                        .fill(Color.blue)
                                        .frame(width: 6, height: 6)
                                }
                                Button(action: {
                                    _ = DocumentPromptService.shared.closeDocumentWithPrompt(doc)
                                }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(PlainButtonStyle())
                                .padding(.leading, 4)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(isActive ? Color(NSColor.controlBackgroundColor) : Color(NSColor.windowBackgroundColor))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                documentStore.activeDocument = doc
                            }
                        }
                    }
                }
                .background(Color(NSColor.windowBackgroundColor))
                Divider()
                
                HStack(spacing: 0) {
                    // Editor Area
                    if let doc = documentStore.activeDocument {
                        DocumentDetailView(document: doc)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("No Document Selected")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    
                    if uiState.minimapVisible {
                        Divider()
                        MinimapPlaceholderView()
                    }
                }
                
                if uiState.terminalVisible {
                    Divider()
                    TerminalPlaceholderView()
                }
                
                // Status Bar
                if let doc = documentStore.activeDocument {
                    Divider()
                    HStack(spacing: 12) {
                        Text("Line: \(doc.cursorLine + 1), Col: \(doc.cursorColumn + 1), Char: \(doc.cursorByteOffset)")
                        Spacer()
                        if doc.isLargeFileMode {
                            Text("Large File Mode")
                                .foregroundColor(.orange)
                        }
                        
                        let charset = (doc.encoding == .utf8) ? "UTF-8" : doc.encoding.description
                        Text(charset)
                        
                        let endingStr = (doc.lineEnding == .lf) ? "LF" : ((doc.lineEnding == .crlf) ? "CRLF" : "CR")
                        Text(endingStr)
                        
                        Text(formatBytes(doc.buffer.byteLength))
                    }
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.windowBackgroundColor))
                }
            }
        }
        .background(WindowAccessor(callback: { window in
            EditorWindowController.attach(to: window)
        }))
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(Int(b)) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        return String(format: "%.1f MB", b / (1024 * 1024))
    }
}

struct MinimapPlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Minimap")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)
            
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .frame(width: 120)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct TerminalPlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Integrated terminal panel is visible.")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 140, alignment: .topLeading)
        .background(Color(NSColor.textBackgroundColor))
    }
}

struct SourceControlSidebarView: View {
    @ObservedObject private var workspace = Workspace.shared
    @State private var statuses: [GitFileStatus] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    private let gitService = DefaultGitService()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SOURCE CONTROL")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Refresh") { refreshStatus() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if statuses.isEmpty {
                Text("No changes")
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(statuses, id: \.fileURL) { status in
                    HStack(spacing: 8) {
                        Text(symbol(for: status.state))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(color(for: status.state))
                        Text(status.fileURL.lastPathComponent)
                            .lineLimit(1)
                    }
                    .font(.system(size: 12))
                }
                .listStyle(.sidebar)
            }
        }
        .task(id: workspace.rootURL) {
            refreshStatus()
        }
    }

    private func refreshStatus() {
        guard let workspaceRoot = workspace.rootURL else {
            statuses = []
            errorMessage = "Open a folder to view source control."
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            if let repoRoot = await gitService.repoRoot(for: workspaceRoot) {
                do {
                    let result = try await gitService.status(repoRoot: repoRoot)
                    let sorted = result.sorted { $0.fileURL.path < $1.fileURL.path }
                    await MainActor.run {
                        statuses = sorted
                        isLoading = false
                        errorMessage = nil
                    }
                } catch {
                    await MainActor.run {
                        statuses = []
                        isLoading = false
                        errorMessage = "Failed to load git status."
                    }
                }
            } else {
                await MainActor.run {
                    statuses = []
                    isLoading = false
                    errorMessage = "Current folder is not a Git repository."
                }
            }
        }
    }

    private func symbol(for state: GitFileStatus.State) -> String {
        switch state {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "?"
        case .ignored: return "!"
        case .conflicted: return "U"
        }
    }

    private func color(for state: GitFileStatus.State) -> Color {
        switch state {
        case .modified: return .orange
        case .added: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .untracked: return .yellow
        case .ignored: return .secondary
        case .conflicted: return .pink
        }
    }
}

struct SearchResultsSidebarView: View {
    @ObservedObject private var results = SearchResultsStore.shared
    @ObservedObject private var documentStore = DocumentStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SEARCH")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if results.isSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if results.query.isEmpty {
                    Text("Use toolbar Find in Files, then type.")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                } else {
                    Text(results.query)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(summaryText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if results.fileResults.isEmpty {
                Text(results.statusText.isEmpty ? "No results yet." : results.statusText)
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List {
                    ForEach(results.fileResults.indices, id: \.self) { i in
                        let r = results.fileResults[i]
                        Section {
                            ForEach(r.matches.indices, id: \.self) { j in
                                let m = r.matches[j]
                                Button {
                                    openAndSelect(fileURL: r.fileURL, match: m)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text("L\(m.lineRange.lowerBound + 1)")
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundColor(.secondary)
                                        Text(r.fileURL.lastPathComponent)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                Text(r.fileURL.lastPathComponent)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(r.matches.count)")
                                    .foregroundColor(.secondary)
                            }
                            .font(.system(size: 11, weight: .semibold))
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var summaryText: String {
        let files = results.fileResults.count
        let total = results.fileResults.reduce(0) { $0 + $1.matches.count }
        if results.isSearching {
            return "\(total) matches in \(files) files (searching)"
        }
        return results.statusText.isEmpty ? "\(total) matches in \(files) files" : results.statusText
    }

    private func openAndSelect(fileURL: URL, match: SearchMatch) {
        do {
            SearchResultsStore.shared.setPendingSelection(fileURL: fileURL, byteRange: match.byteRange)
            _ = try documentStore.open(url: fileURL)
        } catch {
            // Status text will show in the panel.
            SearchResultsStore.shared.failSearch("Failed opening \(fileURL.lastPathComponent)")
        }
    }
}

struct DocumentDetailView: View {
    @ObservedObject var document: LocalDocumentBuffer
    
    var body: some View {
        Group {
            if document.isHexMode {
                HexViewControllerWrapper(activeDocument: document)
            } else {
                EditorViewControllerWrapper(activeDocument: document)
            }
        }
    }
}

struct SidebarView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var documentStore: DocumentStore
    
    var body: some View {
        List {
            if let root = workspace.rootURL {
                Section(root.lastPathComponent.uppercased()) {
                    OutlineGroup(workspace.rootNodes, children: \.children) { node in
                        HStack {
                            Image(systemName: node.isDirectory ? "folder" : "doc.text")
                                .foregroundColor(node.isDirectory ? .blue : .primary)
                            Text(node.name)
                            
                            if !node.isDirectory, let doc = documentStore.documents.first(where: { $0.fileURL == node.url }) {
                                if doc.isDirty {
                                    Spacer()
                                    Circle()
                                        .fill(Color.blue)
                                        .frame(width: 8, height: 8)
                                }
                            }
                        }
                        .contentShape(Rectangle()) // Make full row tappable
                        .onTapGesture {
                            if !node.isDirectory {
                                do {
                                    _ = try documentStore.open(url: node.url)
                                    AppLogger.shared.log("Opened file from sidebar: \(node.url.lastPathComponent)")
                                } catch {
                                    AppLogger.shared.log("Failed to open file: \(error)", level: "ERROR")
                                }
                            }
                        }
                    }
                }
            } else {
                Text("No Folder Opened")
                    .foregroundColor(.secondary)
                    .padding()
            }
        }
        .listStyle(.sidebar)
    }
}
