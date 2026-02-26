import AppKit
import Foundation
import BlackSwanEditCore

@MainActor
final class DocumentPromptService {
    static let shared = DocumentPromptService()

    private init() {}

    enum CloseDecision {
        case closed
        case canceled
    }

    func closeDocumentWithPrompt(_ document: LocalDocumentBuffer) -> CloseDecision {
        guard document.isDirty else {
            DocumentStore.shared.close(document: document)
            return .closed
        }

        switch promptToSaveChanges(for: document, actionName: "close") {
        case .save:
            guard saveDocumentWithPanelsIfNeeded(document) else { return .canceled }
            DocumentStore.shared.close(document: document)
            return .closed
        case .dontSave:
            DocumentStore.shared.close(document: document)
            return .closed
        case .cancel:
            return .canceled
        }
    }

    func closeAllWithPrompt() -> CloseDecision {
        // Close active first, then the rest (stable order for the user).
        let store = DocumentStore.shared
        var docs = store.documents
        if let active = store.activeDocument, let idx = docs.firstIndex(where: { $0.id == active.id }) {
            docs.remove(at: idx)
            docs.insert(active, at: 0)
        }

        for doc in docs {
            if closeDocumentWithPrompt(doc) == .canceled {
                return .canceled
            }
        }
        return .closed
    }

    func saveDocumentWithPanelsIfNeeded(_ document: LocalDocumentBuffer) -> Bool {
        if let url = document.fileURL {
            do {
                try document.save(to: url)
                return true
            } catch {
                presentError("Save failed: \(error.localizedDescription)")
                return false
            }
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName(for: document)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            try document.save(to: url)
            return true
        } catch {
            presentError("Save failed: \(error.localizedDescription)")
            return false
        }
    }

    func saveAll() -> Bool {
        let store = DocumentStore.shared
        for doc in store.documents where doc.isDirty {
            guard saveDocumentWithPanelsIfNeeded(doc) else { return false }
        }
        return true
    }

    func confirmTerminateApplication() -> Bool {
        let store = DocumentStore.shared
        let dirty = store.documents.filter { $0.isDirty }
        guard !dirty.isEmpty else { return true }

        // Prompt sequentially so the user can choose per-file (UltraEdit-style).
        for doc in dirty {
            switch promptToSaveChanges(for: doc, actionName: "quit") {
            case .save:
                guard saveDocumentWithPanelsIfNeeded(doc) else { return false }
            case .dontSave:
                continue
            case .cancel:
                return false
            }
        }
        return true
    }

    // MARK: - Prompting

    private enum SavePromptResult {
        case save
        case dontSave
        case cancel
    }

    private func promptToSaveChanges(for document: LocalDocumentBuffer, actionName: String) -> SavePromptResult {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes you made?"
        alert.informativeText = "\(displayName(for: document)) has unsaved changes. If you don't save, your changes will be lost."

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .dontSave
        default: return .cancel
        }
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Error"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    private func displayName(for document: LocalDocumentBuffer) -> String {
        document.fileURL?.lastPathComponent ?? "Untitled"
    }

    private func suggestedName(for document: LocalDocumentBuffer) -> String {
        if let existing = document.fileURL?.lastPathComponent { return existing }
        return "Untitled.txt"
    }
}

