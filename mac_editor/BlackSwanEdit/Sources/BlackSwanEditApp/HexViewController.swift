import SwiftUI
import AppKit
import BlackSwanEditCore

/// Wraps the AppKit-based Hex viewer so it can live inside SwiftUI.
struct HexViewControllerWrapper: NSViewControllerRepresentable {
    var activeDocument: LocalDocumentBuffer?
    
    func makeNSViewController(context: Context) -> HexViewController {
        let vc = HexViewController()
        if let doc = activeDocument {
            vc.bind(to: doc)
        }
        return vc
    }
    
    func updateNSViewController(_ nsViewController: HexViewController, context: Context) {
        if let doc = activeDocument {
            nsViewController.bind(to: doc)
        }
    }
}

class HexViewController: NSViewController {
    
    var document: LocalDocumentBuffer?
    private let scrollView = NSScrollView()
    private let hexView = HexTextView(frame: .zero)
    
    override func loadView() {
        self.view = NSView()
        
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        
        // Setup Hex View
        scrollView.documentView = hexView
        
        // Layout
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
    
    func bind(to document: LocalDocumentBuffer) {
        self.document = document
        hexView.document = document
    }
}
