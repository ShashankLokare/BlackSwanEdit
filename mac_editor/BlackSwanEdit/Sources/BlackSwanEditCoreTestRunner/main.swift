import Foundation
import BlackSwanEditCore

func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, line: UInt = #line) {
    if a != b {
        fatalError("Assertion failed on line \(line): \(a) is not equal to \(b)")
    }
}

func XCTAssertNotNil<T>(_ a: T?, line: UInt = #line) {
    if a == nil {
        fatalError("Assertion failed on line \(line): Value is nil")
    }
}

func runTests() async {
    print("Running testBasicInitAndAccess...")
    testBasicInitAndAccess()
    print("Running testInsertion...")
    testInsertion()
    print("Running testDeletion...")
    testDeletion()
    print("Running testUndoRedo...")
    testUndoRedo()
    print("Running testLineBoundaries...")
    testLineBoundaries()
    print("Running testColumnSelection...")
    testColumnSelection()
    print("Running testDocumentStoreSave...")
    await testDocumentStoreSave()
    print("Running testSearchAndReplace...")
    await testSearchAndReplace()
    print("All PieceChainBuffer tests passed successfully!")
}

func testBasicInitAndAccess() {
    let text = "Hello, World!"
    let data = Data(text.utf8)
    let buffer = PieceChainBuffer(data: data)

    XCTAssertEqual(buffer.byteLength, UInt64(data.count))
    XCTAssertEqual(buffer.lineCount, 1)
    XCTAssertEqual(String(data: buffer.allBytes(), encoding: .utf8), text)
}

func testInsertion() {
    let buffer = PieceChainBuffer(data: Data())
    buffer.insert(Data("Hello".utf8), at: 0)
    XCTAssertEqual(String(data: buffer.allBytes(), encoding: .utf8), "Hello")

    buffer.insert(Data(" World".utf8), at: 5)
    XCTAssertEqual(String(data: buffer.allBytes(), encoding: .utf8), "Hello World")

    buffer.insert(Data(",".utf8), at: 5)
    XCTAssertEqual(String(data: buffer.allBytes(), encoding: .utf8), "Hello, World")
}

func testDeletion() {
    let text = "Hello, World!"
    let buffer = PieceChainBuffer(data: Data(text.utf8))

    buffer.delete(range: 7..<12)
    XCTAssertEqual(String(data: buffer.allBytes(), encoding: .utf8), "Hello, !")

    buffer.delete(range: 0..<7)
    XCTAssertEqual(String(data: buffer.allBytes(), encoding: .utf8), "!")

    buffer.delete(range: 0..<1)
    XCTAssertEqual(String(data: buffer.allBytes(), encoding: .utf8), "")
}

func testUndoRedo() {
    let buffer = PieceChainBuffer(data: Data())
    let snap0 = buffer.makeSnapshot()

    buffer.insert(Data("A".utf8), at: 0)
    let snap1 = buffer.makeSnapshot()

    buffer.insert(Data("B".utf8), at: 1)
    XCTAssertEqual(String(data: buffer.allBytes(), encoding: .utf8), "AB")

    buffer.restore(snapshot: snap1)
    XCTAssertEqual(String(data: buffer.allBytes(), encoding: .utf8), "A")

    buffer.restore(snapshot: snap0)
    XCTAssertEqual(String(data: buffer.allBytes(), encoding: .utf8), "")

    buffer.restore(snapshot: snap1)
    XCTAssertEqual(String(data: buffer.allBytes(), encoding: .utf8), "A")
}

