import SwiftUI
import AppKit
import BlackSwanEditCore

@main
struct BlackSwanEditApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            EditorSplitView()
                .frame(minWidth: 800, minHeight: 600)
        }
        
        // Preview windows should behave like normal macOS windows (movable, resizable, maximizable).
        WindowGroup("Mermaid Preview", id: "mermaidPreview") {
            MermaidPreviewSheet()
        }
        
        WindowGroup("JSX Preview", id: "jsxPreview") {
            JSXPreviewSheet()
        }
        .commands {
            SidebarCommands()
            FileMenuCommands()
            EditMenuCommands()
            LanguageMenuCommands()
            ViewMenuCommands()
            CommandMenu("Macro") {
                MacroMenuItems()
            }
            CommandMenu("Transform") {
                TransformMenuItems()
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.shared.log("Application Did Finish Launching")
        AutosaveService.shared.start()
    }
    
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        Task { @MainActor in
            do {
                _ = try globalDocumentStore.open(url: url)
                AppLogger.shared.log("System opened file: \(url.lastPathComponent)")
            } catch {
                AppLogger.shared.log("System file open failed: \(error)", level: "ERROR")
            }
        }
        return true
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if DocumentPromptService.shared.confirmTerminateApplication() {
            return .terminateNow
        }
        return .terminateCancel
    }
}

// Global accessor for testing/UI bindings
@MainActor
let globalDocumentStore = BlackSwanEditCore.DocumentStore.shared
let globalLanguageService = DefaultLanguageService()

