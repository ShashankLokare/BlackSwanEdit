import AppKit
import CoreText
import BlackSwanEditCore

/// Caches CoreText line layouts for visible regions so we don't re-layout constantly on scroll.
@MainActor
final class LineLayoutCache {
    struct LineLayout {
        var attributedString: NSAttributedString
        var ctLine: CTLine
        var height: CGFloat
        var descent: CGFloat
    }
    
    // Key: Logical Line Number
    private var cache: [Int: LineLayout] = [:]
    
    // MVP: Let's assume a monospaced font for simplicity.
    private let font: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    
    // Syntax Highlighting Services
    var languageService: LanguageService?
    var activeLanguage: LanguageDef?
    
    // State Tracking for multi-line blocks (like /* */ comments) - simplified MVP
    private var lineStates: [Int: TokeniserState] = [:]
    
    func invalidate() {
        cache.removeAll()
        lineStates.removeAll()
    }
    
    func invalidate(line: Int) {
        cache.removeValue(forKey: line)
    }
    
    func layout(for line: Int, in buffer: PieceChainBuffer) -> LineLayout? {
        if let existing = cache[line] { return existing }
        
        guard let byteRange = buffer.byteRange(forLine: line) else { return nil }
        
        // Exclude the trailing newline from the line rendering
        let rawData = buffer.bytes(in: byteRange)
        guard var string = String(data: rawData, encoding: .utf8) else { return nil }
        if string.hasSuffix("\n") { string.removeLast() }
        if string.hasSuffix("\r") { string.removeLast() }
        
        // Create base attributed string
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]
        
        let attrStr = NSMutableAttributedString(string: string, attributes: attrs)
        
        // Tokenise if language services are attached
        if let ls = languageService, let lang = activeLanguage {
            // Find prior state (MVP: just grab previous line or initial)
            let prior = lineStates[line - 1] ?? .initial
            let (tokens, newState) = ls.tokenise(line: Data(string.utf8), language: lang, priorState: prior)
            lineStates[line] = newState
            
            // Map Token Rules to NSColor
            for token in tokens {
                // Token ranges are in UTF-8 byte offsets; convert to an NSRange in UTF-16 code units.
                guard token.byteRange.lowerBound <= token.byteRange.upperBound,
                      token.byteRange.upperBound <= UInt64(string.utf8.count)
                else { continue }

                let utf8 = string.utf8
                let b0 = utf8.index(utf8.startIndex, offsetBy: Int(token.byteRange.lowerBound))
                let b1 = utf8.index(utf8.startIndex, offsetBy: Int(token.byteRange.upperBound))
                guard let s0 = b0.samePosition(in: string),
                      let s1 = b1.samePosition(in: string)
                else { continue }

                let nsRange = NSRange(s0..<s1, in: string)
                
                var color: NSColor = .textColor
                switch token.typeID {
                case "keyword", "keyword.value", "keyword.builtin":
                    color = .systemPink
                case "string":
                    color = .systemRed
                case "comment", "comment.block":
                    color = .systemGreen
                case "number":
                    color = .systemOrange
                case "type", "attribute", "tag":
                    color = .systemTeal
                case "function":
                    color = .systemBlue
                case "class":
                    color = .systemIndigo
                case "variable", "property":
                    color = .systemBrown
                default: break
                }
                
                attrStr.addAttribute(.foregroundColor, value: color, range: nsRange)
            }
        }
        
        let ctLine = CTLineCreateWithAttributedString(attrStr as CFAttributedString)
        
        // Measure
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
        let height = ascent + descent + leading
        
        let layout = LineLayout(
            attributedString: attrStr,
            ctLine: ctLine,
            height: ceil(max(height, font.capHeight * 1.5)), // ensure minimum line height
            descent: ceil(descent)
        )
        
