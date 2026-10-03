import AppKit

// How the open island looks, as the user sets it: the size of the conversation's text and of the message field's text,
// the island's width and height, and how many lines the field grows to before it scrolls.
//
//   DisplaySettings   the preferences themselves: ranges, defaults, clamping, persistence (plain values)
//   IslandPreset      the size presets (Compacta, Normal, Amplia, Alta)
//   NotchGeometry     (extension) the island's size for those settings on a given screen
//   PaneLayout        what the pane derives from its own size and the settings: composer height, how many rows the
//                     "/" menu and the question card can show, how tall the lists over the conversation may be
//
// Every default reproduces the look the island had before the settings existed, so a Mac that never opens them sees
// no difference. Nothing here has a view in it: the numbers are checked by tests for every preset and screen.

/// The island's size presets. A preset is a pair of offsets from the Normal island, so it means the same on a screen with
/// a notch (a taller island) and on one without.
enum IslandPreset: String, CaseIterable, Identifiable {
    case compact, normal, wide, tall

    var id: String { rawValue }

    var title: String {
        switch self { case .compact: "Compacta"; case .normal: "Normal"; case .wide: "Amplia"; case .tall: "Alta" }
    }

    /// Points added to the Normal island's width.
    var widthExtra: CGFloat {
        switch self { case .compact: -72; case .normal: 0; case .wide: 148; case .tall: 0 }
    }
    /// Points added to the Normal island's height.
    var heightExtra: CGFloat {
        switch self { case .compact: -44; case .normal: 0; case .wide: 84; case .tall: 220 }
    }
}

struct DisplaySettings: Equatable {
    static let chatSizeRange: ClosedRange<Double> = 9...18
    static let inputSizeRange: ClosedRange<Double> = 10...20
    static let linesRange: ClosedRange<Int> = 1...6
    static let defaultChatSize = 11.0
    static let defaultInputSize = 13.0
    static let defaultLines = 3
    /// How far the stored offsets may reach; the screen decides what is really shown (see `NotchGeometry.expandedSize`).
    static let widthExtraRange: ClosedRange<CGFloat> = -140...2400
    static let heightExtraRange: ClosedRange<CGFloat> = -80...2400

    /// The conversation's text (the chat mirror and the live terminal of Nook's own sessions), in points.
    var chatSize = defaultChatSize
    /// The message field's text, in points.
    var inputSize = defaultInputSize
    /// How many lines the message field shows before it scrolls inside itself.
    var inputLines = defaultLines
    /// Points added to the Normal island's width and height (negative: smaller). Zero is today's island.
    var widthExtra: CGFloat = 0
    var heightExtra: CGFloat = 0

    // MARK: Fonts

    var chatFont: NSFont { Self.chatFont(size: chatSize) }
    var inputFont: NSFont { Self.inputFont(size: inputSize) }
    static func chatFont(size: Double) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    static func inputFont(size: Double) -> NSFont { .systemFont(ofSize: size) }

    // MARK: Changes

    /// The same settings with every value brought inside its range (and whole points for the texts, so the shortcuts
    /// and the sliders always meet on the same values). Anything that is not a number goes back to its default.
    func clamped() -> DisplaySettings {
        func fix(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(max(value.rounded(), range.lowerBound), range.upperBound) : fallback
        }
        func fix(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
            value.isFinite ? min(max(value.rounded(), range.lowerBound), range.upperBound) : 0
        }
        var copy = self
        copy.chatSize = fix(chatSize, Self.chatSizeRange, Self.defaultChatSize)
        copy.inputSize = fix(inputSize, Self.inputSizeRange, Self.defaultInputSize)
        copy.inputLines = min(max(inputLines, Self.linesRange.lowerBound), Self.linesRange.upperBound)
        copy.widthExtra = fix(widthExtra, Self.widthExtraRange)
        copy.heightExtra = fix(heightExtra, Self.heightExtraRange)
        return copy
    }

    /// What ⌘+, ⌘− and ⌘0 do to the settings.
    func applying(_ shortcut: ChatSizeShortcut) -> DisplaySettings {
        switch shortcut {
        case .larger: return steppingChatSize(by: 1)
        case .smaller: return steppingChatSize(by: -1)
        case .reset:
            var copy = self
            copy.chatSize = Self.defaultChatSize
            return copy
        }
    }

