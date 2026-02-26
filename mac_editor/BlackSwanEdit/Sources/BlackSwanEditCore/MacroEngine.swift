import Foundation
import AppKit

/// Defines an atomic interaction the user can perform in the editor.
public enum EditorAction: Codable, Sendable {
    case insertText(String)
    case deleteBackward
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
}

@MainActor
public protocol EditorActionPerformer {
    func performInsertText(_ text: String)
    func performDeleteBackward()
    func performMoveLeft()
    func performMoveRight()
    func performMoveUp()
    func performMoveDown()
}

/// A sequential list of recorded actions that can be serialized and replayed.
public struct Macro: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var actions: [EditorAction]
    
    public init(id: UUID = UUID(), name: String, actions: [EditorAction] = []) {
        self.id = id
        self.name = name
        self.actions = actions
    }
}

/// Manages the recording state and execution of Macros.
@MainActor
public final class MacroEngine: ObservableObject {
    public static let shared = MacroEngine()
    
    @Published public private(set) var isRecording = false
    private var currentActions: [EditorAction] = []
    
    // In-memory stash of recorded macros for MVP.
    @Published public private(set) var savedMacros: [Macro] = []
    
    private init() {}
    
    public func startRecording() {
        guard !isRecording else { return }
        currentActions.removeAll()
        isRecording = true
    }
    
    public func stopRecording(name: String) -> Macro? {
        guard isRecording else { return nil }
        isRecording = false
        
        let m = Macro(name: name, actions: currentActions)
        savedMacros.append(m)
        currentActions.removeAll()
        return m
    }
    
    public func record(_ action: EditorAction) {
        guard isRecording else { return }
        currentActions.append(action)
    }
    
    public func play(_ macro: Macro, on performer: EditorActionPerformer) {
        for action in macro.actions {
            switch action {
            case .insertText(let text):
                performer.performInsertText(text)
            case .deleteBackward:
                performer.performDeleteBackward()
            case .moveLeft:
                performer.performMoveLeft()
            case .moveRight:
                performer.performMoveRight()
            case .moveUp:
                performer.performMoveUp()
            case .moveDown:
                performer.performMoveDown()
            }
        }
    }
}
