import AppKit
import SwiftUI
import XCTest
@testable import Nook

// MARK: - Pure logic

final class FileDropLogicTests: XCTestCase {
    private func pasteboard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("nook-drop-test-" + UUID().uuidString)) }

    func testOnlyFilesAndFoldersAreTakenFromADrag() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook drop \(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("informe final.pdf")
        try Data("x".utf8).write(to: file)

        let board = pasteboard(); defer { board.releaseGlobally() }
        board.clearContents(); board.writeObjects([file as NSURL, folder as NSURL])
        XCTAssertEqual(FileDrop.urls(from: board).map(\.path), [file.path, folder.path], "Files and folders, in the order dragged, exact paths.")

        // The same file twice (a drag can list one item through two flavors) is one path.
        board.clearContents(); board.writeObjects([file as NSURL, file as NSURL])
        XCTAssertEqual(FileDrop.urls(from: board).count, 1)

        // A file reference URL stands for its path.
        let reference = try XCTUnwrap((file as NSURL).fileReferenceURL())
        board.clearContents(); board.writeObjects([reference as NSURL])
        let resolved = try XCTUnwrap(FileDrop.urls(from: board).first)
        XCTAssertFalse(resolved.path.hasPrefix("/.file"))
        XCTAssertEqual(resolved.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)

        board.clearContents(); board.writeObjects([URL(string: "https://example.com/foto.png")! as NSURL])
        XCTAssertEqual(FileDrop.urls(from: board), [], "A web address is not a file.")
        board.clearContents(); board.setString("/Users/me/algo.txt", forType: .string)
        XCTAssertEqual(FileDrop.urls(from: board), [], "Plain text that looks like a path is still text.")
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.systemMint.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        board.clearContents(); board.writeObjects([image])
        XCTAssertEqual(FileDrop.urls(from: board), [], "An image with no file behind it has no path.")
        board.clearContents(); board.writeObjects([URL(string: "https://example.com")! as NSURL, file as NSURL])
        XCTAssertEqual(FileDrop.urls(from: board).map(\.path), [file.path], "Of a mixed drag only the files count.")
    }

    func testTheOperationIsACopyWheneverTheSourceAllowsIt() {
        XCTAssertEqual(FileDrop.operation(for: [.copy, .move, .link, .generic]), .copy)
        XCTAssertEqual(FileDrop.operation(for: .every), .copy)
        XCTAssertEqual(FileDrop.operation(for: [.generic, .link]), .generic)
        XCTAssertEqual(FileDrop.operation(for: .link), .link)
        XCTAssertEqual(FileDrop.operation(for: .move), [], "A source that only moves its files is not asking for a path.")
        XCTAssertEqual(FileDrop.operation(for: []), [])
    }

    func testThePathLandsAfterTheSelectionAndNeverReplacesIt() {
        XCTAssertNil(DropPlacement.location(selection: nil, length: 10), "No field being edited: the end.")
        XCTAssertNil(DropPlacement.location(selection: NSRange(location: NSNotFound, length: 0), length: 10))
        XCTAssertEqual(DropPlacement.location(selection: NSRange(location: 4, length: 0), length: 10), 4, "A cursor is where it is.")
        XCTAssertEqual(DropPlacement.location(selection: NSRange(location: 4, length: 3), length: 10), 7, "A selection is kept: the path goes after it.")
        XCTAssertEqual(DropPlacement.location(selection: NSRange(location: 8, length: 9), length: 10), 10, "A stale range never points past the text.")

        let path = "/Users/me/informe.pdf"
        // The edit is the same text DroppedPaths.insert makes, expressed as one insertion for the field editor.
        for (draft, selection) in [("", NSRange(location: 0, length: 0)), ("evalúa este archivo", NSRange(location: 19, length: 0)), ("revisa  y dime", NSRange(location: 7, length: 0)),
                                   ("revisa esto ahora", NSRange(location: 7, length: 4)), ("mira😀", NSRange(location: 6, length: 0)), ("hola", NSRange(location: NSNotFound, length: 0))] {
            let edit = DropPlacement.replacement(of: path, in: draft, selection: selection)
            let applied = (draft as NSString).replacingCharacters(in: edit.range, with: edit.piece)
            let at = DropPlacement.location(selection: selection, length: (draft as NSString).length)
            XCTAssertEqual(applied, DroppedPaths.insert(path, into: draft, at: at).text, draft)
            XCTAssertEqual(edit.range.length, 0, "An insertion, never a replacement.")
            XCTAssertEqual(edit.cursor, edit.range.location + (edit.piece as NSString).length, "The cursor follows the path.")
        }
        XCTAssertEqual(DropPlacement.replacement(of: path, in: "revisa  y dime", selection: NSRange(location: 7, length: 0)).piece, path, "Spaces that are already there are reused.")
        XCTAssertEqual(DropPlacement.replacement(of: path, in: "", selection: nil).piece, path + " ", "A space after, to keep writing.")
    }

    func testAPathFirstDraftIsNotACommand() {
        // A path starts with "/", like a command; with the space after it the "/" menu never opens for it.
        for path in ["/Applications", "/Users/me/informe.pdf", "\"/Users/me/New project\""] {
            let draft = DroppedPaths.insert(path, into: "").text
            XCTAssertNil(SlashCatalog.query(in: draft), draft)
        }
    }

    func testTheOpenDelayRunsFromWhenTheDragReachedTheNotch() {
        var hover = FileDragHover()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertFalse(hover.shouldOpen(now: t0))
        hover.enter(.notch, files: 1, now: t0)
        XCTAssertFalse(hover.shouldOpen(now: t0.addingTimeInterval(0.1)), "A drag passing by does not open the island.")
        XCTAssertTrue(hover.shouldOpen(now: t0.addingTimeInterval(FileDragHover.openDelay)))
        // Entering again from the same place (a second event for the same hover) does not restart the wait.
        hover.enter(.notch, files: 1, now: t0.addingTimeInterval(0.2))
        XCTAssertTrue(hover.shouldOpen(now: t0.addingTimeInterval(0.31)))
        hover.exit(.notch)
        XCTAssertNil(hover.place)
        XCTAssertFalse(hover.shouldOpen(now: t0.addingTimeInterval(5)), "Gone from the notch: nothing to open.")
    }

    func testTheIslandIsHeldOnlyWhileTheDragIsOverItWithTheButtonDown() {
        var hover = FileDragHover()
        let t0 = Date()
        hover.enter(.island, files: 2, now: t0)
        XCTAssertTrue(hover.holdsIsland(buttonDown: true))
        XCTAssertFalse(hover.holdsIsland(buttonDown: false), "A drag that ended without telling us holds nothing.")
        XCTAssertFalse(hover.shouldOpen(now: t0.addingTimeInterval(5)), "Over the open island there is nothing to open.")
        hover.exit(.island)
        XCTAssertFalse(hover.holdsIsland(buttonDown: true))
        XCTAssertEqual(hover.files, 0)
    }

    func testAHandOverBetweenWindowsKeepsTheNewPlaceWhateverTheOrderOfEvents() {
        var hover = FileDragHover()
        let t0 = Date()
        hover.enter(.notch, files: 1, now: t0)
        // The island's window reports the drag before the notch's window reports it gone.
        hover.enter(.island, files: 1, now: t0.addingTimeInterval(0.4))
        hover.exit(.notch)
        XCTAssertEqual(hover.place, .island, "Leaving a place the drag is no longer in changes nothing.")
        hover.exit(.island)
        hover.exit(.island)
        XCTAssertNil(hover.place)
    }
}