        cache[line] = layout
        return layout
    }
    
    var defaultLineHeight: CGFloat {
        ceil(font.capHeight * 1.5)
    }
    
    var advanceWidth: CGFloat {
        font.maximumAdvancement.width
    }
}

/// The main canvas for rendering text using CoreText + PieceChainBuffer.
@MainActor
class EditorTextView: NSView, EditorActionPerformer {
    
    weak var document: LocalDocumentBuffer? {
        didSet {
            self.buffer = document?.buffer
        }
    }
    
    var buffer: PieceChainBuffer? {
        didSet {
            refreshLayoutAndFrame()
        }
    }
    
    var searchMatches: [SearchMatch] = [] {
        didSet { needsDisplay = true }
    }
    
    var selection: EditorSelection = .linear(LinearSelection(caret: TextPosition(line: 0, column: 0))) {
        didSet { 
            updateSelectionLayers()
            updateDocumentCursor()
        }
    }
    
    private func updateDocumentCursor() {
        guard let document = document, let buffer = buffer else { return }
        switch selection {
        case .linear(let lin):
            document.cursorLine = lin.active.line
            document.cursorColumn = lin.active.column
            document.cursorByteOffset = byteOffset(for: lin.active, in: buffer)
        case .column(let col):
            // Show the lead cursor of the block
            document.cursorLine = col.active.line
            document.cursorColumn = col.active.column
            document.cursorByteOffset = byteOffset(for: col.active, in: buffer)
        }
    }
    
    private let layoutCache = LineLayoutCache()
    
