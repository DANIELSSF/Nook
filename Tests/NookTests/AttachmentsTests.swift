import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// A pasted image is a file, shown as a thumbnail in the composer and sent as its path: what each tab holds, the picture of it, and the
/// message that goes out.
@MainActor
final class AttachmentsTests: XCTestCase {
    /// A PNG of `size` points (a gradient, so a thumbnail has something to show), written to a folder of its own.
    static func writeImage(named name: String = "imagen-prueba.png", width: Int = 640, height: Int = 400) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSGradient(colors: [NSColor(red: 0.95, green: 0.55, blue: 0.35, alpha: 1), NSColor(red: 0.25, green: 0.35, blue: 0.85, alpha: 1)])!
            .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 35)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: width / 2 - 70, y: height / 2 - 70, width: 140, height: 140)).fill()
        image.unlockFocus()
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        let url = folder.appendingPathComponent(name)
        try png.write(to: url)
        return url.path
    }

    func testTheMessageIsTheWordsThenThePathsApartBySpaces() {
        XCTAssertEqual(MessageAttachments.message(text: "mira esto", files: ["/tmp/a.png"]), "mira esto /tmp/a.png")
        XCTAssertEqual(MessageAttachments.message(text: "mira", files: ["/tmp/a.png", "/tmp/b.png"]), "mira /tmp/a.png /tmp/b.png")
        XCTAssertEqual(MessageAttachments.message(text: "", files: ["/tmp/a.png"]), "/tmp/a.png", "An image on its own: the agent opens it from the path.")
        XCTAssertEqual(MessageAttachments.message(text: "solo texto", files: []), "solo texto")
        XCTAssertEqual(MessageAttachments.message(text: "dos\nlíneas", files: ["/tmp/a.png"]), "dos\nlíneas /tmp/a.png", "After the last line.")
        XCTAssertEqual(MessageAttachments.message(text: "", files: []), "")
    }

    func testEachTabKeepsItsOwnAttachmentsUntilTheyAreCleared() {
        let store = MessageAttachments()
        XCTAssertEqual(store.paths(for: "a"), [])
        store.set(["/tmp/1.png", "/tmp/2.png"], for: "a")
        store.set(["/tmp/3.png"], for: "b")
        XCTAssertEqual(store.paths(for: "a"), ["/tmp/1.png", "/tmp/2.png"])
        XCTAssertEqual(store.paths(for: "b"), ["/tmp/3.png"])
        store.set([], for: "a")
        XCTAssertEqual(store.paths(for: "a"), [], "A sent message leaves nothing behind.")
        XCTAssertEqual(store.paths(for: "b"), ["/tmp/3.png"])
    }

    func testAThumbnailIsTheFilesPictureAtTheSizeItIsShown() throws {
        let path = try Self.writeImage(width: 1280, height: 800)
        let thumbnail = try XCTUnwrap(AttachmentThumbnail.image(at: path, points: 44))
        XCTAssertLessThanOrEqual(thumbnail.size.width, 44); XCTAssertLessThanOrEqual(thumbnail.size.height, 44)
        XCTAssertEqual(max(thumbnail.size.width, thumbnail.size.height), 44, accuracy: 1, "As large as the chip, sharp on a 2× screen.")
        XCTAssertEqual(thumbnail.size.width / thumbnail.size.height, 1280.0 / 800.0, accuracy: 0.05, "The shape of the picture is kept.")
        XCTAssertTrue(AttachmentThumbnail.image(at: path, points: 44) === thumbnail, "The second look is the first one's, not another reading of the file.")
    }

    func testAFileThatIsGoneOrIsNotAnImageHasNoThumbnail() throws {
        XCTAssertNil(AttachmentThumbnail.image(at: "/tmp/nook-no-such-image-\(UUID().uuidString).png", points: 44))
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("nota-\(UUID().uuidString).txt")
        try "no soy una imagen".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertNil(AttachmentThumbnail.image(at: text.path, points: 44))
    }

    func testTheRowHoldsOneChipAPictureSquare() throws {
        let path = try Self.writeImage()
        let size = NSHostingView(rootView: AttachmentRow(paths: [path]) { _ in }).fittingSize
        XCTAssertEqual(size.height, AttachmentChip.side + 10, "Room above the chips for their remove buttons, which stand half outside. \(size)")
    }
}