// MARK: - Through real windows and views

/// A drag as AppKit hands it to a destination view, with the pasteboard and where in the window it is.
final class StubDraggingInfo: NSObject, NSDraggingInfo {
    weak var window: NSWindow?
    var location: NSPoint
    let pasteboard: NSPasteboard
    var sourceMask: NSDragOperation
    init(window: NSWindow?, location: NSPoint = .zero, pasteboard: NSPasteboard, sourceMask: NSDragOperation = [.copy, .generic, .link, .move]) {
        self.window = window; self.location = location; self.pasteboard = pasteboard; self.sourceMask = sourceMask
    }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { sourceMask }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// The island's own assembly (its container, the panel's SwiftUI content and the drop view above it) in an offscreen
/// window, with a drag simulated the way AppKit delivers one. Nothing here starts the app or touches Terminal: the
/// session is an owned one whose process is `true`.
@MainActor
final class FileDropRig {
    let model = AppModel(receivesSignals: false)
    let session: TerminalSession
    let window: NotchPanel
    let island = IslandView()
    let host: NSHostingView<AnyView>
    let drop = FileDropView()
    let coordinator: FileDropCoordinator
    var expandCalls = 0, focusCalls = 0
    var expanded = true
    private var boards: [NSPasteboard] = []
    static let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))

    static func makeSession(_ kind: SessionKind) -> TerminalSession {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-drop-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-drop-" + UUID().uuidString.prefix(6), name: kind.title, kind: kind, directory: NSTemporaryDirectory(), socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        session.isRunning = true
        return session
    }

    /// `draft` is what the composer holds when the island opens; `focused` puts the keyboard in the field first, as
    /// when the user was typing there.
    init(kind: SessionKind = .claude, session external: TerminalSession? = nil, draft: String = "", focused: Bool = true, key: Bool = true) throws {
        session = external ?? Self.makeSession(kind)
        session.draft = draft
        model.sessions = [session]; model.selectedID = session.id
        // Not `model.expanded`: that would read the real prompt history of this Mac.
        model.islandContentVisible = true
        host = NSHostingView(rootView: AnyView(NookPanel(model: model).environment(\.nookTintedGlass, false)))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        // Far off every screen: the window never shows, and a window that is not key still takes events.
        // The island's own kind of window: a panel that can be key without activating the app.
        window = NotchPanel(contentRect: NSRect(x: -30000, y: -30000, width: Self.size.width, height: Self.size.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = island
        island.frame = NSRect(origin: .zero, size: Self.size)
        host.frame = island.bounds
        island.addSubview(host)
        drop.frame = island.bounds; drop.autoresizingMask = [.width, .height]
        island.addSubview(drop)
        island.layoutSubtreeIfNeeded()
        island.reveal(island.bounds, radius: 22, duration: 0) {}
        coordinator = FileDropCoordinator(model: model, isExpanded: { true }, expand: {}, focus: {}, window: { nil })
        coordinator.isExpanded = { [unowned self] in expanded }
        coordinator.expand = { [unowned self] in expandCalls += 1; expanded = true }
        coordinator.focus = { [unowned self] in focusCalls += 1; window.makeKeyAndOrderFront(nil) }
        coordinator.window = { [unowned self] in window }
        coordinator.attach(drop, place: .island)
        // The island is not the key window while the user works in another app; the drop brings it forward.
        if key { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
        Self.settle(0.5)
        if focused {
            let field = try XCTUnwrap(Self.find(ComposerTextView.self, in: host))
            window.makeFirstResponder(field)
            Self.settle(0.3)
            XCTAssertNotNil(ComposerEditor.active(in: window), "The composer's field is being edited.")
        }
    }
    deinit { boards.forEach { $0.releaseGlobally() } }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }
    static func settle(_ seconds: TimeInterval = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    var editor: NSTextView? { ComposerEditor.active(in: window) }
    var draft: String { session.draft }

    /// What the user types into the field.
    func type(_ text: String) {
        let field = editor!
        field.insertText(text, replacementRange: field.selectedRange())
        Self.settle()
    }
    func select(_ range: NSRange) { editor!.setSelectedRange(range); Self.settle(0.05) }

    func board(_ objects: [NSPasteboardWriting]) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("nook-drop-rig-" + UUID().uuidString))
        board.clearContents(); board.writeObjects(objects)
        boards.append(board)
        return board
    }
    func info(_ board: NSPasteboard, at point: NSPoint = NSPoint(x: 280, y: 40)) -> StubDraggingInfo { StubDraggingInfo(window: window, location: point, pasteboard: board) }

    /// A whole drag: entering, moving a little over the island and letting go.
    @discardableResult
    func dragAndDrop(_ urls: [URL], at point: NSPoint = NSPoint(x: 280, y: 40)) -> Bool {
        let dragging = info(board(urls.map { $0 as NSURL }), at: point)
        _ = drop.draggingEntered(dragging)
        _ = drop.draggingUpdated(dragging)
        let performed = drop.prepareForDragOperation(dragging) && drop.performDragOperation(dragging)
        drop.concludeDragOperation(dragging)
        drop.draggingEnded(dragging)
        Self.settle(0.4)
        return performed
    }

    /// Which view AppKit would give a drag to at `point` (window coordinates), asked of the window itself.
    func dragTarget(at point: NSPoint, board: NSPasteboard) throws -> NSView? {
        let selector = NSSelectorFromString("_findDragTargetFrom:")
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { throw XCTSkip("This AppKit has no drag target lookup to ask.") }
        typealias Lookup = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        let lookup = unsafeBitCast(method_getImplementation(method), to: Lookup.self)
        return lookup(window, selector, info(board, at: point)) as? NSView
    }

    func click(x: CGFloat, fromTop y: CGFloat) {
        let point = NSPoint(x: x, y: window.contentView!.bounds.height - y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        Self.settle()
    }

    func snapshot(to path: String) throws {
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}

@MainActor
final class FileDropFlowTests: XCTestCase {
    private let report = URL(fileURLWithPath: "/Users/me/Documents/informe.pdf")
    private let folder = URL(fileURLWithPath: "/Users/me/Documents/New project", isDirectory: true)

    func testThePathGoesWhereTheCursorIsAndUndoTakesItBack() throws {
        let rig = try FileDropRig()
        rig.type("revisa  y dime")
        rig.select(NSRange(location: 7, length: 0))
        XCTAssertTrue(rig.dragAndDrop([report]))
        XCTAssertEqual(rig.draft, "revisa /Users/me/Documents/informe.pdf y dime", "Dropped in the field, at the text cursor.")
        XCTAssertEqual(rig.editor?.string, rig.draft, "The field shows it.")
        XCTAssertEqual(rig.editor?.selectedRange(), NSRange(location: 7 + "/Users/me/Documents/informe.pdf".count, length: 0), "The cursor sits right after the path.")
        XCTAssertTrue(rig.session.sentHistory.isEmpty, "Nothing is sent.")
        XCTAssertEqual(rig.focusCalls, 1, "The island comes forward to type in.")

        // It went in through the field editor, so it is one step of undo like anything typed. (What the field shows is
        // what is checked: SwiftUI's own field editor does not report an undo to the binding for any edit, typed or dropped.)
        let editor = try XCTUnwrap(rig.editor)
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(editor.string, "revisa  y dime", "Undo removes the path and nothing else.")
        undo.redo()
        XCTAssertEqual(editor.string, "revisa /Users/me/Documents/informe.pdf y dime", "And redo brings it back.")
    }

    func testANonEmptySelectionIsKeptAndThePathGoesAfterIt() throws {
        let rig = try FileDropRig()
        rig.type("evalúa este archivo")
        rig.select(NSRange(location: 7, length: 4))   // "este"
        rig.dragAndDrop([report])
        XCTAssertEqual(rig.draft, "evalúa este /Users/me/Documents/informe.pdf archivo", "What was selected stays; the path follows it.")
    }

    func testWithTheFieldNotBeingEditedThePathIsAppendedAndTheCursorLeftAfterIt() throws {
        let rig = try FileDropRig(draft: "evalúa este archivo", focused: false)
        XCTAssertNil(rig.editor, "No field is being edited.")
        XCTAssertTrue(rig.dragAndDrop([report]))
        XCTAssertEqual(rig.draft, "evalúa este archivo /Users/me/Documents/informe.pdf ")
        let editor = try XCTUnwrap(rig.editor, "The field took the keyboard.")
        XCTAssertEqual(editor.string, rig.draft)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: (rig.draft as NSString).length, length: 0), "The cursor is after the path, not on a selection of everything.")
        // Typing continues from there.
        rig.type("y dime qué falta")
        XCTAssertEqual(rig.draft, "evalúa este archivo /Users/me/Documents/informe.pdf y dime qué falta")
    }

    func testAnIslandThatIsNotTheKeyWindowTakesTheKeyboardWithTheDrop() throws {
        // The user was in Finder: the island is open (a hover opened it) but another app has the keyboard.
        let rig = try FileDropRig(draft: "evalúa este archivo", focused: false, key: false)
        rig.window.resignKey()
        XCTAssertFalse(rig.window.isKeyWindow)
        XCTAssertTrue(rig.dragAndDrop([report]))
        XCTAssertEqual(rig.focusCalls, 1)
        XCTAssertTrue(rig.window.isKeyWindow, "Dropping is how the user chose to work in the island: it takes the keyboard.")
        XCTAssertEqual(rig.draft, "evalúa este archivo /Users/me/Documents/informe.pdf ")
        let editor = try XCTUnwrap(rig.editor, "The field is being edited, with the cursor after the path.")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: (rig.draft as NSString).length, length: 0))
    }

    func testAnEmptyDraftTakesThePathWithoutOpeningTheCommandMenu() throws {
        let rig = try FileDropRig()
        rig.dragAndDrop([URL(fileURLWithPath: "/Applications")])
        XCTAssertEqual(rig.draft, "/Applications ")
        XCTAssertTrue(rig.model.completions(for: rig.session, draft: rig.draft).isEmpty)
    }

    func testSeveralFilesAndFoldersAndTheQuotingOfEachKindOfTab() throws {
        let agent = try FileDropRig(kind: .claude)
        agent.dragAndDrop([report, folder])
        XCTAssertEqual(agent.draft, "/Users/me/Documents/informe.pdf \"/Users/me/Documents/New project\" ", "An agent reads the paths as text: quotes only where spaces need them.")

        let shell = try FileDropRig(kind: .shell)
        shell.dragAndDrop([report, folder])
        XCTAssertEqual(shell.draft, "/Users/me/Documents/informe.pdf '/Users/me/Documents/New project' ", "A plain shell gets them quoted for the command line.")
    }

    func testDragsWithoutFilesAreNotTaken() throws {
        let rig = try FileDropRig()
        rig.type("hola")
        for objects in [[NSString(string: "texto suelto")], [URL(string: "https://example.com/foto.png")! as NSURL]] as [[NSPasteboardWriting]] {
            let dragging = rig.info(rig.board(objects))
            XCTAssertEqual(rig.drop.draggingEntered(dragging), [], "No pointer badge, no drop.")
            XCTAssertEqual(rig.model.fileDrop.files, 0, "No feedback either.")
            XCTAssertFalse(rig.drop.prepareForDragOperation(dragging))
            XCTAssertFalse(rig.drop.performDragOperation(dragging))
        }
        XCTAssertEqual(rig.draft, "hola")
        XCTAssertEqual(rig.focusCalls, 0)
    }

    func testTheFeedbackFollowsTheDragAndEndsWithEveryWayItCanEnd() throws {
        let rig = try FileDropRig()
        let board = rig.board([report as NSURL, folder as NSURL])
        let dragging = rig.info(board)
        XCTAssertEqual(rig.drop.draggingEntered(dragging), .copy)
        XCTAssertEqual(rig.model.fileDrop.files, 2, "Two files over the island.")
        XCTAssertEqual(rig.coordinator.hover.place, .island)
        XCTAssertEqual(rig.drop.draggingUpdated(dragging), .copy)
        rig.drop.draggingExited(dragging)
        XCTAssertEqual(rig.model.fileDrop.files, 0, "Gone on leaving.")
        XCTAssertNil(rig.coordinator.hover.place)

        XCTAssertEqual(rig.drop.draggingEntered(dragging), .copy)
        rig.drop.draggingEnded(dragging)   // cancelled over the island
        XCTAssertEqual(rig.model.fileDrop.files, 0, "Gone when the drag is cancelled.")

        XCTAssertEqual(rig.drop.draggingEntered(dragging), .copy)
        XCTAssertTrue(rig.drop.performDragOperation(dragging))
        XCTAssertEqual(rig.model.fileDrop.files, 0, "Gone on dropping.")
        XCTAssertEqual(rig.drop.draggingEntered(rig.info(rig.board([report as NSURL]))), .copy)
        rig.coordinator.reset()
        XCTAssertEqual(rig.model.fileDrop.files, 0, "Gone when the island closes under the drag.")
    }

    func testNothingIsTakenWithoutATabOrWhileTheConnectionSheetCoversTheComposer() throws {
        let rig = try FileDropRig()
        rig.model.connectionSheet = true
        XCTAssertEqual(rig.drop.draggingEntered(rig.info(rig.board([report as NSURL]))), [])
        XCTAssertFalse(rig.dragAndDrop([report]))
        rig.model.connectionSheet = false
        rig.model.selectedID = nil
        XCTAssertEqual(rig.drop.draggingEntered(rig.info(rig.board([report as NSURL]))), [], "No tab to write into.")
        XCTAssertFalse(rig.dragAndDrop([report]))
        XCTAssertEqual(rig.session.draft, "")
        XCTAssertEqual(rig.model.fileDrop.files, 0)
    }

    func testTheDropViewIsAheadOfTheFieldForDragsAndInvisibleToClicks() throws {
        let rig = try FileDropRig()
        let files = rig.board([report as NSURL])
        // Anywhere on the island: the composer's field, the header and the tab row. Window coordinates start at the bottom.
        for (name, point) in [("composer", NSPoint(x: 120, y: 40)), ("tab row", NSPoint(x: 120, y: 262 - 45)), ("header", NSPoint(x: 120, y: 262 - 10))] {
            XCTAssertTrue(try rig.dragTarget(at: point, board: files) === rig.drop, "A file drag over the \(name) goes to the drop view, not to the text field under it.")
        }
        // A text drag has no business with it, so the field and the rest take it as they always did.
        let text = rig.board([NSString(string: "hola")])
        XCTAssertFalse(try rig.dragTarget(at: NSPoint(x: 120, y: 40), board: text) === rig.drop)

        // Clicks pass through it: a click in the composer's row puts the keyboard in the field.
        rig.window.makeFirstResponder(nil)
        FileDropRig.settle(0.1)
        XCTAssertNil(rig.editor)
        rig.click(x: 200, fromTop: 262 - 9 - 66 + 20)
        XCTAssertNotNil(rig.editor, "The click reached the composer through the drop view.")
    }

    func testAQuestionCardKeepsThePathsInTheDraftForWhenTheComposerReturns() throws {
        let model = AppModel(receivesSignals: false)
        let permission = ["⏺ Bash(rm -rf build)", "", " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again", "   3. No, and tell Claude what to do differently (esc)"].joined(separator: "\n")
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys098", customTitle: "claude", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: permission)
        let external = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        XCTAssertNotNil(external.prompt)
        let rig = try FileDropRig(session: external, draft: "mira esto", focused: false)
        XCTAssertNil(ComposerEditor.active(in: rig.window), "The card stands where the field was.")
        XCTAssertTrue(rig.dragAndDrop([report]))
        XCTAssertEqual(rig.draft, "mira esto /Users/me/Documents/informe.pdf ", "The paths are in the draft that comes back with the composer.")
        XCTAssertEqual(rig.focusCalls, 1)
    }

    /// Opt-in, like `PanelRenderTests`: the island after real drops (through the drop view, the coordinator and the composer).
    func testRenderTheIslandAfterDrops() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the island after a drop.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        func path(_ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }
        let informe = URL(fileURLWithPath: "/Users/me/Documents/Informe trimestral.pdf")
        let imagen = URL(fileURLWithPath: "/Users/me/Desktop/Captura de pantalla.png")

        // The field was not being edited: the path is appended and the cursor is left after it.
        let appended = try FileDropRig(draft: "evalúa este archivo", focused: false)
        appended.dragAndDrop([informe])
        try appended.snapshot(to: path("flow-appended.png"))

        // The user was typing in the middle of the message.
        let middle = try FileDropRig(focused: true)
        middle.type("compara  con lo de ayer")
        middle.select(NSRange(location: 8, length: 0))
        middle.dragAndDrop([informe, imagen])
        try middle.snapshot(to: path("flow-middle.png"))

        // A question's card stands in the composer's place.
        let model = AppModel(receivesSignals: false)
        let permission = ["⏺ Bash(rm -rf build)", "", " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again", "   3. No, and tell Claude what to do differently (esc)"].joined(separator: "\n")
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys097", customTitle: "claude", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: permission)
        let card = try FileDropRig(session: TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge), focused: false)
        card.dragAndDrop([informe])
        try card.snapshot(to: path("flow-card-note.png"))

        // Mid-drag over the real island: the feedback as the drop view's own events produce it.
        let hovering = try FileDropRig(draft: "evalúa este archivo", focused: false)
        let dragging = hovering.info(hovering.board([informe as NSURL]))
        _ = hovering.drop.draggingEntered(dragging)
        FileDropRig.settle(0.3)
        try hovering.snapshot(to: path("flow-hover.png"))
        hovering.drop.draggingExited(dragging)
    }

    func testDroppingWhileTheIslandIsClosedOpensItAndStillDelivers() throws {
        let rig = try FileDropRig(draft: "hola")
        rig.expanded = false
        // From the notch the island opens first, then the paths go in.
        let notch = FileDropView()
        rig.coordinator.attach(notch, place: .notch)
        let dragging = rig.info(rig.board([report as NSURL]))
        XCTAssertEqual(notch.draggingEntered(dragging), .copy)
        XCTAssertEqual(rig.model.fileDrop.files, 0, "No composer feedback on the notch: the island is still closed.")
        XCTAssertTrue(notch.performDragOperation(dragging))
        XCTAssertEqual(rig.expandCalls, 0, "AppKit's drop returns first; the island opens on the next turn.")
        FileDropRig.settle(0.4)
        XCTAssertEqual(rig.expandCalls, 1)
        XCTAssertEqual(rig.draft, "hola /Users/me/Documents/informe.pdf ")
    }
}