struct FileMenuCommands: Commands {
    @ObservedObject private var documentStore = DocumentStore.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New File") { newFile() }
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Open...") { openFile() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open Folder...") { openFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { saveActiveDocument() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(documentStore.activeDocument == nil)

            Button("Save As...") { saveActiveDocumentAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(documentStore.activeDocument == nil)

            Button("Save All") { saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(documentStore.documents.isEmpty)
        }

        CommandGroup(after: .saveItem) {
            Divider()
            Button("Close File") { closeActiveDocument() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(documentStore.activeDocument == nil)

            Button("Close All") { closeAll() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(documentStore.documents.isEmpty)
        }
    }

    private func newFile() {
        _ = documentStore.newDocument()
        AppLogger.shared.log("Created new untitled document")
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try documentStore.open(url: url)
            AppLogger.shared.log("Opened file from File menu: \(url.lastPathComponent)")
        } catch {
            AppLogger.shared.log("File menu open failed: \(error)", level: "ERROR")
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Workspace.shared.openFolder(at: url)
        AppLogger.shared.log("Opened folder from File menu: \(url.lastPathComponent)")
    }

    private func saveActiveDocument() {
        guard let doc = documentStore.activeDocument else { return }
        _ = DocumentPromptService.shared.saveDocumentWithPanelsIfNeeded(doc)
    }

    private func saveActiveDocumentAs() {
        guard let doc = documentStore.activeDocument else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.fileURL?.lastPathComponent ?? "Untitled.txt"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try doc.save(to: url)
            AppLogger.shared.log("Saved document as: \(url.lastPathComponent)")
        } catch {
            AppLogger.shared.log("File menu Save As failed: \(error)", level: "ERROR")
        }
    }

    private func closeActiveDocument() {
        guard let doc = documentStore.activeDocument else { return }
        _ = DocumentPromptService.shared.closeDocumentWithPrompt(doc)
    }

    private func closeAll() {
        _ = DocumentPromptService.shared.closeAllWithPrompt()
    }

    private func saveAll() {
        _ = DocumentPromptService.shared.saveAll()
    }
}

struct MacroMenuItems: View {
    @ObservedObject var engine = MacroEngine.shared
    
    var body: some View {
        Button(engine.isRecording ? "Stop Recording" : "Start Recording") {
            if engine.isRecording {
                _ = engine.stopRecording(name: "Macro \(engine.savedMacros.count + 1)")
            } else {
                engine.startRecording()
            }
        }
        .keyboardShortcut("r", modifiers: [.command, .option])
        
        Divider()
        
        ForEach(engine.savedMacros, id: \.id) { macro in
            Button("Play \(macro.name)") {
                if let responder = NSApp.keyWindow?.firstResponder as? EditorActionPerformer {
                    engine.play(macro, on: responder)
                }
            }
        }
    }
}

struct LanguageMenuCommands: Commands {
    @ObservedObject private var documentStore = DocumentStore.shared

    private var sortedLanguages: [LanguageDef] {
        globalLanguageService.languages.sorted { $0.name < $1.name }
    }

    var body: some Commands {
        CommandMenu("Language") {
            Button(selectedLanguageName == nil ? "✓ Auto Detect" : "Auto Detect") {
                setLanguageOverride(nil)
            }
            .disabled(documentStore.activeDocument == nil)

            Divider()

            ForEach(sortedLanguages, id: \.name) { lang in
                Button(selectedLanguageName == lang.name ? "✓ \(lang.name)" : lang.name) {
                    setLanguageOverride(lang.name)
                }
                .disabled(documentStore.activeDocument == nil)
            }
        }
    }

    private var selectedLanguageName: String? {
        documentStore.activeDocument?.languageOverride
    }

    private func setLanguageOverride(_ name: String?) {
        guard let doc = documentStore.activeDocument else { return }
        doc.languageOverride = name
        if let name {
            AppLogger.shared.log("Language override set to \(name)")
        } else {
            AppLogger.shared.log("Language override reset to auto-detect")
        }
    }
}

struct TransformMenuItems: View {
    @ObservedObject private var documentStore = DocumentStore.shared
    let engine = TransformEngine()
    
    var body: some View {
        Button("To Uppercase") { apply(.uppercase) }
            .disabled(documentStore.activeDocument == nil)
        Button("To Lowercase") { apply(.lowercase) }
            .disabled(documentStore.activeDocument == nil)
        Button("Trim Whitespace") { apply(.trimTrailingWhitespace) }
            .disabled(documentStore.activeDocument == nil)
        Divider()
        Button("Sort Lines Ascending") { apply(.sortLines) }
            .disabled(documentStore.activeDocument == nil)
        Divider()
        Button("Format Document") { formatActiveDocument() }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(documentStore.activeDocument == nil)
    }
    
    private func apply(_ type: TransformType) {
        guard let doc = globalDocumentStore.activeDocument else { return }
        Task {
            do {
                try await engine.apply(transform: type, to: doc.buffer)
                await MainActor.run {
                    doc.markDirty()
                    AppLogger.shared.log("Transform Menu Applied")
                }
            } catch {
                AppLogger.shared.log("Transform Menu failed: \(error)", level: "ERROR")
            }
        }
    }

    private func formatActiveDocument() {
        guard let doc = documentStore.activeDocument else { return }
        Task {
            do {
                try await DocumentFormattingService.shared.format(document: doc)
                AppLogger.shared.log("Formatted document from menu")
            } catch {
                AppLogger.shared.log("Format failed: \(error.localizedDescription)", level: "ERROR")
            }
        }
    }
}

struct EditMenuCommands: Commands {
    @ObservedObject private var documentStore = DocumentStore.shared

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { sendAction("undo:") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(documentStore.activeDocument == nil)
            Button("Redo") { sendAction("redo:") }
                .keyboardShortcut("Z", modifiers: [.command, .shift])
                .disabled(documentStore.activeDocument == nil)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { sendAction("cut:") }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(documentStore.activeDocument == nil)
            Button("Copy") { sendAction("copy:") }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(documentStore.activeDocument == nil)
            Button("Paste") { sendAction("paste:") }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(documentStore.activeDocument == nil)
        }

        CommandGroup(replacing: .textEditing) {
            Button("Select All") { sendAction("selectAll:") }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(documentStore.activeDocument == nil)

            Divider()

            Button("Find...") { sendAction(#selector(EditorViewController.performFindPanelAction(_:))) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(documentStore.activeDocument == nil)
            Button("Find Next") { sendAction(#selector(EditorViewController.performFindNextAction(_:))) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(documentStore.activeDocument == nil)
            Button("Find Previous") { sendAction(#selector(EditorViewController.performFindPreviousAction(_:))) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(documentStore.activeDocument == nil)

            Divider()

            Button("Replace...") { sendAction(#selector(EditorViewController.performShowReplaceAction(_:))) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(documentStore.activeDocument == nil)

            Divider()

            Button("Find in Files...") { sendAction(#selector(EditorViewController.performFindInFilesAction(_:))) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }

    private func sendAction(_ selectorName: String) {
        _ = NSApp.sendAction(Selector(selectorName), to: nil, from: nil)
    }

    private func sendAction(_ sel: Selector) {
        _ = NSApp.sendAction(sel, to: nil, from: nil)
    }
}

struct ViewMenuCommands: Commands {
    @ObservedObject private var documentStore = DocumentStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("View") {
            Button("Mermaid Preview") {
                openWindow(id: "mermaidPreview")
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(documentStore.activeDocument == nil)

            Button("JSX Preview") {
                openWindow(id: "jsxPreview")
            }
            .keyboardShortcut("j", modifiers: [.command, .option])
            .disabled(documentStore.activeDocument == nil)
        }
    }
}