    /// ⌘+ and ⌘−: one point more or less for the conversation's text, kept inside its range.
    func steppingChatSize(by points: Double) -> DisplaySettings {
        var copy = self
        copy.chatSize = chatSize + points
        return copy.clamped()
    }

    /// Takes a preset's size and leaves the texts alone.
    func applying(_ preset: IslandPreset) -> DisplaySettings {
        var copy = self
        copy.widthExtra = preset.widthExtra
        copy.heightExtra = preset.heightExtra
        return copy
    }

    /// The preset the island's size matches, nil when the user has set a size of their own.
    var preset: IslandPreset? {
        IslandPreset.allCases.first { abs($0.widthExtra - widthExtra) < 0.5 && abs($0.heightExtra - heightExtra) < 0.5 }
    }

    var isDefault: Bool { self == DisplaySettings() }

    // MARK: Persistence

    enum Key {
        static let chatSize = "display.chatSize"
        static let inputSize = "display.inputSize"
        static let inputLines = "display.inputLines"
        static let widthExtra = "display.widthExtra"
        static let heightExtra = "display.heightExtra"
    }

    /// What is stored. A key that is missing (a Mac that never changed it) or holds something else is the default.
    static func load(from defaults: UserDefaults = .standard) -> DisplaySettings {
        func number(_ key: String) -> Double? { (defaults.object(forKey: key) as? NSNumber)?.doubleValue }
        var settings = DisplaySettings()
        if let value = number(Key.chatSize) { settings.chatSize = value }
        if let value = number(Key.inputSize) { settings.inputSize = value }
        if let value = number(Key.inputLines), value.isFinite { settings.inputLines = Int(value.rounded()) }
        if let value = number(Key.widthExtra) { settings.widthExtra = CGFloat(value) }
        if let value = number(Key.heightExtra) { settings.heightExtra = CGFloat(value) }
        return settings.clamped()
    }

    func save(to defaults: UserDefaults = .standard) {
        let value = clamped()
        defaults.set(value.chatSize, forKey: Key.chatSize)
        defaults.set(value.inputSize, forKey: Key.inputSize)
        defaults.set(value.inputLines, forKey: Key.inputLines)
        defaults.set(Double(value.widthExtra), forKey: Key.widthExtra)
        defaults.set(Double(value.heightExtra), forKey: Key.heightExtra)
    }
}

// MARK: - Island size

extension NotchGeometry {
    /// The narrowest and shortest the open island may be: the header's buttons, the composer's controls and a few lines
    /// of conversation still fit. A small screen can force it smaller (see `expandedSize`).
    static let minExpandedWidth: CGFloat = 440
    static func minExpandedHeight(topInset: CGFloat) -> CGFloat { max(topInset, 28) + 170 }

    /// The open island's size on a screen of `screen` points: the Normal size plus the user's offsets, kept between the
    /// minimum and the screen's own clamp (32 pt of margin across, 40 down), which always has the last word.
    static func expandedSize(screen: CGSize, topInset: CGFloat, settings: DisplaySettings = DisplaySettings()) -> CGSize {
        let width = clampedWidth(expandedWidth + settings.widthExtra, screen: screen)
        let height = clampedHeight(expandedHeight(topInset: topInset) + settings.heightExtra, screen: screen, topInset: topInset)
        return CGSize(width: width, height: height)
    }

    static func clampedWidth(_ width: CGFloat, screen: CGSize) -> CGFloat {
        min(max(width, minExpandedWidth), screen.width - 32).rounded()
    }
    static func clampedHeight(_ height: CGFloat, screen: CGSize, topInset: CGFloat) -> CGFloat {
        min(max(height, minExpandedHeight(topInset: topInset)), screen.height - 40).rounded()
    }

