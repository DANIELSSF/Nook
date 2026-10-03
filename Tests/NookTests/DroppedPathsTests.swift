import XCTest
@testable import Nook

final class DroppedPathsTests: XCTestCase {
    private let report = URL(fileURLWithPath: "/Users/me/Documents/informe.pdf")
    private let project = URL(fileURLWithPath: "/Users/me/Documents/New project", isDirectory: true)
    private let quoted = URL(fileURLWithPath: "/tmp/it's \"done\".txt")

    func testAgentsGetThePathAsTextQuotedOnlyWhenItHasSpaces() {
        XCTAssertEqual(DroppedPaths.text(for: [report], shell: false), "/Users/me/Documents/informe.pdf")
        XCTAssertEqual(DroppedPaths.text(for: [project], shell: false), "\"/Users/me/Documents/New project\"", "Exact path, no trailing slash added.")
        XCTAssertEqual(DroppedPaths.text(for: [report, project], shell: false), "/Users/me/Documents/informe.pdf \"/Users/me/Documents/New project\"")
        XCTAssertEqual(DroppedPaths.text(for: [quoted], shell: false), "\"/tmp/it's \\\"done\\\".txt\"")
        XCTAssertEqual(DroppedPaths.text(for: [URL(string: "https://example.com/a.png")!], shell: false), "", "Only files on this Mac.")
    }

    func testAShellGetsPathsItCanUse() {
        XCTAssertEqual(DroppedPaths.text(for: [report], shell: true), "/Users/me/Documents/informe.pdf")
        XCTAssertEqual(DroppedPaths.text(for: [project], shell: true), "'/Users/me/Documents/New project'")
        XCTAssertEqual(DroppedPaths.text(for: [quoted], shell: true), "'/tmp/it'\\''s \"done\".txt'")
    }

    func testThePathGoesWhereTheCursorIsWithSpacesAround() {
        let path = "/Users/me/informe.pdf"
        XCTAssertEqual(DroppedPaths.insert(path, into: "").text, "/Users/me/informe.pdf ")
        let atEnd = DroppedPaths.insert(path, into: "evalúa este archivo")
        XCTAssertEqual(atEnd.text, "evalúa este archivo /Users/me/informe.pdf ")
        XCTAssertEqual(atEnd.cursor, (atEnd.text as NSString).length, "The cursor follows the path, ready to keep writing.")
        let middle = DroppedPaths.insert(path, into: "revisa  y dime", at: 7)
        XCTAssertEqual(middle.text, "revisa /Users/me/informe.pdf y dime", "Existing spaces are reused, never doubled.")
        XCTAssertEqual(DroppedPaths.insert(path, into: "mira😀", at: 6).text, "mira😀 /Users/me/informe.pdf ", "UTF-16 offsets, as the text field reports them.")
        XCTAssertEqual(DroppedPaths.insert("", into: "hola").text, "hola")
    }
}
