import Cocoa
import SwiftUI
import BlackSwanEditCore

// MARK: - EditorCommand Router Enum

enum EditorCommand: String, CaseIterable {
    case navigateBack
    case navigateForward
    case openFile
    case find
    case findInFiles
    case toggleReplace
    case toggleSidebar
    case toggleTerminal
    case toggleMinimap
    case showSourceControl
}

// MARK: - NSToolbar Implementation

class EditorWindowController: NSWindowController, NSToolbarDelegate {
    
    // UI Panel Stub References
    // Group Identifiers
    private static let toolbarID = NSToolbar.Identifier("BlackSwanEditorToolbar")
    private let navGroupID = NSToolbarItem.Identifier("BlackSwan.NavGroup")
    private let searchGroupID = NSToolbarItem.Identifier("BlackSwan.SearchGroup")
    private let layoutGroupID = NSToolbarItem.Identifier("BlackSwan.LayoutGroup")
    
    override func windowDidLoad() {
        super.windowDidLoad()
        setupToolbar()
    }
    
    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: Self.toolbarID)
        toolbar.delegate = self
        // Style parameters enforcing Xcode-style clean visuals
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        
        // Hide standard window title for unified look if desired (macOS 11+)
        if #available(macOS 11.0, *) {
            window?.toolbarStyle = .unified
            window?.titleVisibility = .hidden
        }
        
        window?.toolbar = toolbar
    }
    
    // MARK: - Command Router Execution
    
    @objc func handleToolbarAction(_ sender: NSToolbarItemGroup) {
        guard sender.selectedIndex >= 0 else { return }
        // The sender.selectedSegment represents the index within the group
        
        // Let's resolve the specific nested command based on the group and index
        switch sender.itemIdentifier {
        case navGroupID:
            switch sender.selectedIndex {
            case 0: executeCommand(.navigateBack)
            case 1: executeCommand(.navigateForward)
            case 2: executeCommand(.openFile)
            default: break
            }
        case searchGroupID:
            switch sender.selectedIndex {
            case 0: executeCommand(.find)
            case 1: executeCommand(.findInFiles)
            case 2: executeCommand(.toggleReplace)
            default: break
            }
        case layoutGroupID:
            switch sender.selectedIndex {
            case 0: executeCommand(.toggleSidebar)
            case 1: executeCommand(.toggleTerminal)
            case 2: executeCommand(.toggleMinimap)
            case 3: executeCommand(.showSourceControl)
            default: break
            }
        default:
            break
        }
        
        // Deselect immediately so it acts as a momentary push button
        sender.setSelected(false, at: sender.selectedIndex)
    }
    
    func executeCommand(_ command: EditorCommand) {
        Swift.print("Executing Command: \(command.rawValue)")
        
        switch command {
        case .navigateBack:
            navigateDocument(delta: -1)
        case .navigateForward:
            navigateDocument(delta: 1)
        case .openFile:
            showOpenDialog()
        case .find:
            showInlineFindBar()
        case .findInFiles:
            openSearchPanel()
        case .toggleReplace:
            showReplacePanel()
        case .toggleSidebar:
            EditorUIState.shared.sidebarVisible.toggle()
        case .toggleTerminal:
            EditorUIState.shared.terminalVisible.toggle()
        case .toggleMinimap:
            EditorUIState.shared.minimapVisible.toggle()
        case .showSourceControl:
            EditorUIState.shared.sidebarVisible = true
            EditorUIState.shared.sourceControlVisible.toggle()
        }
    }
    
    // MARK: - NSToolbarDelegate
    
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            navGroupID,
            .flexibleSpace,
            searchGroupID,
            .flexibleSpace,
            layoutGroupID
        ]
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace, .print]
    }
    
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        
        let configureGroup = { (id: NSToolbarItem.Identifier, labels: [String], icons: [NSImage?]) -> NSToolbarItemGroup in
            let group = NSToolbarItemGroup(itemIdentifier: id, titles: labels, selectionMode: .momentary, labels: labels, target: self, action: #selector(self.handleToolbarAction(_:)))
            for (idx, icon) in icons.enumerated() {
                group.subitems[idx].image = icon
                // Use symbols if available:
                if #available(macOS 11.0, *) {
                    group.subitems[idx].image?.isTemplate = true
                    group.subitems[idx].toolTip = labels[idx]
                }
            }
            return group
        }
        
        if itemIdentifier == navGroupID {
            return configureGroup(navGroupID,
                                  ["Back", "Forward", "Open..."],
                                  [symbol("chevron.backward"), symbol("chevron.forward"), symbol("folder")])
        }
        else if itemIdentifier == searchGroupID {
            return configureGroup(searchGroupID,
                                  ["Find", "Find in Files", "Replace"],
                                  [symbol("magnifyingglass"), symbol("doc.text.magnifyingglass"), symbol("arrow.triangle.2.circlepath")])
        }
        else if itemIdentifier == layoutGroupID {
            return configureGroup(layoutGroupID,
                                  ["Sidebar", "Terminal", "Minimap", "Source Control"],
                                  [symbol("sidebar.left"), symbol("terminal"), symbol("map"), symbol("arrow.triangle.branch")])
        }
        
        return nil
    }
    
    // MARK: - validateUserInterfaceItem Interface Validator
    
    @objc func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        // NSToolbarItemGroups don't pass deeply individual items to NSValidatedUserInterfaceItem automatically in older APIs,
        // but if they cast back to `NSToolbarItemGroup`, we manually check indices.
        // For menu items bound to standard first-responder actions, this gets invoked.
        
        guard let group = item as? NSToolbarItemGroup else { return true }
        
        // This is a dummy pass. In true implementations, you loop group.subitems
        // and individually disable parts. For example:
        if group.itemIdentifier == navGroupID {
            let documents = DocumentStore.shared.documents
            let active = DocumentStore.shared.activeDocument
            let activeIndex = active.flatMap { doc in documents.firstIndex(where: { $0.id == doc.id }) } ?? -1

            group.subitems[0].isEnabled = activeIndex > 0
            group.subitems[1].isEnabled = activeIndex >= 0 && activeIndex < documents.count - 1
            group.subitems[2].isEnabled = true // Open is always allowed
        }
        else if group.itemIdentifier == searchGroupID {
            // Find operations require an active editor focus.
            let hasActiveDocument = DocumentStore.shared.activeDocument != nil
            group.subitems[0].isEnabled = hasActiveDocument
            group.subitems[1].isEnabled = hasActiveDocument
            group.subitems[2].isEnabled = hasActiveDocument
        }
        else if group.itemIdentifier == layoutGroupID {
            group.subitems[0].isEnabled = true
            group.subitems[1].isEnabled = true
            group.subitems[2].isEnabled = true
            group.subitems[3].isEnabled = Workspace.shared.rootURL != nil
        }
        
        return true
    }
    
    // MARK: - Helpers & Stubs
    
    private func symbol(_ name: String) -> NSImage? {
        if #available(macOS 11.0, *) {
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }
        return nil
    }
    
    private func showOpenDialog() { 
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir {
                Workspace.shared.openFolder(at: url)
            } else {
                do {
                    _ = try DocumentStore.shared.open(url: url)
                    AppLogger.shared.log("Opened file from dialog: \(url.lastPathComponent)")
                } catch {
                    AppLogger.shared.log("Failed to open file: \(error)", level: "ERROR")
                }
            }
        }
    }
    private func showInlineFindBar() {
        let handled = NSApp.sendAction(#selector(EditorViewController.performFindPanelAction(_:)), to: nil, from: self)
        if !handled {
            NotificationCenter.default.post(name: .editorShowFind, object: nil)
        }
    }

    private func openSearchPanel() {
        let handled = NSApp.sendAction(#selector(EditorViewController.performFindInFilesAction(_:)), to: nil, from: self)
        if !handled {
            NotificationCenter.default.post(name: .editorShowFindInFiles, object: nil)
        }
    }

    private func showReplacePanel() {
        let handled = NSApp.sendAction(#selector(EditorViewController.performShowReplaceAction(_:)), to: nil, from: self)
        if !handled {
            NotificationCenter.default.post(name: .editorShowReplace, object: nil)
        }
    }

    private func navigateDocument(delta: Int) {
        let store = DocumentStore.shared
        let docs = store.documents
        guard !docs.isEmpty, let active = store.activeDocument else { return }
        guard let index = docs.firstIndex(where: { $0.id == active.id }) else { return }
        let nextIndex = index + delta
        guard nextIndex >= 0 && nextIndex < docs.count else { return }
        store.activeDocument = docs[nextIndex]
    }
}

// MARK: - SwiftUI Window Accessor
struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                callback(window)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension EditorWindowController {
    static var sharedControllers: [NSWindow: EditorWindowController] = [:]

    static func attach(to window: NSWindow) {
        guard sharedControllers[window] == nil else { return }
        let wc = EditorWindowController()
        wc.window = window
        wc.setupToolbar()
        sharedControllers[window] = wc
        window.windowController = wc
    }
}
