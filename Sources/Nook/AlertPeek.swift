import AppKit
import Combine

/// Colors and words of the alert peek, from the island's own palette.
enum AlertPeekStyle {
    /// Nook's mint accent: an agent finished.
    static let finished = NSColor(red: 0.32, green: 0.73, blue: 0.61, alpha: 1)
    /// The amber of the unread badge: an agent asks for something.
    static let question = NSColor(red: 0.91, green: 0.79, blue: 0.54, alpha: 1)
    /// A soft red: an agent stopped with an error.
    static let failed = NSColor(red: 0.94, green: 0.42, blue: 0.42, alpha: 1)

    static func color(_ kind: NookAlert.Kind) -> NSColor {
        switch kind { case .finished: finished; case .question: question; case .failed: failed }
    }

    static let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let messageFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)

    /// The text on one calm line: newlines and runs of spaces collapse into single spaces.
    static func line(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What VoiceOver says, since the peek is otherwise only visual.
    static func spoken(_ alert: NookAlert) -> String {
        let title = line(alert.title), message = line(alert.message)
        return title.isEmpty ? message : message.isEmpty ? title : "\(title): \(message)"
    }

    private static var bells: [NookAlert.Kind: NSImage] = [:]
    /// The bell in the alert's color, drawn rather than tinted so it needs no template handling.
    static func bell(_ kind: NookAlert.Kind) -> NSImage {
        if let image = bells[kind] { return image }
        let size = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let colors = NSImage.SymbolConfiguration(paletteColors: [color(kind)])
        let image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?.withSymbolConfiguration(size.applying(colors)) ?? NSImage(size: NSSize(width: 13, height: 14))
        bells[kind] = image
        return image
    }
}

/// The peek's surface: the black shape that grows below the collapsed island, with the bell and the line of
/// text on it. It draws whatever `AlertPeekFrame` it is given and decides nothing about time.
final class AlertPeekView: NSView {
    var layoutSpec: AlertPeekLayout { didSet { if layoutSpec != oldValue { rows = [:]; needsDisplay = true } } }
    private(set) var state = AlertPeekFrame.empty
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var rows: [Int: Row] = [:]

    /// Where the pieces of one alert sit on the chin, in view coordinates.
    struct Row {
        var bell: CGPoint
        var title: NSRect, message: NSRect
        var dot: CGPoint?
    }

