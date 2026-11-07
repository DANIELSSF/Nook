import AppKit

// Drawing the area a message's screenshot is (Ajustes → Pantalla → Elegir área…): every display dims, the pointer becomes a crosshair, and a drag on
// one of them draws the area, as ⇧⌘4 does. Letting go keeps it; Esc (or a right click) leaves everything as it was. The area already chosen shows
// from the start, and ↩ keeps it as it is. Nothing is captured here: the windows are only a frame to draw in, over the live screen.
//
//   ScreenAreaGeometry   from a drag in a display's window to a rect in the display's points and back (plain values, for the tests)
//   ScreenAreaPicker     the windows, one per display, and the answer
//   ScreenAreaCanvas     what each window draws, and the drag

// MARK: - Geometry

enum ScreenAreaGeometry {
    /// A drag from `start` to `end` in a view `bounds` large (AppKit's bottom left origin) as a rect in the display's points from its top left
    /// corner (ScreenCaptureKit's), kept inside the display.
    static func displayRect(from start: CGPoint, to end: CGPoint, bounds: CGSize) -> CGRect {
        let view = viewRect(from: start, to: end, bounds: bounds)
        return CGRect(x: view.minX, y: bounds.height - view.maxY, width: view.width, height: view.height)
    }

    /// The drag as a rect in the view, kept inside it.
    static func viewRect(from start: CGPoint, to end: CGPoint, bounds: CGSize) -> CGRect {
        let clamp = { (p: CGPoint) in CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height)) }
        let a = clamp(start), b = clamp(end)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The area as a rect in the view of its display, `bounds` large (bottom left origin).
    static func viewRect(_ area: ScreenArea, bounds: CGSize) -> CGRect {
        let rect = area.rect(in: bounds)
        return CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The display's id as Core Graphics knows it, or nil.
    static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

// MARK: - The picker

/// One display's window: borderless, over everything (the menu bar and the Dock included), and able to take keys for Esc and ↩.
private final class ScreenAreaWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Puts a window over every display to draw the area in, and tells `completion` what was drawn (nil when the user left it as it was). One at a time:
/// asking again while it is up brings it to the front.
final class ScreenAreaPicker {
    private static var current: ScreenAreaPicker?

    /// Whether the windows are up.
    static var isPicking: Bool { current != nil }

    /// Starts drawing. `area` is the one chosen now, shown from the start.
    static func pick(current area: ScreenArea?, completion: @escaping (ScreenArea?) -> Void) {
        precondition(Thread.isMainThread)
        if let current { current.front(); return }
        let picker = ScreenAreaPicker(area: area, completion: completion)
        current = picker
        picker.show()
    }

    private let initial: ScreenArea?
    private let completion: (ScreenArea?) -> Void
    private var windows: [ScreenAreaWindow] = []
    private var watches: [NSObjectProtocol] = []

    private init(area: ScreenArea?, completion: @escaping (ScreenArea?) -> Void) {
        initial = area
        self.completion = completion
    }

    private func show() {
        for screen in NSScreen.screens {
            guard let id = ScreenAreaGeometry.displayID(of: screen) else { continue }
            let window = ScreenAreaWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.animationBehavior = .none
            window.acceptsMouseMovedEvents = true
            let canvas = ScreenAreaCanvas(frame: CGRect(origin: .zero, size: screen.frame.size), display: id, name: screen.localizedName, picker: self)
            if let initial, initial.display == id { canvas.selection = ScreenAreaGeometry.viewRect(initial, bounds: screen.frame.size) }
            window.contentView = canvas
            window.setFrame(screen.frame, display: false)
            windows.append(window)
        }
        guard !windows.isEmpty else { return finish(nil) }
        NSApp.activate(ignoringOtherApps: true)
        for window in windows { window.orderFrontRegardless() }
        front()
        // The displays changed under the windows: they no longer cover what they say. Nothing is kept.
        watches.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.finish(nil)
        })
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "Arrastra sobre la pantalla para elegir el área que llevarán tus mensajes. Escape para cancelar.",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// The window under the pointer takes the keys.
    private func front() {
        let pointer = NSEvent.mouseLocation
        let window = windows.first { $0.frame.contains(pointer) } ?? windows.first
        window?.makeKey()
        if let canvas = window?.contentView { window?.makeFirstResponder(canvas) }
        NSCursor.crosshair.set()
    }

    /// A drag began on `canvas`: whatever the other displays showed is not the area any more.
    fileprivate func began(on canvas: ScreenAreaCanvas) {
        for window in windows {
            guard let other = window.contentView as? ScreenAreaCanvas, other !== canvas, other.selection != nil else { continue }
            other.selection = nil
        }
    }

    /// The answer, once: the windows go, and `completion` hears it.
    fileprivate func finish(_ area: ScreenArea?) {
        guard Self.current === self else { return }
        Self.current = nil
        for watch in watches { NotificationCenter.default.removeObserver(watch) }
        watches.removeAll()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        completion(area)
    }
}