    private let selectionLayer = CAShapeLayer()
    private let caretLayer = CALayer()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }
    
    private func setupLayers() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        
        selectionLayer.fillColor = NSColor.selectedTextBackgroundColor.cgColor
        selectionLayer.opacity = 0.5
        layer?.addSublayer(selectionLayer)
        
        caretLayer.backgroundColor = NSColor.textColor.cgColor
        layer?.addSublayer(caretLayer)
        
        // Blink animation
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.0
        anim.duration = 0.5
        anim.autoreverses = true
        anim.repeatCount = .infinity
        caretLayer.add(anim, forKey: "blink")
    }
    
    override var isFlipped: Bool { true } // Top-left origin
    
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true
        return ok
    }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let buffer = buffer else { return }
        
        // Background
        context.setFillColor(NSColor.textBackgroundColor.cgColor)
        context.fill(dirtyRect)
        
        let lineHeight = layoutCache.defaultLineHeight
        
        // Draw Search Matches (Under text)
        context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.4).cgColor)
        for match in searchMatches {
            let startPos = position(for: match.byteRange.lowerBound, in: buffer)
            let endPos = position(for: match.byteRange.upperBound, in: buffer)
            
            let rStart = rectFor(position: startPos)
            let rEnd = rectFor(position: endPos)
            
            if startPos.line == endPos.line {
                context.fill(NSRect(x: rStart.minX, y: rStart.minY, width: max(2.0, rEnd.minX - rStart.minX), height: rStart.height))
            } else {
                context.fill(NSRect(x: rStart.minX, y: rStart.minY, width: bounds.width - rStart.minX, height: rStart.height))
                if endPos.line > startPos.line + 1 {
                    let midY = rStart.maxY
                    let midH = CGFloat(endPos.line - startPos.line - 1) * lineHeight
                    context.fill(NSRect(x: 5.0, y: midY, width: bounds.width - 5.0, height: midH))
                }
                context.fill(NSRect(x: 5.0, y: rEnd.minY, width: rEnd.minX - 5.0, height: rEnd.height))
            }
        }
        
        // Determine visible lines based on dirtyRect
        let topVisibleLine = max(0, Int(floor(dirtyRect.minY / lineHeight)))
        let bottomVisibleLine = min(buffer.lineCount - 1, Int(ceil(dirtyRect.maxY / lineHeight)))
        
        guard topVisibleLine <= bottomVisibleLine else { return }
        
        // Set text matrix to match AppKit's flipped coordinate system
        context.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
        
        for line in topVisibleLine...bottomVisibleLine {
            guard let layout = layoutCache.layout(for: line, in: buffer) else { continue }
            
            // Calculate baseline Y. Since we are flipped, the origin is top-left of the line's rect.
            // CoreText draws from the baseline up. So baseline = Top of line + Ascent
            let lineTopY = CGFloat(line) * lineHeight
            let baselineY = lineTopY + (lineHeight - layout.descent)
            
            context.textPosition = CGPoint(x: 5.0, y: baselineY)
            CTLineDraw(layout.ctLine, context)
        }
    }
    
    // Provide an intrinsic size to drive the NSScrollView's document size.
    override var intrinsicContentSize: NSSize {
        guard let buffer = buffer else { return .zero }
        let h = CGFloat(buffer.lineCount) * layoutCache.defaultLineHeight
        // Hardcode a width for MVP; in reality we track max line width or wrap.
        return NSSize(width: 800, height: h)
    }
    
    func setLanguage(_ lang: LanguageDef, service: LanguageService) {
        layoutCache.activeLanguage = lang
        layoutCache.languageService = service
        refreshLayoutAndFrame()
    }
    
    // Frame updates for NSScrollView resizing
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSelectionLayers()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        adjustDocumentFrame()
    }

    private func refreshLayoutAndFrame() {
        layoutCache.invalidate()
        invalidateIntrinsicContentSize()
        adjustDocumentFrame()
        needsDisplay = true
        updateSelectionLayers()
    }

    private func adjustDocumentFrame() {
        let contentSize = intrinsicContentSize
        guard contentSize != .zero else { return }

        var width = contentSize.width
        if let scroll = enclosingScrollView {
            width = max(width, scroll.contentView.bounds.width)
        }

        if frame.size.width != width || frame.size.height != contentSize.height {
            super.setFrameSize(NSSize(width: width, height: contentSize.height))
        }
    }
    
    // MARK: - Coordinate Mapping & Selection Rendering
    
    private func position(for offset: UInt64, in buffer: PieceChainBuffer) -> TextPosition {
        textPosition(forByteOffset: offset, in: buffer)
    }

    private func byteOffset(for position: TextPosition, in buffer: PieceChainBuffer) -> UInt64 {
        let line = min(max(0, position.line), max(0, buffer.lineCount - 1))
        guard let lineRange = buffer.byteRange(forLine: line) else { return buffer.byteLength }

        // Treat column as UTF-16 units (per Selection.swift). Convert to UTF-8 bytes.
        let lineData = buffer.bytes(in: lineRange)
        let lineStr = String(data: lineData, encoding: .utf8) ?? ""
        let clampedCol = min(max(0, position.column), lineStr.utf16.count)
        let prefix = String(decoding: Array(lineStr.utf16.prefix(clampedCol)), as: UTF16.self)
        let byteCount = prefix.utf8.count
        return min(lineRange.lowerBound + UInt64(byteCount), buffer.byteLength)
    }

    private func textPosition(forByteOffset offset: UInt64, in buffer: PieceChainBuffer) -> TextPosition {
        let clampedOffset = min(offset, buffer.byteLength)
        let line = buffer.line(containing: clampedOffset)
        guard let lineRange = buffer.byteRange(forLine: line) else {
            return TextPosition(line: line, column: 0)
        }

        let end = min(clampedOffset, lineRange.upperBound)
        let prefixData = buffer.bytes(in: lineRange.lowerBound..<end)
        let prefixStr = String(data: prefixData, encoding: .utf8) ?? ""
        return TextPosition(line: line, column: prefixStr.utf16.count)
    }
    
    private func rectFor(position: TextPosition) -> NSRect {
        let lh = layoutCache.defaultLineHeight
        let cw = layoutCache.advanceWidth
        // x offset is 5.0 (margin)
        return NSRect(x: 5.0 + CGFloat(position.column) * cw,
                      y: CGFloat(position.line) * lh,
                      width: cw,
                      height: lh)
    }

    func scrollSelectionToVisible() {
        switch selection {
        case .linear(let lin):
            let lh = layoutCache.defaultLineHeight
            var r = rectFor(position: lin.active)
            r = r.insetBy(dx: -40.0, dy: -lh * 2.0)
            _ = scrollToVisible(r)
        case .column(let col):
            let lh = layoutCache.defaultLineHeight
            let a = TextPosition(line: col.active.line, column: col.active.column)
            var r = rectFor(position: a)
            r = r.insetBy(dx: -40.0, dy: -lh * 2.0)
            _ = scrollToVisible(r)
        }
    }
    
    private func textPosition(at point: NSPoint) -> TextPosition {
        guard let buffer = buffer else { return TextPosition(line: 0, column: 0) }
        let lh = layoutCache.defaultLineHeight
        let cw = layoutCache.advanceWidth
        
        let line = max(0, min(buffer.lineCount - 1, Int(floor(point.y / lh))))
        let rawCol = max(0, Int(round((point.x - 5.0) / cw)))
        let maxCol = maxColumn(forLine: line, in: buffer)
        return TextPosition(line: line, column: min(rawCol, maxCol))
    }

    private func maxColumn(forLine line: Int, in buffer: PieceChainBuffer) -> Int {
        guard let range = buffer.byteRange(forLine: line) else { return 0 }
        let data = buffer.bytes(in: range)
        let str = String(data: data, encoding: .utf8) ?? ""
        return str.utf16.count
    }
    
    private func updateSelectionLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        switch selection {
        case .linear(let lin):
            if lin.isEmpty {
                selectionLayer.path = nil
                let r = rectFor(position: lin.active)
                caretLayer.frame = NSRect(x: r.minX, y: r.minY, width: 2.0, height: r.height)
                caretLayer.isHidden = false
            } else {
                caretLayer.isHidden = true
                
                let path = CGMutablePath()
                let start = lin.start
                let end = lin.end
                
                if start.line == end.line {
                    let r1 = rectFor(position: start)
                    let r2 = rectFor(position: end)
                    path.addRect(NSRect(x: r1.minX, y: r1.minY, width: r2.minX - r1.minX, height: r1.height))
                } else {
                    // Start line
                    let r1 = rectFor(position: start)
                    path.addRect(NSRect(x: r1.minX, y: r1.minY, width: bounds.width - r1.minX, height: r1.height))
                    // Middle lines
                    if end.line > start.line + 1 {
                        let midY = r1.maxY
                        let midH = CGFloat(end.line - start.line - 1) * layoutCache.defaultLineHeight
                        path.addRect(NSRect(x: 5.0, y: midY, width: bounds.width - 5.0, height: midH))
                    }
                    // End line
                    let r2 = rectFor(position: end)
                    path.addRect(NSRect(x: 5.0, y: r2.minY, width: r2.minX - 5.0, height: r2.height))
                }
                selectionLayer.path = path
            }
            
        case .column(let colSel):
            caretLayer.isHidden = true
            let path = CGMutablePath()
            let rTopLeft = rectFor(position: TextPosition(line: colSel.topLine, column: colSel.leftCol))
            let rBotRight = rectFor(position: TextPosition(line: colSel.bottomLine, column: colSel.rightCol))
            
            let w = max(rBotRight.minX - rTopLeft.minX, 2.0)
            let h = max(rBotRight.maxY - rTopLeft.minY, layoutCache.defaultLineHeight)
            path.addRect(NSRect(x: rTopLeft.minX, y: rTopLeft.minY, width: w, height: h))
            selectionLayer.path = path
        }
        
        CATransaction.commit()
    }
    
    // MARK: - Mouse Events
    
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        let pos = textPosition(at: pt)
        
        if event.modifierFlags.contains(.option) {
            selection = .column(ColumnSelection(anchor: pos, active: pos))
        } else {
            selection = .linear(LinearSelection(caret: pos))
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let pos = textPosition(at: pt)
        
        switch selection {
        case .linear(var lin):
            lin.active = pos
            selection = .linear(lin)
        case .column(var col):
            col.active = pos
            selection = .column(col)
        }
        
        autoscroll(with: event)
    }
    
    // MARK: - Keyboard Events
    
    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    @IBAction func copy(_ sender: Any?) {
        guard let buffer else { return }

        let textToCopy: String
        switch selection {
        case .linear(let lin):
            guard !lin.isEmpty else { return }
            let startOffset = byteOffset(for: lin.start, in: buffer)
            let endOffset = byteOffset(for: lin.end, in: buffer)
            guard endOffset > startOffset else { return }
            let data = buffer.bytes(in: startOffset..<endOffset)
            textToCopy = String(data: data, encoding: .utf8) ?? ""
        case .column(let col):
            let block = buffer.extractColumnBlock(col)
            textToCopy = block.rows.map { String(data: $0, encoding: .utf8) ?? "" }.joined(separator: "\n")
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToCopy, forType: .string)
    }

    @IBAction func cut(_ sender: Any?) {
        copy(sender)
        performDeleteBackward()
    }

    @IBAction func paste(_ sender: Any?) {
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        performInsertText(str)
    }

    @IBAction override func selectAll(_ sender: Any?) {
        guard let buffer else { return }
        let start = TextPosition(line: 0, column: 0)
        let end = textPosition(forByteOffset: buffer.byteLength, in: buffer)
        selection = .linear(LinearSelection(anchor: start, active: end))
    }

    @IBAction func undo(_ sender: Any?) {
        document?.undo()
        refreshLayoutAndFrame()
    }

    @IBAction func redo(_ sender: Any?) {
        document?.redo()
        refreshLayoutAndFrame()
    }
    
    // MARK: - AppKit Event overrides
    override func insertText(_ insertString: Any) {
        guard let text = insertString as? String else { return }
        MacroEngine.shared.record(.insertText(text))
        performInsertText(text)
    }
    
    override func deleteBackward(_ sender: Any?) {
        MacroEngine.shared.record(.deleteBackward)
        performDeleteBackward()
    }
    
    override func moveLeft(_ sender: Any?) {
        MacroEngine.shared.record(.moveLeft)
        performMoveLeft()
    }
    
    override func moveRight(_ sender: Any?) {
        MacroEngine.shared.record(.moveRight)
        performMoveRight()
    }
    
    override func moveUp(_ sender: Any?) {
        MacroEngine.shared.record(.moveUp)
        performMoveUp()
    }
    
    override func moveDown(_ sender: Any?) {
        MacroEngine.shared.record(.moveDown)
        performMoveDown()
    }

    // MARK: - EditorActionPerformer Compliance (Internal Mutation Logic)
    
    func performInsertText(_ text: String) {
        guard let buffer = buffer, let document = document else { return }
        
        guard case .linear(let lin) = selection else { return }

        let insertTextData = Data(text.utf8)

        if !lin.isEmpty {
            let startOffset = byteOffset(for: lin.start, in: buffer)
            let endOffset = byteOffset(for: lin.end, in: buffer)
            if endOffset > startOffset {
                document.delete(range: startOffset..<endOffset)
            }
            document.insert(text, at: startOffset)
            refreshLayoutAndFrame()
            let caretOffset = startOffset + UInt64(insertTextData.count)
            selection = .linear(LinearSelection(caret: textPosition(forByteOffset: caretOffset, in: buffer)))
            return
        }

        let caretOffset = byteOffset(for: lin.active, in: buffer)
        document.insert(text, at: caretOffset)
        refreshLayoutAndFrame()
        let newCaretOffset = caretOffset + UInt64(insertTextData.count)
        selection = .linear(LinearSelection(caret: textPosition(forByteOffset: newCaretOffset, in: buffer)))
    }
    
    func performDeleteBackward() {
        guard let buffer = buffer, let document = document else { return }
        guard case .linear(let lin) = selection else { return }

        if !lin.isEmpty {
            let startOffset = byteOffset(for: lin.start, in: buffer)
            let endOffset = byteOffset(for: lin.end, in: buffer)
            if endOffset > startOffset {
                document.delete(range: startOffset..<endOffset)
                refreshLayoutAndFrame()
                selection = .linear(LinearSelection(caret: textPosition(forByteOffset: startOffset, in: buffer)))
            }
            return
        }

        guard lin.active.column > 0 else { return }
        let from = TextPosition(line: lin.active.line, column: lin.active.column - 1)
        let startOffset = byteOffset(for: from, in: buffer)
        let endOffset = byteOffset(for: lin.active, in: buffer)
        guard endOffset > startOffset else { return }
        document.delete(range: startOffset..<endOffset)
        refreshLayoutAndFrame()
        selection = .linear(LinearSelection(caret: from))
    }
    
    func performMoveLeft() {
        guard case .linear(let lin) = selection else { return }
        let c = max(0, lin.active.column - 1)
        selection = .linear(LinearSelection(caret: TextPosition(line: lin.active.line, column: c)))
    }
    
    func performMoveRight() {
        guard case .linear(let lin) = selection, let buffer else { return }
        let maxCol = maxColumn(forLine: lin.active.line, in: buffer)
        let c = min(maxCol, lin.active.column + 1)
        selection = .linear(LinearSelection(caret: TextPosition(line: lin.active.line, column: c)))
    }
    
    func performMoveUp() {
        guard case .linear(let lin) = selection, let buffer else { return }
        let l = max(0, lin.active.line - 1)
        let maxCol = maxColumn(forLine: l, in: buffer)
        selection = .linear(LinearSelection(caret: TextPosition(line: l, column: min(lin.active.column, maxCol))))
    }
    
    func performMoveDown() {
        guard case .linear(let lin) = selection, let buffer else { return }
        let l = min(buffer.lineCount - 1, lin.active.line + 1)
        let maxCol = maxColumn(forLine: l, in: buffer)
        selection = .linear(LinearSelection(caret: TextPosition(line: l, column: min(lin.active.column, maxCol))))
    }
}

