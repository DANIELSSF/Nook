import AppKit

// The mint pill on the collapsed island's right wing counts the selected tab's working subagents. Alone, a "1" there says
// nothing, so the pill explains itself: pointing at it shows what it counts, in words, and a click opens the island on that
// tab with its list of agents open.
//
// Pointing at the pill does not open the island the way the rest of the wing does: it holds the hover-to-expand back while
// the pointer rests on it, so the tooltip can be read; leaving the pill for the rest of the island gives the hover back.

/// What the pill speaks for: the selected tab and its working agents.
struct AgentPillSummary: Equatable {
    var tab: String
    /// The working agents' names, oldest first.
    var names: [String]
    var running: Int { names.count }
}

/// A request to open a tab's list of agents once the island is open. The serial makes asking twice for the same tab a change.
struct AgentListRequest: Equatable {
    var sessionID: String
    var serial: Int
}

extension AppModel {
    /// What the collapsed island's pill says now, or nil when no agent of the selected tab is working (then there is no pill).
    var agentPill: AgentPillSummary? {
        guard let session = selected else { return nil }
        let running = session.subagents.filter { $0.role == .agent && $0.isRunning }
        return running.isEmpty ? nil : AgentPillSummary(tab: session.displayTitle, names: running.map(\.name))
    }
}

enum AgentPillTooltip {
    /// How many agents the tooltip names before it says "y N más".
    static let namesShown = 3
    static let nameLength = 58

    /// "1 subagente trabajando en «nook»", then the names of up to three of them, then the click's hint.
    static func text(_ summary: AgentPillSummary) -> String {
        let count = summary.running
        let tab = summary.tab.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var lines = ["\(count) \(count == 1 ? "subagente" : "subagentes") trabajando" + (tab.isEmpty ? "" : " en «\(tab)»")]
        for name in summary.names.prefix(namesShown) { lines.append("· " + shortened(name)) }
        if count > namesShown { lines.append("· y \(count - namesShown) más") }
        lines.append("Clic para ver la lista")
        return lines.joined(separator: "\n")
    }

    /// One calm line: runs of whitespace collapse, and a long name is cut with an ellipsis.
    static func shortened(_ name: String) -> String {
        let line = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > nameLength ? String(line.prefix(nameLength - 1)) + "…" : line
    }
}

extension AgentNotchBadge {
    /// The pill's click and hover area: a little larger than the pill itself, inside the wing.
    static func hitRect(running: Int, in bounds: NSRect) -> NSRect? {
        rect(running: running, in: bounds).map { $0.insetBy(dx: -5, dy: -5).intersection(bounds) }
    }
}

// MARK: - The tooltip

/// The tooltip's surface: black like the island, a hairline edge, and the text in three weights.
final class AgentPillTipView: NSView {
    static let padding = NSSize(width: 11, height: 8)
    static let cornerRadius: CGFloat = 10
    static let maxWidth: CGFloat = 320
    private(set) var text = ""

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func setText(_ text: String) {
        guard text != self.text else { return }
        self.text = text
        needsDisplay = true
    }

    /// The text as drawn: the headline, the names a little dimmer, the hint dimmest.
    static func attributed(_ text: String) -> NSAttributedString {
        let lines = text.components(separatedBy: "\n")
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let isHeadline = index == 0, isHint = index == lines.count - 1 && lines.count > 1
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            paragraph.paragraphSpacingBefore = isHint ? 3 : 0
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: isHeadline ? 11.5 : isHint ? 10 : 11, weight: isHeadline ? .semibold : .regular),
                .foregroundColor: NSColor(white: 1, alpha: isHeadline ? 0.96 : isHint ? 0.5 : 0.76),
                .paragraphStyle: paragraph,
            ]
            result.append(NSAttributedString(string: line + (index < lines.count - 1 ? "\n" : ""), attributes: attributes))
        }
        return result
    }

    /// The size the surface needs for `text`.
    static func size(for text: String) -> NSSize {
        let box = attributed(text).boundingRect(with: NSSize(width: maxWidth - padding.width * 2, height: 1000), options: [.usesLineFragmentOrigin])
        return NSSize(width: ceil(min(maxWidth, box.width + padding.width * 2)), height: ceil(box.height + padding.height * 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        NSColor.black.setFill()
        path.fill()
        NSColor(white: 1, alpha: 0.14).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        Self.attributed(text).draw(with: bounds.insetBy(dx: Self.padding.width, dy: Self.padding.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text.replacingOccurrences(of: "\n", with: ". ") }
}

/// The pill's tooltip, in a small panel under the collapsed island. It never takes the pointer or the keyboard.
final class AgentPillTip {
    private let panel: NSPanel
    private let view = AgentPillTipView()
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private(set) var isShown = false

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.contentView = view
    }

    /// Where the tooltip goes: under the island, centred on the pill and kept inside the screen.
    static func frame(size: NSSize, pill: NSRect, island: NSRect, screen: NSRect, gap: CGFloat = 5) -> NSRect {
        let x = min(max(pill.midX - size.width / 2, screen.minX + 8), screen.maxX - 8 - size.width)
        return NSRect(x: x, y: island.minY - gap - size.height, width: size.width, height: size.height)
    }

    /// Shows `text` (or changes it, when it is already up). `pill` and `island` are in screen coordinates.
    func show(_ text: String, pill: NSRect, island: NSRect, screen: NSRect) {
        view.setText(text)
        let size = AgentPillTipView.size(for: text)
        panel.setFrame(Self.frame(size: size, pill: pill, island: island, screen: screen), display: true)
        view.frame = NSRect(origin: .zero, size: size)
        guard !isShown else { return }
        isShown = true
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if !reduceMotion { NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 } }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        panel.orderOut(nil)
    }
}

extension AppModel {
    /// Asks the open island to show this tab's list of agents (see `agentListRequest`).
    func requestAgentList(for session: TerminalSession) {
        agentListRequest = AgentListRequest(sessionID: session.id, serial: (agentListRequest?.serial ?? 0) + 1)
    }
}