    /// What the sliders can reach on this screen.
    static func widthRange(screen: CGSize) -> ClosedRange<CGFloat> {
        let top = clampedWidth(.greatestFiniteMagnitude, screen: screen)
        return min(minExpandedWidth, top)...top
    }
    static func heightRange(screen: CGSize, topInset: CGFloat) -> ClosedRange<CGFloat> {
        let top = clampedHeight(.greatestFiniteMagnitude, screen: screen, topInset: topInset)
        return min(minExpandedHeight(topInset: topInset), top)...top
    }

    /// The offsets that give the island exactly `size` on this screen (a drag on its corner, or a slider).
    static func settings(for size: CGSize, screen: CGSize, topInset: CGFloat, from base: DisplaySettings) -> DisplaySettings {
        var settings = base
        settings.widthExtra = clampedWidth(size.width, screen: screen) - expandedWidth
        settings.heightExtra = clampedHeight(size.height, screen: screen, topInset: topInset) - expandedHeight(topInset: topInset)
        return settings.clamped()
    }

    /// The header's room for the cat, left of the camera: the island's half beyond the cutout, less the margins, never
    /// under 60 pt. A wider island lets it roam a little further.
    static func petStageWidth(islandWidth: CGFloat, cutout: CGFloat) -> CGFloat {
        let cap = 164 + max(0, islandWidth - expandedWidth) / 4
        return max(60, min(cap, (islandWidth - cutout) / 2 - 24))
    }
}

// MARK: - The composer's measures

/// The message field's measures, shared by the field itself (which lays text out) and the pane (which has to know how
/// tall the composer will be before it does).
enum ComposerMetrics {
    /// Space above and below the text inside the field. With the default 13 pt text one line is 16 + 6 = 22 pt, as the
    /// single-line field always was.
    static let verticalInset: CGFloat = 3
    /// The band above the field (inside the composer) and the controls row under it.
    static let topPadding: CGFloat = 9
    static let controlsHeight: CGFloat = 35
    /// Between the pane's edge and the composer's bottom.
    static let bottomInset: CGFloat = 9
    /// The conversation never gives up its last pane points: this much stays above the composer.
    static let minConversation: CGFloat = 56
    /// Between the conversation and the composer.
    static let spacing: CGFloat = 6

    /// One line of text of this size, in whole points: every line of the field has exactly this height.
    static func lineHeight(size: Double) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: DisplaySettings.inputFont(size: size)))
    }

    static func fieldHeight(lines: Int, size: Double) -> CGFloat {
        CGFloat(max(1, lines)) * lineHeight(size: size) + 2 * verticalInset
    }

    /// What the composer takes besides the field's lines: the band above, the padding in the field, the controls row.
    static let chrome: CGFloat = topPadding + 2 * verticalInset + controlsHeight

    static func composerHeight(lines: Int, size: Double) -> CGFloat {
        chrome + CGFloat(max(1, lines)) * lineHeight(size: size)
    }
}

// MARK: - The pane's layout

/// What the pane (the conversation, the composer and what floats over them) works out from its own size and the
/// settings. `height` is the pane's: the island's height less the header and the tab row.
struct PaneLayout: Equatable {
    var width: CGFloat
    var height: CGFloat
    var settings = DisplaySettings()

    /// The tab row's height; the pane starts under it.
    static let tabRowHeight: CGFloat = 30

    /// The pane of an island of this size (`neck` is the header's height).
    static func of(island: CGSize, neck: CGFloat, settings: DisplaySettings) -> PaneLayout {
        PaneLayout(width: island.width, height: max(0, island.height - neck - tabRowHeight), settings: settings)
    }

    var lineHeight: CGFloat { ComposerMetrics.lineHeight(size: settings.inputSize) }

    func composerHeight(lines: Int) -> CGFloat { ComposerMetrics.composerHeight(lines: lines, size: settings.inputSize) }

    /// The lines the field may show before it scrolls: what the user chose, less what the pane cannot spare (the
    /// conversation keeps at least `minConversation` points). At least one.
    var fieldLines: Int {
        let spare = height - ComposerMetrics.bottomInset - ComposerMetrics.chrome - ComposerMetrics.spacing - ComposerMetrics.minConversation
        let fits = Int((spare / lineHeight).rounded(.down))
        return max(1, min(settings.inputLines, fits))
    }