// MARK: - One display

/// The dim over a display, the area cut out of it with its size, and a line that says what to do. The drag happens here.
final class ScreenAreaCanvas: NSView {
    let display: UInt32
    let name: String
    private weak var picker: ScreenAreaPicker?
    private var start: CGPoint?

    /// The area on this display, in the view (bottom left origin), or nil.
    var selection: CGRect? { didSet { needsDisplay = true } }

    fileprivate init(frame: CGRect, display: UInt32, name: String, picker: ScreenAreaPicker?) {
        self.display = display
        self.name = name
        self.picker = picker
        super.init(frame: frame)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }

    // MARK: The drag

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        picker?.began(on: self)
        start = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        selection = ScreenAreaGeometry.viewRect(from: start, to: convert(event.locationInWindow, from: nil), bounds: bounds.size)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        self.start = nil
        let end = convert(event.locationInWindow, from: nil)
        let rect = ScreenAreaGeometry.displayRect(from: start, to: end, bounds: bounds.size)
        // A click, or a drag too small to read anything in, is not an area: the user draws again (or presses Esc).
        guard let area = ScreenArea(display: display, displayName: name, rect: rect, in: bounds.size) else {
            selection = nil
            return
        }
        picker?.finish(area)
    }

    override func rightMouseDown(with event: NSEvent) { picker?.finish(nil) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: picker?.finish(nil)                                   // esc
        case 36, 76:                                                    // ↩, enter
            if start == nil, let selection, let area = ScreenArea(display: display, displayName: name, rect: displayRect(selection), in: bounds.size) {
                picker?.finish(area)
            } else {
                NSSound.beep()
            }
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { picker?.finish(nil) }

    private func displayRect(_ view: CGRect) -> CGRect { CGRect(x: view.minX, y: bounds.height - view.maxY, width: view.width, height: view.height) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()
        if let selection, selection.width > 0, selection.height > 0 {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            let border = NSBezierPath(rect: selection.insetBy(dx: -0.75, dy: -0.75))
            border.lineWidth = 1.5
            NookPalette.mintOnBlack.setStroke()
            border.stroke()
            drawSize(of: selection)
        }
        drawHint()
    }

    /// "820 × 540" under the area's bottom right corner (inside it when there is no room below).
    private func drawSize(of selection: CGRect) {
        let rect = displayRect(selection)
        let text = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        let pill = CGSize(width: size.width + 14, height: size.height + 6)
        var origin = CGPoint(x: selection.maxX - pill.width, y: selection.minY - pill.height - 6)
        if origin.y < 4 { origin.y = selection.minY + 6 }
        origin.x = min(max(4, origin.x), bounds.width - pill.width - 4)
        let frame = CGRect(origin: origin, size: pill)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: frame, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(at: CGPoint(x: frame.minX + 7, y: frame.minY + 3))
    }

    /// What to do, in a pill near the top of the display, under the menu bar.
    private func drawHint() {
        let first = NSAttributedString(string: "Arrastra para elegir el área que llevarán tus mensajes", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let keys = selection != nil && start == nil ? "↩ mantener esta área  ·  esc cancelar" : "esc cancelar"
        let second = NSAttributedString(string: keys, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.66),
        ])
        let a = first.size(), b = second.size()
        let pill = CGSize(width: max(a.width, b.width) + 32, height: a.height + b.height + 20)
        let top = bounds.height - (window?.screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 24) - 18
        let frame = CGRect(x: (bounds.width - pill.width) / 2, y: top - pill.height, width: pill.width, height: pill.height)
        // Out of the way of an area drawn under it.
        if let selection, selection.intersects(frame.insetBy(dx: -8, dy: -8)) { return }
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).fill()
        first.draw(at: CGPoint(x: frame.midX - a.width / 2, y: frame.maxY - 10 - a.height))
        second.draw(at: CGPoint(x: frame.midX - b.width / 2, y: frame.minY + 10))
    }
}
