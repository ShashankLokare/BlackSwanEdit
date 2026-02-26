import AppKit
import Combine
import Foundation
import BlackSwanEditCore

@MainActor
final class AutosaveService {
    static let shared = AutosaveService()

    private let ioQueue = DispatchQueue(label: "BlackSwanEdit.AutosaveIO", qos: .utility)
    private var cancellables: Set<AnyCancellable> = []
    private var docCancellables: [UUID: AnyCancellable] = [:]
    private var pendingWork: [UUID: DispatchWorkItem] = [:]

    private let maxAutosaveBytes: UInt64 = 50 * 1024 * 1024

    private init() {}

    func start() {
        observeDocuments()
        offerRecoveryIfNeeded()
    }

    private func observeDocuments() {
        DocumentStore.shared.$documents
            .sink { [weak self] docs in
                guard let self else { return }
                self.reconcile(documents: docs)
            }
            .store(in: &cancellables)
    }

    private func reconcile(documents: [LocalDocumentBuffer]) {
        let currentIDs = Set(documents.map(\.id))

        // Remove any observers for closed docs.
        for (id, c) in docCancellables where !currentIDs.contains(id) {
            c.cancel()
            docCancellables[id] = nil
            pendingWork[id]?.cancel()
            pendingWork[id] = nil
            removeAutosaveFiles(forDocumentID: id)
        }

        // Add observers for new docs.
        for doc in documents where docCancellables[doc.id] == nil {
            docCancellables[doc.id] = doc.$isDirty
                .removeDuplicates()
                .sink { [weak self, weak doc] isDirty in
                    guard let self, let doc else { return }
                    if isDirty {
                        self.scheduleAutosave(for: doc)
                    } else {
                        self.pendingWork[doc.id]?.cancel()
                        self.pendingWork[doc.id] = nil
                        self.removeAutosaveFiles(forDocumentID: doc.id)
                    }
                }
        }
    }

    private func scheduleAutosave(for document: LocalDocumentBuffer) {
        guard document.buffer.byteLength <= maxAutosaveBytes else { return }

        pendingWork[document.id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak document] in
            guard let self, let document else { return }
            self.writeAutosaveSnapshot(document: document)
        }
        pendingWork[document.id] = work
        ioQueue.asyncAfter(deadline: .now() + 1.25, execute: work)
    }

    private func writeAutosaveSnapshot(document: LocalDocumentBuffer) {
        let (contentURL, metaURL) = autosaveURLs(forDocumentID: document.id)
        let buffer = document.buffer
        let startGen = buffer.generation
        let total = buffer.byteLength
        let bytes = buffer.bytes(in: 0..<total)

        let meta = AutosaveMeta(
            documentID: document.id.uuidString,
            originalPath: document.fileURL?.path,
            timestamp: Date().timeIntervalSince1970
        )

        // Write on the IO queue; buffer reads are on MainActor.
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: contentURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                try bytes.write(to: contentURL, options: [.atomic])
                let metaData = try JSONEncoder().encode(meta)
                try metaData.write(to: metaURL, options: [.atomic])
            } catch {
                // Best-effort; autosave is non-fatal.
            }
        }

        // If content changed during write, schedule another autosave soon.
        if buffer.generation != startGen {
            Task { @MainActor in
                self.scheduleAutosave(for: document)
            }
        }
    }

    // MARK: - Recovery

    private func offerRecoveryIfNeeded() {
        let autosaves = listAutosaves()
        guard !autosaves.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Recovered Documents"
        alert.informativeText = "Found \(autosaves.count) recovered document(s) from a previous session. Do you want to open them?"
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Discard")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            for file in autosaves {
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    let doc = DocumentStore.shared.newDocument(text: text)
                    doc.markDirty()
                }
                // Keep autosave until user saves/closes, so recovery survives restarts.
            }
        } else {
            discardAllAutosaves()
        }
    }

    // MARK: - Paths

    private struct AutosaveMeta: Codable {
        var documentID: String
        var originalPath: String?
        var timestamp: TimeInterval
    }

    private func autosaveDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("BlackSwanEdit", isDirectory: true)
            .appendingPathComponent("Autosave", isDirectory: true)
    }

    private func autosaveURLs(forDocumentID id: UUID) -> (content: URL, meta: URL) {
        let dir = autosaveDir()
        let baseName = id.uuidString
        return (
            dir.appendingPathComponent("\(baseName).autosave", isDirectory: false),
            dir.appendingPathComponent("\(baseName).json", isDirectory: false)
        )
    }

    private func removeAutosaveFiles(forDocumentID id: UUID) {
        let urls = autosaveURLs(forDocumentID: id)
        try? FileManager.default.removeItem(at: urls.content)
        try? FileManager.default.removeItem(at: urls.meta)
    }

    private func listAutosaves() -> [URL] {
        let dir = autosaveDir()
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "autosave" }
    }

    private func discardAllAutosaves() {
        for file in listAutosaves() {
            try? FileManager.default.removeItem(at: file)
            let meta = file.deletingPathExtension().appendingPathExtension("json")
            try? FileManager.default.removeItem(at: meta)
        }
    }
}
