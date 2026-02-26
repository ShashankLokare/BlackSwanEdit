import AppKit
import CoreText
import BlackSwanEditCore

/// Renders a PieceChainBuffer in a standard 16-byte Hex Grid.
@MainActor
class HexTextView: NSView {
    
    weak var document: LocalDocumentBuffer? {
        didSet {
            self.buffer = document?.buffer
        }
    }
    
    var buffer: PieceChainBuffer? {
        didSet { needsDisplay = true }
    }
    
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let bytesPerRow: UInt64 = 16
    
    // Measured sizes based on font
    private var lineHeight: CGFloat = 16.0
    private var advanceWidth: CGFloat = 8.0
    
    private var selectedByteOffset: UInt64? = nil {
        didSet { 
            needsDisplay = true
            updateDocumentCursor()
        }
    }
    
    private func updateDocumentCursor() {
        guard let document = document, let offset = selectedByteOffset else { return }
        document.cursorLine = Int(offset / bytesPerRow)
        document.cursorColumn = Int(offset % bytesPerRow)
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        
        let sampleAttr = NSAttributedString(string: "0", attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(sampleAttr as CFAttributedString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let advance = CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
        
        self.advanceWidth = CGFloat(advance)
        self.lineHeight = ceil(max(ascent + descent + leading, font.capHeight * 1.5))
    }
    
    override var isFlipped: Bool { true }
    
    override var acceptsFirstResponder: Bool { true }
    
    override var intrinsicContentSize: NSSize {
        guard let buffer = buffer else { return .zero }
        let rows = CGFloat((buffer.byteLength + bytesPerRow - 1) / bytesPerRow)
        // Fixed width for 16-byte mode: Address(8) + space + Hex(47) + space + Ascii(16) -> ~74 chars
        return NSSize(width: 74 * advanceWidth + 20, height: max(bounds.height, rows * lineHeight))
    }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let buffer = buffer else { return }
        
        context.setFillColor(NSColor.textBackgroundColor.cgColor)
        context.fill(dirtyRect)
        
        let byteLength = buffer.byteLength
        if byteLength == 0 { return }
        
        let topRow = max(0, UInt64(floor(dirtyRect.minY / lineHeight)))
        let bottomRow = min((byteLength + bytesPerRow - 1) / bytesPerRow, UInt64(ceil(dirtyRect.maxY / lineHeight)))
        
        context.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
        
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]
        
        let addressAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        
        for row in topRow...bottomRow {
            let offset = row * bytesPerRow
            guard offset < byteLength else { break }
            
            let length = min(bytesPerRow, byteLength - offset)
            let chunk = buffer.bytes(in: offset..<(offset + length))
            
            // 1. Address
            let addressStr = String(format: "%08X", offset)
            let addressAttrStr = NSAttributedString(string: addressStr, attributes: addressAttrs)
            
            // 2. Hex
            var hexStr = ""
            for byte in chunk {
                hexStr += String(format: "%02X ", byte)
            }
            // Pad out to 16 bytes if short
            if length < bytesPerRow {
                let diff = bytesPerRow - length
                hexStr += String(repeating: "   ", count: Int(diff))
            }
            let hexAttrStr = NSAttributedString(string: hexStr, attributes: attrs)
            
            // 3. ASCII
            var asciiStr = ""
            for byte in chunk {
                // Printable ASCII range 32...126
                if byte >= 32 && byte <= 126 {
                    asciiStr.append(Character(UnicodeScalar(byte)))
                } else {
                    asciiStr.append(".")
                }
            }
            let asciiAttrStr = NSAttributedString(string: asciiStr, attributes: attrs)
            
            // Draw Selection
            if let sel = selectedByteOffset, sel >= offset && sel < offset + length {
                let selCol = sel - offset
                let selRect = NSRect(x: 10.0 + (10 * advanceWidth) + CGFloat(selCol * 3) * advanceWidth,
                                     y: CGFloat(row) * lineHeight,
                                     width: 2 * advanceWidth,
                                     height: lineHeight)
                context.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.5).cgColor)
                context.fill(selRect)
            }
            
            let y = CGFloat(row) * lineHeight + (lineHeight - ceil(font.descender)) // Baseline adjustment (simple)
            
            context.textPosition = CGPoint(x: 10.0, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(addressAttrStr), context)
            
            context.textPosition = CGPoint(x: 10.0 + (10 * advanceWidth), y: y)
            CTLineDraw(CTLineCreateWithAttributedString(hexAttrStr), context)
            
            context.textPosition = CGPoint(x: 10.0 + (60 * advanceWidth), y: y)
            CTLineDraw(CTLineCreateWithAttributedString(asciiAttrStr), context)
        }
    }
    
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
    }
    
    // MARK: - Input Handling
    
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        
        let row = UInt64(max(0, floor(pt.y / lineHeight)))
        let hexStartX = 10.0 + (10 * advanceWidth)
        
        if pt.x >= hexStartX {
            let colIndex = Int(floor((pt.x - hexStartX) / (3 * advanceWidth)))
            if colIndex >= 0 && colIndex < 16 {
                let offset = row * bytesPerRow + UInt64(colIndex)
                if let buffer = buffer, offset <= buffer.byteLength { // allow selecting end-of-file for append
                    selectedByteOffset = offset
                }
            }
        }
    }
    
    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }
    
    override func insertText(_ insertString: Any) {
        guard let text = insertString as? String, let buffer = buffer, let document = document else { return }
        guard let offset = selectedByteOffset else { return }
        
        // Simply insert string as utf8 at offset
        document.insert(text, at: offset)
        selectedByteOffset = offset + UInt64(text.utf8.count)
    }

    override func deleteBackward(_ sender: Any?) {
        guard let buffer = buffer, let document = document else { return }
        guard let offset = selectedByteOffset, offset > 0 else { return }
        
        document.delete(range: (offset - 1)..<offset)
        selectedByteOffset = offset - 1
    }
}
