import Foundation
import Combine

@MainActor
final class EditorUIState: ObservableObject {
    static let shared = EditorUIState()

    @Published var sidebarVisible: Bool = true
    @Published var terminalVisible: Bool = false
    @Published var minimapVisible: Bool = false
    @Published var sourceControlVisible: Bool = false
    @Published var searchResultsVisible: Bool = false

    private init() {}
}

extension Notification.Name {
    static let editorShowFind = Notification.Name("BlackSwanEdit.editorShowFind")
    static let editorShowFindInFiles = Notification.Name("BlackSwanEdit.editorShowFindInFiles")
    static let editorShowReplace = Notification.Name("BlackSwanEdit.editorShowReplace")
}
