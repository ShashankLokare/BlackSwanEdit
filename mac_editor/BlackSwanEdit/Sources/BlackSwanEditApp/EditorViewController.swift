import SwiftUI
import AppKit
import BlackSwanEditCore

/// Wraps our AppKit-based highly optimized `EditorViewController` so it can live inside SwiftUI.
struct EditorViewControllerWrapper: NSViewControllerRepresentable {
    var activeDocument: LocalDocumentBuffer?
    
    func makeNSViewController(context: Context) -> EditorViewController {
        let vc = EditorViewController()
        if let doc = activeDocument {
            vc.bind(to: doc)
        }
        return vc
    }
    
    func updateNSViewController(_ nsViewController: EditorViewController, context: Context) {
        if let doc = activeDocument {
            if nsViewController.document?.id != doc.id {
                nsViewController.bind(to: doc)
            } else {
                nsViewController.applyPendingSelectionIfAny()
                nsViewController.refreshLanguageForCurrentDocument()
            }
        }
    }
}

/// The core AppKit view controller driving our custom text stack.
class EditorViewController: NSViewController {
    private enum SearchMode {
        case currentFile
        case files
    }
    
    var document: LocalDocumentBuffer?
    
    private let scrollView = NSScrollView()
    private let textView = EditorTextView()
    private let gutterView = GutterView()
    
    private let searchPanel = SearchPanelViewController()
    private let searchService = DefaultSearchService()
    private let languageService = DefaultLanguageService()
    
    private var currentMatches: [SearchMatch] = []
    private var currentMatchIndex: Int = -1
    private var notificationObservers: [NSObjectProtocol] = []
    private var searchMode: SearchMode = .currentFile
    private var findInFilesTask: Task<Void, Never>?

    private var activeLanguageName: String?
    
    override func loadView() {
        self.view = NSView()
        self.view.wantsLayer = true
        self.view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        
        setupHierarchy()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if document != nil {
            view.window?.makeFirstResponder(textView)
        }
    }
    
    private func setupHierarchy() {
        // Setup ScrollView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        
        gutterView.translatesAutoresizingMaskIntoConstraints = false
        searchPanel.view.translatesAutoresizingMaskIntoConstraints = false
        
        addChild(searchPanel)
        view.addSubview(gutterView)
        view.addSubview(scrollView)
        view.addSubview(searchPanel.view)
        
        NSLayoutConstraint.activate([
            gutterView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gutterView.topAnchor.constraint(equalTo: view.topAnchor),
            gutterView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            gutterView.widthAnchor.constraint(equalToConstant: 45),
            
            scrollView.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            searchPanel.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            searchPanel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            searchPanel.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
        ])
        
        searchPanel.delegate = self
        searchPanel.view.isHidden = true
        registerToolbarObservers()
        
        // Link gutter scrolling to scroll view
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            self?.gutterView.needsDisplay = true
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
    }
    
