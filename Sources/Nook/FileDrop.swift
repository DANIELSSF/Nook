import AppKit
import Combine

// Files, folders and images dragged onto the island: their exact paths go into the selected tab's message, the way
// Terminal writes a dropped file's path. `DroppedPaths` formats the paths; this file is how a drag reaches the composer.
//
//   FileDropView         a transparent AppKit view on top of the island (and of the collapsed one) that takes file drags
//   FileDropCoordinator  what a drag means: open the collapsed island, hold it open, hand the paths to the composer
//   FileDragHover        where the drag is and for how long (the timing, with no timers of its own)
//   FileDropState        what the SwiftUI feedback reads while a drag is over the island
//   DropPlacement        where in the draft the paths land
//
// Nothing is ever sent: the paths only enter the draft.

/// What the island shows while files are dragged over it. A separate object so that a drag redraws only the feedback
/// and not the whole panel.
final class FileDropState: ObservableObject {
    /// How many files and folders are being dragged over the island; 0 when no drag is.
    @Published var files = 0
}

enum FileDrop {
    /// The files and folders on a pasteboard, in order, as plain path URLs. A web URL, text or an image without a file
    /// behind it gives nothing, so such drags are never taken.
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        let found = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        var seen = Set<String>()
        return found.compactMap { url -> URL? in
            // A file reference URL (file:///.file/id=…) is turned into the path it stands for.
            let resolved = (url as NSURL).filePathURL ?? url
            return seen.insert(resolved.path).inserted ? resolved : nil
        }
    }

    /// What the drop does as far as the dragged files are concerned: the paths are copied into the message. The plus
    /// badge on the pointer says so; a source that allows no copy gets the closest thing it allows.
    static func operation(for mask: NSDragOperation) -> NSDragOperation {
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        if mask.contains(.link) { return .link }
        return []
    }
}

/// Where in the draft dropped paths land.
enum DropPlacement {
    /// After the text selected in the field, or at the end when the field is not being edited. Dropping never replaces
    /// what the user selected.
    static func location(selection: NSRange?, length: Int) -> Int? {
        guard let selection, selection.location != NSNotFound else { return nil }
        return min(max(selection.location + selection.length, 0), length)
    }

    /// The paths as one edit of `draft` (an insertion with the spaces `DroppedPaths.insert` decides on), for the field
    /// editor to apply so the user can undo it like typing, and the cursor that follows them.
    static func replacement(of text: String, in draft: String, selection: NSRange?) -> (range: NSRange, piece: String, cursor: Int) {
        let length = (draft as NSString).length
        let at = location(selection: selection, length: length) ?? length
        let placed = DroppedPaths.insert(text, into: draft, at: at)
        let grown = (placed.text as NSString).length - length
        return (NSRange(location: at, length: 0), (placed.text as NSString).substring(with: NSRange(location: at, length: max(grown, 0))), placed.cursor)
    }
}

/// Where a file drag is, and since when. Pure, so the timing is tested without a screen: the controller feeds it the
/// drag's events and asks it what to do.
struct FileDragHover {
    enum Place { case notch, island }
    /// How long a drag rests over the collapsed notch before the island opens, a little longer than a plain hover so a
    /// drag passing by does not open it.
    static let openDelay: TimeInterval = 0.3

    private(set) var place: Place?
    private(set) var files = 0
    private var since = Date.distantPast

    mutating func enter(_ place: Place, files: Int, now: Date) {
        if self.place != place { since = now }
        self.place = place; self.files = files
    }
    /// The drag left `place`. A drag handed from one window to the next may report the new entry before the old exit, so
    /// leaving a place the drag is no longer in changes nothing.
    mutating func exit(_ place: Place) {
        if self.place == place { end() }
    }
    mutating func end() { place = nil; files = 0; since = .distantPast }

    /// The drag has rested over the collapsed notch long enough to open the island.
    func shouldOpen(now: Date, delay: TimeInterval = openDelay) -> Bool {
        place == .notch && now.timeIntervalSince(since) >= delay - 0.001
    }
    /// A drag with the button still down over the open island keeps it open, like the pin.
    func holdsIsland(buttonDown: Bool) -> Bool { place == .island && buttonDown }
}

/// The dropped paths on their way to the composer of the tab they were meant for.
struct FileDropRequest {
    let sessionID: String
    /// The paths as they go in the message (already quoted where needed).
    let text: String
    /// The island's window, where the field editor is found.
    weak var window: NSWindow?

    func post() { NotificationCenter.default.post(name: .nookDropFiles, object: self) }
}

extension Notification.Name {
    /// Paths dropped on the island, for the selected tab's composer (`FileDropRequest`).
    static let nookDropFiles = Notification.Name("NookDropFiles")
}

/// The composer's text while it is being edited.
enum ComposerEditor {
    /// The composer's text view while it has the keyboard (the window's first responder). Nil when the field is not being
    /// edited: something else has the keyboard, or the question card stands where the field was.
    static func active(in window: NSWindow?) -> NSTextView? {
        window?.firstResponder as? ComposerTextView
    }

    /// Puts the cursor at `location` once the field shows `text` and is being edited. SwiftUI hands the field its text and
    /// the keyboard on its own schedule (the keyboard request is granted a turn of the run loop later), so this looks
    /// again for a moment (a few frames, only after a drop) and gives up quietly if the text has moved on.
    static func place(cursor location: Int, expecting text: String, in window: NSWindow?, attempts: Int = 12) {
        if let editor = active(in: window), editor.string == text {
            editor.setSelectedRange(NSRange(location: min(location, (text as NSString).length), length: 0))
            return
        }
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak window] in
            place(cursor: location, expecting: text, in: window, attempts: attempts - 1)
        }
    }
}