// MARK: - The collapsed notch

@MainActor
final class FileDropNotchTests: XCTestCase {
    private let report = URL(fileURLWithPath: "/Users/me/Documents/informe.pdf")

    @MainActor private final class Rig {
        let model = AppModel(receivesSignals: false)
        let coordinator: FileDropCoordinator
        let window: NSWindow
        let pet = PetView(frame: .zero)
        var expands = 0
        var expanded = false
        let board = NSPasteboard(name: NSPasteboard.Name("nook-notch-" + UUID().uuidString))

        init() {
            let session = FileDropRig.makeSession(.claude)
            model.sessions = [session]; model.selectedID = session.id
            coordinator = FileDropCoordinator(model: model, isExpanded: { false }, expand: {}, focus: {}, window: { nil })
            window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = pet
            pet.frame = NSRect(x: 0, y: 0, width: 240, height: 32)
            coordinator.isExpanded = { [unowned self] in expanded }
            coordinator.expand = { [unowned self] in expands += 1; expanded = true }
            coordinator.openDelay = 0.08
            coordinator.attach(pet.fileDrop, place: .notch)
            board.clearContents(); board.writeObjects([URL(fileURLWithPath: "/Users/me/informe.pdf") as NSURL])
        }
        deinit { board.releaseGlobally() }
        var dragging: StubDraggingInfo { StubDraggingInfo(window: window, location: NSPoint(x: 100, y: 16), pasteboard: board) }
    }