    func bind(to document: LocalDocumentBuffer) {
        self.document = document
        // Pass model to the custom views...
        textView.document = document
        gutterView.buffer = document.buffer
        restoreSelection(for: document)
        textView.searchMatches = []
        searchPanel.view.isHidden = true

        if let pending = SearchResultsStore.shared.consumePendingSelection(for: document.fileURL) {
            let start = textPosition(for: pending.byteRange.lowerBound, in: document.buffer)
            let end = textPosition(for: pending.byteRange.upperBound, in: document.buffer)
            textView.selection = .linear(LinearSelection(anchor: start, active: end))
            DispatchQueue.main.async { [weak self] in
                self?.textView.scrollSelectionToVisible()
            }
        }

        refreshLanguageForCurrentDocument()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.textView)
        }
    }

    func applyPendingSelectionIfAny() {
        guard let document else { return }
        guard let pending = SearchResultsStore.shared.consumePendingSelection(for: document.fileURL) else { return }
        let start = textPosition(for: pending.byteRange.lowerBound, in: document.buffer)
        let end = textPosition(for: pending.byteRange.upperBound, in: document.buffer)
        textView.selection = .linear(LinearSelection(anchor: start, active: end))
        textView.scrollSelectionToVisible()
    }

    private func restoreSelection(for document: LocalDocumentBuffer) {
        let maxLine = max(0, document.buffer.lineCount - 1)
        let line = min(max(0, document.cursorLine), maxLine)
        let lineRange = document.buffer.byteRange(forLine: line) ?? 0..<document.buffer.byteLength
        let lineData = document.buffer.bytes(in: lineRange)
        let lineStr = String(data: lineData, encoding: .utf8) ?? ""
        let maxColumn = lineStr.utf16.count
        let column = min(max(0, document.cursorColumn), maxColumn)
        textView.selection = .linear(LinearSelection(caret: TextPosition(line: line, column: column)))
    }

    func refreshLanguageForCurrentDocument() {
        guard let document = document else { return }

        let nextLanguage = resolvedLanguage(for: document)
        guard activeLanguageName != nextLanguage?.name else { return }

        activeLanguageName = nextLanguage?.name
        if let nextLanguage {
            textView.setLanguage(nextLanguage, service: languageService)
        }
    }

    private func resolvedLanguage(for document: LocalDocumentBuffer) -> LanguageDef? {
        if let override = document.languageOverride,
           let overrideLanguage = languageService.languages.first(where: { $0.name == override }) {
            return overrideLanguage
        }

        let prefix = document.buffer.bytes(in: 0..<min(document.buffer.byteLength, 128))
        if let fileURL = document.fileURL,
           let detected = languageService.detect(for: fileURL, contentPrefix: prefix) {
            return detected
        }

        if let plain = languageService.languages.first(where: { $0.name == "Plain Text" }) {
            return plain
        }
        return languageService.languages.first(where: { $0.name == "Swift" })
    }
    
    // MARK: - AppKit Event Overrides
    
    @IBAction @objc func performFindPanelAction(_ sender: Any?) {
        searchMode = .currentFile
        searchPanel.setReplaceMode(false)
        searchPanel.setStatus("Searching current file")
        searchPanel.view.isHidden = false
        searchPanel.focusField()
    }

    @IBAction @objc func performFindInFilesAction(_ sender: Any?) {
        searchMode = .files
        searchPanel.setReplaceMode(false)
        searchPanel.setStatus("Searching workspace files")
        searchPanel.view.isHidden = false
        searchPanel.focusField()
        EditorUIState.shared.sidebarVisible = true
        EditorUIState.shared.searchResultsVisible = true
        EditorUIState.shared.sourceControlVisible = false
    }

    @IBAction @objc func performShowReplaceAction(_ sender: Any?) {
        searchMode = .currentFile
        searchPanel.setReplaceMode(true)
        searchPanel.setStatus("Replace in current file")
        searchPanel.view.isHidden = false
        searchPanel.focusReplaceField()
    }

    @IBAction @objc func performFindNextAction(_ sender: Any?) {
        if searchPanel.view.isHidden {
            performFindPanelAction(sender)
            return
        }
        searchPanelDidRequestNext(searchPanel)
    }

    @IBAction @objc func performFindPreviousAction(_ sender: Any?) {
        if searchPanel.view.isHidden {
            performFindPanelAction(sender)
            return
        }
        searchPanelDidRequestPrevious(searchPanel)
    }

    deinit {
        findInFilesTask?.cancel()
        for token in notificationObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func registerToolbarObservers() {
        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(forName: .editorShowFind, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.performFindPanelAction(nil)
            }
        )
        notificationObservers.append(
            center.addObserver(forName: .editorShowFindInFiles, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.performFindInFilesAction(nil)
            }
        )
        notificationObservers.append(
            center.addObserver(forName: .editorShowReplace, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.performShowReplaceAction(nil)
            }
        )
    }
}

// MARK: - SearchPanelDelegate
extension EditorViewController: SearchPanelDelegate {
    func searchPanelDidUpdateQuery(_ panel: SearchPanelViewController, pattern: String, options: SearchOptions) {
        if searchMode == .files {
            runFindInFiles(pattern: pattern, options: options)
            return
        }

        guard let doc = document, !pattern.isEmpty else {
            findInFilesTask?.cancel()
            self.currentMatches = []
            self.currentMatchIndex = -1
            self.textView.searchMatches = []
            panel.setStatus("Type to search current file")
            return
        }

        Task {
            do {
                let matches = try await searchService.findAll(pattern: pattern, options: options, in: doc.buffer)
                await MainActor.run {
                    self.currentMatches = matches
                    self.currentMatchIndex = matches.isEmpty ? -1 : 0
                    self.textView.searchMatches = matches
                    panel.setStatus("\(matches.count) matches in current file")
                    if !matches.isEmpty {
                        self.selectCurrentMatch()
                    }
                }
            } catch {
                await MainActor.run {
                    panel.setStatus("Search failed")
                }
            }
        }
    }
    
    func searchPanelDidRequestNext(_ panel: SearchPanelViewController) {
        guard !currentMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % currentMatches.count
        selectCurrentMatch()
    }