    // MARK: The "/" menu

    /// Rows the menu shows before it scrolls. It floats over the conversation, bottom edge just above the composer, and may
    /// reach up to 7 points under the tab row. In the Normal island that is five rows, as it always was; a taller one
    /// shows more, a smaller one fewer (never under two, which the smallest island still has room for).
    static let slashRowRange = 2...14
    func slashRows(composerHeight: CGFloat) -> Int {
        let room = height - ComposerMetrics.bottomInset - composerHeight - SlashMenuView.gap - 7 - 2 * SlashMenuView.inset
        let rows = Int(((room + SlashMenuView.rowGap) / (SlashMenuView.rowHeight + SlashMenuView.rowGap)).rounded(.down))
        return min(max(rows, Self.slashRowRange.lowerBound), Self.slashRowRange.upperBound)
    }

    // MARK: The agent's question

    /// The room the question card may take: the pane less its bottom margin.
    var cardRoom: CGFloat { height - ComposerMetrics.bottomInset }

    /// Options the card shows before it scrolls: as many as fit with the header, never under three.
    var cardRows: Int {
        let rows = Int(((cardRoom - AgentPromptCard.headerHeight - AgentPromptCard.bottomInset + AgentPromptCard.rowGap) / (AgentPromptCard.rowHeight + AgentPromptCard.rowGap)).rounded(.down))
        return max(3, rows)
    }

    /// The conversation keeps at least this much above the card for the card to sit beside it: 51 points, which is what
    /// four options leave in the Normal island.
    static let minConversationBesideCard: CGFloat = 51

    /// The most options the card can have and still leave the conversation a few lines above it (four in the Normal
    /// island); with more, the card takes the pane.
    var cardOptionsBesideMirror: Int {
        var options = 0
        while options < 40 {
            let card = AgentPromptCard.cardHeight(options: options + 1, visibleRows: cardRows)
            if cardRoom - card - ComposerMetrics.spacing < Self.minConversationBesideCard { break }
            options += 1
        }
        return max(1, options)
    }

    // MARK: Lists over the conversation

    /// The tallest the subagent list may be under the tab row: the pane less 26 points (178 in the Normal island).
    var tabListMaxHeight: CGFloat { max(120, height - 26) }
    /// The list's width: its own 440, or what the island leaves between its margins.
    var tabListWidth: CGFloat { min(TabAgentListLayout.width, max(240, width - 2 * TabAgentListLayout.margin)) }

    /// The tallest the list above the composer's agents capsule may be: from just under the tab row (2 points) down to 6 above
    /// the capsule, which sits on the first line of the field.
    func capsuleListMaxHeight(composerHeight: CGFloat) -> CGFloat {
        let capsuleTop = height - ComposerMetrics.bottomInset - composerHeight + ComposerMetrics.topPadding + capsuleOffset
        return max(80, capsuleTop - 6 - 2)
    }

    /// The capsule is 22 pt tall and sits centred on the field's first line.
    var capsuleOffset: CGFloat { max(0, ComposerMetrics.verticalInset + lineHeight / 2 - 11) }

    /// The recap card's width and the height of its text before it scrolls (124 in the Normal island).
    var recapWidth: CGFloat { min(SessionRecapCard.width, max(220, width - 24)) }
    var recapMaxBodyHeight: CGFloat { min(320, max(60, height - 80)) }
}

// MARK: - Shortcuts

/// ⌘+ and ⌘− (also ⌘= and the keypad's, since "+" is a shifted key on some layouts) change the chat's text size, ⌘0
/// resets it. Plain values, so the keys are checked without an event.
enum ChatSizeShortcut: Equatable {
    case larger, smaller, reset

    /// `characters` are the key's own characters (ignoring modifiers other than shift); `modifiers` as the event reports them.
    init?(characters: String?, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        guard flags == [.command] || flags == [.command, .shift], let key = characters else { return nil }
        switch key {
        case "+", "=": self = .larger
        case "-", "_": self = .smaller
        case "0" where flags == [.command]: self = .reset
        default: return nil
        }
    }

    init?(event: NSEvent) {
        self.init(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
    }
}
