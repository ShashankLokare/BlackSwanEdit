import AppKit
import BlackSwanEditCore

protocol SearchPanelDelegate: AnyObject {
    func searchPanelDidUpdateQuery(_ panel: SearchPanelViewController, pattern: String, options: SearchOptions)
    func searchPanelDidRequestNext(_ panel: SearchPanelViewController)
    func searchPanelDidRequestPrevious(_ panel: SearchPanelViewController)
    func searchPanelDidRequestReplace(_ panel: SearchPanelViewController, with template: String)
    func searchPanelDidRequestReplaceAll(_ panel: SearchPanelViewController, with template: String)
    func searchPanelDidClose(_ panel: SearchPanelViewController)
}

class SearchPanelViewController: NSViewController, NSTextFieldDelegate {
    
    weak var delegate: SearchPanelDelegate?
    
    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let matchCaseBtn = NSButton(checkboxWithTitle: "Aa", target: nil, action: nil)
    private let regexBtn = NSButton(checkboxWithTitle: ".*", target: nil, action: nil)
    
    private let nextBtn = NSButton(title: "Next", target: nil, action: nil)
    private let prevBtn = NSButton(title: "Prev", target: nil, action: nil)
    private let replaceBtn = NSButton(title: "Replace", target: nil, action: nil)
    private let replaceAllBtn = NSButton(title: "Replace All", target: nil, action: nil)
    private let closeBtn = NSButton(title: "Done", target: nil, action: nil)

    private var replaceRow: NSStackView?
    private let statusLabel = NSTextField(labelWithString: "")
    
    override func loadView() {
        let container = NSVisualEffectView()
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        self.view = container
        
        setupUI()
    }
    
    private func setupUI() {
        let vStack = NSStackView()
        vStack.orientation = .vertical
        vStack.translatesAutoresizingMaskIntoConstraints = false
        vStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.addSubview(vStack)
        
        NSLayoutConstraint.activate([
            vStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            vStack.topAnchor.constraint(equalTo: view.topAnchor),
            vStack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // ROW 1: Find
        let findStack = NSStackView(views: [NSTextField(labelWithString: "Find:"), findField, matchCaseBtn, regexBtn])
        findField.placeholderString = "Search..."
        findField.target = self
        findField.action = #selector(onFindTextChanged)
        findField.delegate = self
        
        // ROW 2: Replace
        let replaceStack = NSStackView(views: [NSTextField(labelWithString: "Replace:"), replaceField])
        replaceField.placeholderString = "Replacement..."
        replaceField.delegate = self
        replaceRow = replaceStack
        
        // ROW 3: Actions
        nextBtn.target = self
        nextBtn.action = #selector(onNext)
        prevBtn.target = self
        prevBtn.action = #selector(onPrev)
        replaceBtn.target = self
        replaceBtn.action = #selector(onReplace)
        replaceAllBtn.target = self
        replaceAllBtn.action = #selector(onReplaceAll)
        closeBtn.target = self
        closeBtn.action = #selector(onClose)
        
        let actionStack = NSStackView(views: [prevBtn, nextBtn, replaceBtn, replaceAllBtn, closeBtn])

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.stringValue = ""
        
        vStack.addArrangedSubview(findStack)
        vStack.addArrangedSubview(replaceStack)
        vStack.addArrangedSubview(actionStack)
        vStack.addArrangedSubview(statusLabel)
        
        // Button actions for toggles trigger search update
        matchCaseBtn.target = self
        matchCaseBtn.action = #selector(onFindTextChanged)
        regexBtn.target = self
        regexBtn.action = #selector(onFindTextChanged)

        setReplaceMode(false)
    }
    
    var currentOptions: SearchOptions {
        var opt: SearchOptions = []
        if matchCaseBtn.state == .on { opt.insert(.caseSensitive) }
        if regexBtn.state == .on { opt.insert(.regex) }
        return opt
    }

    var currentPattern: String {
        findField.stringValue
    }
    
    @objc private func onFindTextChanged() {
        delegate?.searchPanelDidUpdateQuery(self, pattern: findField.stringValue, options: currentOptions)
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField == findField {
            onFindTextChanged()
        }
    }
    
    @objc private func onNext() { delegate?.searchPanelDidRequestNext(self) }
    @objc private func onPrev() { delegate?.searchPanelDidRequestPrevious(self) }
    
    @objc private func onReplace() {
        delegate?.searchPanelDidRequestReplace(self, with: replaceField.stringValue)
    }
    
    @objc private func onReplaceAll() {
        delegate?.searchPanelDidRequestReplaceAll(self, with: replaceField.stringValue)
    }
    
    @objc private func onClose() {
        delegate?.searchPanelDidClose(self)
    }
    
    func focusField() {
        view.window?.makeFirstResponder(findField)
    }

    func focusReplaceField() {
        view.window?.makeFirstResponder(replaceField)
    }

    func setReplaceMode(_ enabled: Bool) {
        replaceRow?.isHidden = !enabled
        replaceBtn.isHidden = !enabled
        replaceAllBtn.isHidden = !enabled
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }
}
