import Foundation
import BlackSwanEditCore

@MainActor
final class SearchResultsStore: ObservableObject {
    static let shared = SearchResultsStore()

    struct PendingSelection: Equatable {
        var fileURL: URL
        var byteRange: Range<UInt64>
    }

    @Published var query: String = ""
    @Published var isSearching: Bool = false
    @Published var fileResults: [FileSearchResult] = []
    @Published var statusText: String = ""
    @Published var lastErrorText: String?

    private var pendingSelection: PendingSelection?

    private init() {}

    func resetForNewSearch(query: String) {
        self.query = query
        self.isSearching = true
        self.fileResults = []
        self.statusText = "Searching..."
        self.lastErrorText = nil
    }

    func finishSearch(statusText: String) {
        self.isSearching = false
        self.statusText = statusText
    }

    func failSearch(_ errorText: String) {
        self.isSearching = false
        self.lastErrorText = errorText
        self.statusText = errorText
    }

    func appendFileResult(_ result: FileSearchResult) {
        fileResults.append(result)
    }

    func setPendingSelection(fileURL: URL, byteRange: Range<UInt64>) {
        pendingSelection = PendingSelection(fileURL: fileURL, byteRange: byteRange)
    }

    func consumePendingSelection(for fileURL: URL?) -> PendingSelection? {
        guard let fileURL, let pendingSelection else { return nil }
        guard pendingSelection.fileURL == fileURL else { return nil }
        self.pendingSelection = nil
        return pendingSelection
    }
}