    init(layout: AlertPeekLayout) {
        layoutSpec = layout
        super.init(frame: NSRect(origin: .zero, size: layout.windowSize))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Aviso de Nook")
        setAccessibilityHelp("Abre la pestaña que avisa.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if layoutSpec.shapeRect(progress: state.progress).contains(point) { onClick?() }
    }

    func show(_ frame: AlertPeekFrame) {
        guard frame != state else { return }
        if frame.alert == nil { rows.removeAll() }
        // Frames arrive at the display rate; the spoken label only changes with the alert.
        if let alert = frame.alert, alert.id != state.alert?.id { setAccessibilityLabel(AlertPeekStyle.spoken(alert)) }
        state = frame
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext, state.alert != nil, state.surface > 0.001 else { return }
        cg.saveGState(); defer { cg.restoreGState() }
        // A reduced-motion peek dissolves as one piece, so the shape and its content share one opacity.
        let grouped = state.surface < 0.999
        if grouped { cg.setAlpha(state.surface); cg.beginTransparencyLayer(auxiliaryInfo: nil) }
        let path = IslandView.outline(layoutSpec.shapeRect(progress: state.progress), radius: layoutSpec.radius(progress: state.progress))
        cg.addPath(path); cg.setFillColor(NSColor.black.cgColor); cg.fillPath()
        // The text belongs to the chin: while the island is still growing it is cut off by the shape.
        cg.saveGState(); cg.addPath(path); cg.clip()
        if let old = state.outgoing, state.outgoingContent > 0.001 { drawContent(old, alpha: state.outgoingContent, bell: 0, in: cg) }
        if let alert = state.alert, state.content > 0.001 { drawContent(alert, alpha: state.content, bell: state.bell, in: cg) }
        cg.restoreGState()
        if grouped { cg.endTransparencyLayer() }
    }

    private func drawContent(_ alert: NookAlert, alpha: CGFloat, bell angle: CGFloat, in cg: CGContext) {
        let row = self.row(for: alert)
        let color = AlertPeekStyle.color(alert.kind)
        cg.saveGState(); defer { cg.restoreGState() }
        cg.setAlpha(alpha); cg.beginTransparencyLayer(auxiliaryInfo: nil)
        // A soft light of the alert's color under the bell.
        NSGradient(colors: [color.withAlphaComponent(0.26), color.withAlphaComponent(0)])?
            .draw(fromCenter: row.bell, radius: 0, toCenter: row.bell, radius: 17, options: [])
        let bell = AlertPeekStyle.bell(alert.kind), size = bell.size
        // The bell hangs from its top, so that is the pivot of the swing.
        let pivot = CGPoint(x: row.bell.x, y: row.bell.y + size.height * 0.36)
        cg.saveGState()
        cg.translateBy(x: pivot.x, y: pivot.y); cg.rotate(by: angle)
        bell.draw(in: NSRect(x: -size.width / 2, y: -size.height * 0.86, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1)
        cg.restoreGState()
        let title = AlertPeekStyle.line(alert.title), message = AlertPeekStyle.line(alert.message)
        if !title.isEmpty { Self.text(title, font: AlertPeekStyle.titleFont, color: NSColor.white.withAlphaComponent(0.96), in: row.title) }
        if let dot = row.dot {
            NSColor.white.withAlphaComponent(0.3).setFill()
            NSBezierPath(ovalIn: NSRect(x: dot.x - 1.2, y: dot.y - 1.2, width: 2.4, height: 2.4)).fill()
        }
        if !message.isEmpty { Self.text(message, font: AlertPeekStyle.messageFont, color: NSColor.white.withAlphaComponent(0.64), in: row.message) }
        cg.endTransparencyLayer()
    }

    private static func text(_ string: String, font: NSFont, color: NSColor, in rect: NSRect) {
        NSAttributedString(string: string, attributes: attributes(font, color)).draw(with: rect, options: [.usesLineFragmentOrigin])
    }
    private static func attributes(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }

    /// Bell, title and message as one group, centred on the chin. When it does not fit the title gives way
    /// first (down to about a third of the line) and the message is cut with an ellipsis.
    func row(for alert: NookAlert) -> Row {
        if let row = rows[alert.id] { return row }
        let chin = layoutSpec.chinRect
        let title = AlertPeekStyle.line(alert.title), message = AlertPeekStyle.line(alert.message)
        let bell: CGFloat = 13, gap: CGFloat = 7, separator: CGFloat = 13, margin: CGFloat = 18
        let available = chin.width - 2 * margin - bell - gap
        func width(_ s: String, _ font: NSFont) -> CGFloat { s.isEmpty ? 0 : ceil(NSAttributedString(string: s, attributes: [.font: font]).size().width) }
        var titleWidth = width(title, AlertPeekStyle.titleFont), messageWidth = width(message, AlertPeekStyle.messageFont)
        let between = titleWidth > 0 && messageWidth > 0 ? separator : 0
        if titleWidth + between + messageWidth > available {
            titleWidth = min(titleWidth, max(available * 0.34, available - between - messageWidth))
            messageWidth = min(messageWidth, available - between - titleWidth)
        }
        let total = bell + gap + titleWidth + between + messageWidth
        let x = chin.midX - total / 2
        let lineHeight = ceil(AlertPeekStyle.messageFont.ascender - AlertPeekStyle.messageFont.descender)
        let y = chin.midY - lineHeight / 2 - 0.5
        let textX = x + bell + gap
        let row = Row(bell: CGPoint(x: x + bell / 2, y: chin.midY + 0.5),
                      title: NSRect(x: textX, y: y, width: titleWidth, height: lineHeight),
                      message: NSRect(x: textX + titleWidth + between, y: y, width: messageWidth, height: lineHeight),
                      dot: between > 0 ? CGPoint(x: textX + titleWidth + between / 2, y: chin.midY + 0.5) : nil)
        rows[alert.id] = row
        return row
    }
}

/// Runs the peek on the collapsed island: watches the model for a new alert, owns the timeline, the peek's
/// window and its frames, and gives the cat its reaction. Nothing runs between alerts: no timer, no display
/// link, no window; while the peek only sits there the controller sleeps until it is time to close.
final class AlertPeekController {
    private weak var notch: NotchController?
    private let model: AppModel
    private var timeline = AlertPeekTimeline()
    /// The last alert that was given a peek; each alert gets one.
    private var shown: Int?
    private var panel: NotchPanel?
    private var view: AlertPeekView?
    private lazy var ticker = PetTicker { [weak self] in self?.pump() }
    private var wake: Timer?
    private var watches: [AnyCancellable] = []

    init(notch: NotchController) {
        self.notch = notch
        model = notch.model
        // Hop to the next turn: an alert and the island opening for the same question arrive together, and
        // by then it is clear whether there is anything to show.
        watches.append(model.$alert.map { $0?.id }.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sync() })
        // `expand` stops the peek itself, once the island's window is up; this only covers anything else that opens it.
        watches.append(model.$expanded.removeDuplicates().sink { [weak self] expanded in if expanded { DispatchQueue.main.async { self?.cancel() } } })
    }

    static var now: Double { ProcessInfo.processInfo.systemUptime }

    func owns(_ window: NSWindow?) -> Bool { window != nil && window === panel }
    /// The alert on screen: set from the moment the peek starts until it has settled back.
    var current: NookAlert? { timeline.alert }

    private func sync() {
        guard let notch else { return }
        guard let alert = model.alert else { cancel(); return }
        // A hidden island (a full-screen app, a locked screen) has nobody to show a peek to, and a cat being dragged is busy.
        let visible = notch.petPanel.isVisible && notch.petPanel.occlusionState.contains(.visible) && !notch.isDraggingPet
        guard AlertPeekTimeline.shouldPeek(alert, shown: shown, expanded: model.expanded, visible: visible) else { return }
        start(alert)
    }

    private func start(_ alert: NookAlert) {
        guard let notch else { return }
        shown = alert.id
        let now = Self.now
        let fresh = !timeline.isActive
        timeline.begin(alert, now: now, motion: model.animations && !PetAnimation.motionReduced)
        if fresh {
            let compact = notch.compactFrame
            let layout = AlertPeekLayout(compact: compact.size)
            let view = peekView(layout)
            view.show(timeline.frame(at: now))
            let panel = peekPanel(view, level: notch.petPanel.level)
            panel.setFrame(layout.windowFrame(compactFrame: compact), display: false)
            // Behind the collapsed island: its black joins the peek's, and its cat and badge stay on top.
            panel.order(.below, relativeTo: notch.petPanel.windowNumber)
            notch.petView.perk = { [weak self] t in self?.timeline.perk(at: t) ?? 0 }
        }
        if NSWorkspace.shared.isVoiceOverEnabled, let view {
            NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [.announcement: AlertPeekStyle.spoken(alert), .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        notch.petView.react(boost: true)
        pump()
    }

    private func peekView(_ layout: AlertPeekLayout) -> AlertPeekView {
        if let view { view.layoutSpec = layout; view.frame = NSRect(origin: .zero, size: layout.windowSize); return view }
        let view = AlertPeekView(layout: layout)
        view.onHover = { [weak self] hovering in self?.hover(hovering) }
        view.onClick = { [weak self] in self?.click() }
        self.view = view
        return view
    }

    private func peekPanel(_ view: AlertPeekView, level: NSWindow.Level) -> NotchPanel {
        if let panel { return panel }
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.allowsKey = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.level = level
        panel.contentView = view
        self.panel = panel
        return panel
    }

    /// The peek's shape on screen right now (screen coordinates) and its corner radius, so the island can
    /// open from it instead of from the collapsed shape. Nil unless the peek is fully there.
    func visibleShape() -> (rect: CGRect, radius: CGFloat)? {
        guard timeline.isActive, let panel, panel.isVisible, let view else { return nil }
        let frame = timeline.frame(at: Self.now)
        guard frame.surface > 0.999 else { return nil }
        return (view.layoutSpec.screenRect(progress: frame.progress, windowFrame: panel.frame), view.layoutSpec.radius(progress: frame.progress))
    }

    private func hover(_ hovering: Bool) {
        guard timeline.isActive else { return }
        timeline.setHover(hovering, now: Self.now)
        pump()
    }

    private func click() {
        guard let alert = current else { return }
        notch?.openAlertTab(alert)
    }

    /// Stops the peek at once: the island is opening, or the screen changed under it.
    func cancel() {
        guard timeline.isActive else { return }
        finish()
    }

    private func finish() {
        ticker.stop(); wake?.invalidate(); wake = nil
        timeline.cancel()
        view?.show(.empty)
        panel?.orderOut(nil)
        notch?.petView.perk = nil
        notch?.petView.react()
    }

    /// Draws the frame for this moment, then decides what keeps time: frames while something moves, one
    /// timer for the moment it starts to close while it only sits there, nothing while the pointer holds it.
    private func pump() {
        let now = Self.now
        timeline.advance(to: now)
        guard timeline.isActive else { finish(); return }
        view?.show(timeline.frame(at: now))
        if timeline.isAnimating(at: now) {
            wake?.invalidate(); wake = nil
            ticker.host = view
            ticker.run(every: 1.0 / 60)
            return
        }
        ticker.stop()
        wake?.invalidate(); wake = nil
        guard let due = timeline.nextWake(at: now) else { return }
        let timer = Timer(timeInterval: max(0.01, due - now), repeats: false) { [weak self] _ in self?.pump() }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        wake = timer
    }
}