    func testTheDropViewCoversTheCollapsedNotchAndLetsClicksThrough() {
        let rig = Rig()
        XCTAssertEqual(rig.pet.fileDrop.frame, rig.pet.bounds, "It follows the collapsed island's size.")
        rig.pet.frame = NSRect(x: 0, y: 0, width: 300, height: 32)
        XCTAssertEqual(rig.pet.fileDrop.frame, rig.pet.bounds)
        XCTAssertTrue(rig.pet.subviews.last === rig.pet.fileDrop, "Front-most, so a file drag finds it first.")
        XCTAssertTrue(rig.pet.hitTest(NSPoint(x: 100, y: 16)) === rig.pet, "The cat's own clicks and drag are untouched.")
    }

    func testTheIslandsDropViewFollowsTheWindowThatIsSizedAfterItsContentIsAdded() {
        // The controller builds the island with no size and sizes its window afterwards; the drop view has to end up covering all of it.
        let island = IslandView()
        let content = NSView()
        content.autoresizingMask = [.width, .height]
        island.addSubview(content)
        let drop = FileDropView()
        drop.frame = island.bounds
        drop.autoresizingMask = [.width, .height]
        island.addSubview(drop)
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = island
        panel.setFrame(NSRect(x: -30000, y: -30000, width: 572, height: 262), display: false)
        island.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.frame, island.bounds, "How the SwiftUI content already follows the window.")
        XCTAssertEqual(drop.frame, island.bounds, "The drop view covers the whole island, so a drop anywhere on it counts.")
        XCTAssertEqual(island.subviews.last, drop)
    }

    func testAFileDragRestingOnTheNotchOpensTheIslandOnceWithoutTakingTheKeyboard() {
        let rig = Rig()
        XCTAssertEqual(rig.pet.fileDrop.draggingEntered(rig.dragging), .copy)
        FileDropRig.settle(0.03)
        XCTAssertEqual(rig.expands, 0, "Not yet: a drag passing by does not open it.")
        FileDropRig.settle(0.2)
        XCTAssertEqual(rig.expands, 1)
        XCTAssertEqual(rig.model.fileDrop.files, 0, "The feedback belongs to the open island's composer.")
        FileDropRig.settle(0.2)
        XCTAssertEqual(rig.expands, 1, "Only once.")
    }

    func testAFileDragThatLeavesTheNotchBeforeTheDelayOpensNothing() {
        let rig = Rig()
        let dragging = rig.dragging
        _ = rig.pet.fileDrop.draggingEntered(dragging)
        FileDropRig.settle(0.03)
        rig.pet.fileDrop.draggingExited(dragging)
        FileDropRig.settle(0.2)
        XCTAssertEqual(rig.expands, 0)
        XCTAssertNil(rig.coordinator.hover.place)

        // And a cancelled drag (no exit, only its end) opens nothing either.
        _ = rig.pet.fileDrop.draggingEntered(dragging)
        rig.pet.fileDrop.draggingEnded(dragging)
        FileDropRig.settle(0.2)
        XCTAssertEqual(rig.expands, 0)
    }

    func testTheNotchTakesNoDragWithoutATab() {
        let rig = Rig()
        rig.model.selectedID = nil
        XCTAssertEqual(rig.pet.fileDrop.draggingEntered(rig.dragging), [], "Nothing to write into: no badge and no opening.")
        FileDropRig.settle(0.2)
        XCTAssertEqual(rig.expands, 0)
    }

    func testTheOpenIslandHoldsAStaleDragOnlyWhileTheButtonIsDown() {
        let rig = Rig()
        rig.expanded = true
        _ = rig.coordinator.entered(.island, files: 1)
        // Whatever the real button state is, a drag that is over cannot hold the island once the button is up.
        XCTAssertEqual(rig.coordinator.holdsIsland, NSEvent.pressedMouseButtons & 1 != 0)
        rig.coordinator.reset()
        XCTAssertFalse(rig.coordinator.holdsIsland)
    }
}