func testLineBoundaries() {
    let text = "Line 0\nLine 1\nLine 2\n"
    let buffer = PieceChainBuffer(data: Data(text.utf8))

    XCTAssertEqual(buffer.lineCount, 4) // 3 newlines + 1

    let l0Bytes = buffer.byteRange(forLine: 0)
    XCTAssertNotNil(l0Bytes)
    XCTAssertEqual(String(data: buffer.bytes(in: l0Bytes!), encoding: .utf8), "Line 0\n")

    let l1Bytes = buffer.byteRange(forLine: 1)
    XCTAssertNotNil(l1Bytes)
    XCTAssertEqual(String(data: buffer.bytes(in: l1Bytes!), encoding: .utf8), "Line 1\n")

    XCTAssertEqual(buffer.line(containing: 0), 0)
    // "Line 0" is 6 bytes + 1 newline = 7. Offset 7 is 'L' of "Line 1"
    XCTAssertEqual(buffer.line(containing: 7), 1)
    XCTAssertEqual(buffer.line(containing: buffer.byteLength - 1), 2)
}

func testColumnSelection() {
    let text = """
    ColA ColC ColE
    ColB ColD ColF
    """
    let buffer = PieceChainBuffer(data: Data(text.utf8))

    let sel = ColumnSelection(
        anchor: TextPosition(line: 0, column: 5),
        active: TextPosition(line: 1, column: 9)
    )

    let block = buffer.extractColumnBlock(sel)
    XCTAssertEqual(block.rows.count, 2)
    XCTAssertEqual(String(data: block.rows[0], encoding: .utf8), "ColC")
    XCTAssertEqual(String(data: block.rows[1], encoding: .utf8), "ColD")

    buffer.deleteColumnRange(sel)
    let expectedAfterDelete = """
    ColA  ColE
    ColB  ColF
    """
    XCTAssertEqual(String(data: buffer.allBytes(), encoding: .utf8), expectedAfterDelete)

    // Fill
    let fillSel = ColumnSelection(
        anchor: TextPosition(line: 0, column: 6),
        active: TextPosition(line: 1, column: 6)
    )
    buffer.fillColumn(fillSel, with: "XXX")
    let expectedAfterFill = """
    ColA  XXXColE
    ColB  XXXColF
    """
    XCTAssertEqual(String(data: buffer.allBytes(), encoding: .utf8), expectedAfterFill)
}

@MainActor
func testDocumentStoreSave() {
    let fm = FileManager.default
    let tempURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
    
    // Create new buffer, insert text, and trigger save
    let doc = LocalDocumentBuffer(text: "Initial setup")
    try! doc.save(to: tempURL)
    
    // Check it wrote properly
    let savedData = try! Data(contentsOf: tempURL)
    XCTAssertEqual(String(data: savedData, encoding: .utf8), "Initial setup")
    
    // Open via DocumentStore
    let storeDoc = try! DocumentStore.shared.open(url: tempURL)
    storeDoc.insert(" - Modified", at: storeDoc.buffer.byteLength)
    try! storeDoc.save(to: tempURL)
    
    // Check chunked save worked correctly and atomically replaced
    let updatedData = try! Data(contentsOf: tempURL)
    XCTAssertEqual(String(data: updatedData, encoding: .utf8), "Initial setup - Modified")
    
    // Cleanup
    try? fm.removeItem(at: tempURL)
}

func testSearchAndReplace() async {
    let text = "The quick brown fox jumps over the lazy dog.\nThe quick red fox jumps high."
    let buffer = PieceChainBuffer(data: Data(text.utf8))
    let search = DefaultSearchService()
    
    // Find all "quick .* fox"
    let matches = try! await search.findAll(pattern: "quick (.*?) fox", options: [.regex], in: buffer)
    XCTAssertEqual(matches.count, 2)
    XCTAssertEqual(matches[0].lineRange, 0..<1)
    XCTAssertEqual(matches[1].lineRange, 1..<2)
    
    // Replace all with "slow $1 turtle"
    let replaced = try! await search.replaceAll(matches: matches, template: "slow $1 turtle", in: buffer)
    XCTAssertEqual(replaced, 2)
    
    let expected = "The slow brown turtle jumps over the lazy dog.\nThe slow red turtle jumps high."
    XCTAssertEqual(String(data: buffer.allBytes(), encoding: .utf8), expected)
}

await runTests()