/// Takes the file drags of the view it covers. Transparent and invisible to the pointer (`hitTest` is nil), so clicks
/// reach what is underneath; AppKit looks for a drag's destination without hit testing, front-most registered view
/// first, so being the last subview is what puts it ahead of the text field and the rest of the island. It registers
/// for file URLs only: a text or web drag is not its business and goes on to the views below as before.
final class FileDropView: NSView {
    /// A drag with files came in. Return whether this place takes it.
    var onEnter: (([URL]) -> Bool)?
    var onExit: (() -> Void)?
    /// The files were dropped. Return whether they were used.
    var onDrop: (([URL]) -> Bool)?
    /// Set while the drag that entered was taken; the rest of the drag's events follow that decision.
    private(set) var accepted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        // Only a drag adds this to the accessibility tree, through the feedback it shows; a transparent element over the
        // whole island would stand in front of everything under it.
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = FileDrop.urls(from: sender.draggingPasteboard)
        accepted = !urls.isEmpty && onEnter?(urls) == true
        return accepted ? FileDrop.operation(for: sender.draggingSourceOperationMask) : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepted ? FileDrop.operation(for: sender.draggingSourceOperationMask) : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { leave() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepted }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = FileDrop.urls(from: sender.draggingPasteboard)
        accepted = false
        return !urls.isEmpty && onDrop?(urls) == true
    }
    /// A drag cancelled over the view ends without a drop.
    override func draggingEnded(_ sender: NSDraggingInfo) { leave() }

    private func leave() {
        guard accepted else { return }
        accepted = false
        onExit?()
    }
}

/// What a file drag does on the island: opens it from the notch, holds it open, and gives the paths to the composer.
/// The controller supplies what only it can do (open the island, bring it forward); the rest is here so it can be tested
/// without a screen.
final class FileDropCoordinator {
    let model: AppModel
    private(set) var hover = FileDragHover()
    /// The island is open (not collapsed or collapsing).
    var isExpanded: () -> Bool
    /// Open the island without taking the keyboard from the app the drag comes from.
    var expand: () -> Void
    /// Bring the island forward to type in, as a click on it does.
    var focus: () -> Void
    var window: () -> NSWindow?
    var now: () -> Date = Date.init
    var openDelay = FileDragHover.openDelay
    private var openWork: DispatchWorkItem?

    init(model: AppModel, isExpanded: @escaping () -> Bool, expand: @escaping () -> Void, focus: @escaping () -> Void, window: @escaping () -> NSWindow?) {
        self.model = model
        self.isExpanded = isExpanded; self.expand = expand; self.focus = focus; self.window = window
    }

    /// Connects a drop view to this coordinator as the island's or the collapsed notch's.
    func attach(_ view: FileDropView, place: FileDragHover.Place) {
        view.onEnter = { [weak self] urls in self?.entered(place, files: urls.count) ?? false }
        view.onExit = { [weak self] in self?.exited(place) }
        view.onDrop = { [weak self] urls in self?.dropped(urls) ?? false }
    }

    /// There has to be a tab to write into, and the connection sheet covers the composer.
    var canReceive: Bool { model.selected != nil && !model.connectionSheet }

    /// True while a drag over the open island should keep it from collapsing.
    var holdsIsland: Bool { hover.place == .island && hover.holdsIsland(buttonDown: NSEvent.pressedMouseButtons & 1 != 0) }

    func entered(_ place: FileDragHover.Place, files: Int) -> Bool {
        guard canReceive else { return false }
        switch place {
        case .island:
            guard isExpanded() else { return false }
            cancelOpen()
            hover.enter(.island, files: files, now: now())
            model.fileDrop.files = files
        case .notch:
            hover.enter(.notch, files: files, now: now())
            scheduleOpen()
        }
        return true
    }

    func exited(_ place: FileDragHover.Place) {
        let was = hover.place
        hover.exit(place)
        guard was == place else { return }
        if place == .notch { cancelOpen() } else { model.fileDrop.files = 0 }
    }

    func dropped(_ urls: [URL]) -> Bool {
        reset()
        guard canReceive, let session = model.selected else { return false }
        // A plain shell gets the paths quoted for the command line; an agent reads them as text.
        let text = DroppedPaths.text(for: urls, shell: !session.drivesAgent)
        guard !text.isEmpty else { return false }
        let sessionID = session.id
        // The drag's own callback returns first: opening a window, taking the keyboard and updating the composer all wait
        // for the next turn of the run loop instead of happening inside AppKit's drop.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.isExpanded() { self.expand() }
            self.focus()
            FileDropRequest(sessionID: sessionID, text: text, window: self.window()).post()
        }
        return true
    }

    /// The drag is over (or the island closed under it): nothing is pending and no feedback shows.
    func reset() {
        hover.end(); cancelOpen()
        if model.fileDrop.files != 0 { model.fileDrop.files = 0 }
    }

    private func scheduleOpen() {
        cancelOpen()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hover.shouldOpen(now: self.now(), delay: self.openDelay), !self.isExpanded() else { return }
            self.expand()
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + openDelay, execute: work)
    }
    private func cancelOpen() { openWork?.cancel(); openWork = nil }
}