/// Draws line numbers down the left side. Pinned in the EditorViewController.
@MainActor
class GutterView: NSView {
    var buffer: PieceChainBuffer? {
        didSet { needsDisplay = true }
    }
    
    // Must match EditorTextView
    var lineHeight: CGFloat = 18.0
    
    override var isFlipped: Bool { true }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let buffer = buffer else { return }
        
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(dirtyRect)
        
        let borderPath = NSBezierPath()
        borderPath.move(to: NSPoint(x: bounds.maxX - 1, y: 0))
        borderPath.line(to: NSPoint(x: bounds.maxX - 1, y: bounds.maxY))
        NSColor.separatorColor.setStroke()
        borderPath.stroke()
        
        let topVisibleLine = max(0, Int(floor(dirtyRect.minY / lineHeight)))
        let bottomVisibleLine = min(buffer.lineCount - 1, Int(ceil(dirtyRect.maxY / lineHeight)))
        
        guard topVisibleLine <= bottomVisibleLine else { return }
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]
        
        for line in topVisibleLine...bottomVisibleLine {
            // Lines are 1-indexed for display
            let text = "\(line + 1)" as NSString
            let lineTopY = CGFloat(line) * lineHeight
            
            let drawRect = NSRect(x: 0, y: lineTopY + 2, width: bounds.width - 8, height: lineHeight)
            text.draw(in: drawRect, withAttributes: attrs)
        }
    }
}