    func searchPanelDidRequestPrevious(_ panel: SearchPanelViewController) {
        guard !currentMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + currentMatches.count) % currentMatches.count
        selectCurrentMatch()
    }
    
    func searchPanelDidRequestReplace(_ panel: SearchPanelViewController, with template: String) {
        guard let doc = document, !currentMatches.isEmpty else { return }
        let safeIndex = max(0, min(currentMatchIndex, currentMatches.count - 1))
        let target = currentMatches[safeIndex]
        Task {
            _ = try await searchService.replaceAll(matches: [target], template: template, in: doc.buffer)
            await MainActor.run {
                searchPanelDidUpdateQuery(panel, pattern: panel.currentPattern, options: panel.currentOptions)
            }
        }
    }
    
    func searchPanelDidRequestReplaceAll(_ panel: SearchPanelViewController, with template: String) {
        guard let doc = document, !currentMatches.isEmpty else { return }
        Task {
            _ = try await searchService.replaceAll(matches: currentMatches, template: template, in: doc.buffer)
            await MainActor.run {
                self.currentMatches = []
                self.currentMatchIndex = -1
                self.textView.searchMatches = []
            }
        }
    }
    
    func searchPanelDidClose(_ panel: SearchPanelViewController) {
        findInFilesTask?.cancel()
        panel.view.isHidden = true
        panel.setStatus("")
        currentMatchIndex = -1
        textView.searchMatches = []
        textView.window?.makeFirstResponder(textView)
    }

    private func selectCurrentMatch() {
        guard let doc = document else { return }
        guard currentMatchIndex >= 0 && currentMatchIndex < currentMatches.count else { return }

        let match = currentMatches[currentMatchIndex]
        let start = textPosition(for: match.byteRange.lowerBound, in: doc.buffer)
        let end = textPosition(for: match.byteRange.upperBound, in: doc.buffer)
        textView.selection = .linear(LinearSelection(anchor: start, active: end))
        textView.scrollSelectionToVisible()
    }

    private func textPosition(for offset: UInt64, in buffer: PieceChainBuffer) -> TextPosition {
        let clampedOffset = min(offset, buffer.byteLength)
        let line = buffer.line(containing: clampedOffset)
        guard let range = buffer.byteRange(forLine: line) else {
            return TextPosition(line: line, column: 0)
        }

        let end = min(clampedOffset, range.upperBound)
        let prefixData = buffer.bytes(in: range.lowerBound..<end)
        let prefixStr = String(data: prefixData, encoding: .utf8) ?? ""
        return TextPosition(line: line, column: prefixStr.utf16.count)
    }

    private func runFindInFiles(pattern: String, options: SearchOptions) {
        findInFilesTask?.cancel()

        guard !pattern.isEmpty else {
            currentMatches = []
            currentMatchIndex = -1
            textView.searchMatches = []
            searchPanel.setStatus("Type to search workspace files")
            SearchResultsStore.shared.finishSearch(statusText: "Type to search workspace files")
            return
        }

        guard let rootURL = Workspace.shared.rootURL else {
            currentMatches = []
            currentMatchIndex = -1
            textView.searchMatches = []
            searchPanel.setStatus("Open a folder to use Find in Files")
            SearchResultsStore.shared.failSearch("Open a folder to use Find in Files")
            return
        }

        searchPanel.setStatus("Searching \(rootURL.lastPathComponent)...")
        SearchResultsStore.shared.resetForNewSearch(query: pattern)
        EditorUIState.shared.sidebarVisible = true
        EditorUIState.shared.searchResultsVisible = true
        EditorUIState.shared.sourceControlVisible = false

        findInFilesTask = Task { [weak self] in
            guard let self else { return }

            var fileCount = 0
            var totalMatches = 0

            do {
                let stream = self.searchService.findInFiles(
                    pattern: pattern,
                    options: options,
                    in: [rootURL],
                    excluding: []
                )

                for try await result in stream {
                    if Task.isCancelled { return }
                    fileCount += 1
                    totalMatches += result.matches.count
                    await MainActor.run {
                        SearchResultsStore.shared.appendFileResult(result)
                        SearchResultsStore.shared.statusText = "\(totalMatches) matches in \(fileCount) files"
                    }
                    if fileCount >= 200 {
                        break
                    }
                }

                await MainActor.run {
                    guard self.searchMode == .files else { return }

                    if SearchResultsStore.shared.fileResults.isEmpty {
                        self.currentMatches = []
                        self.currentMatchIndex = -1
                        self.textView.searchMatches = []
                        self.searchPanel.setStatus("No matches in \(rootURL.lastPathComponent)")
                        SearchResultsStore.shared.finishSearch(statusText: "No matches in \(rootURL.lastPathComponent)")
                        return
                    }

                    self.searchPanel.setStatus("\(totalMatches) matches in \(fileCount) files")
                    SearchResultsStore.shared.finishSearch(statusText: "\(totalMatches) matches in \(fileCount) files")
                }
            } catch {
                await MainActor.run {
                    self.searchPanel.setStatus("Find in files failed")
                    SearchResultsStore.shared.failSearch("Find in files failed")
                }
            }
        }
    }
}
