import SwiftUI
import AppKit

// What Claude says about a session as it starts, out of the chat and into the island's own chrome.
//
//   SessionStrip          one quiet line over the conversation: the model, the plan, the folder and the version from Claude's banner
//                         and, at its end, the notice for the warnings Claude printed before it
//   StartupWarningsNotice the amber pill for those warnings and the card it opens, with the rules for opening and closing it; the strip has it
//                         at its end and the welcome of a fresh session (`ClaudeWelcome`) in its first row
//   StartupWarningsCard   the notice opened: every warning in full, with the way to copy them or to dismiss them
//   SessionInfoText       the words, apart from the views so they can be tested without a window
//
// Nothing here reads the screen again: `TerminalSession.banner` and `startupWarnings` already hold what the parser took out of the chat.
// The warnings are Claude's own sentences and stay in its words; everything around them is Nook's, in Spanish.

private let infoAmber = Color.nookAmber

// MARK: - Words

enum SessionInfoText {
    /// "Muy alto" for "xhigh". A level Nook does not know keeps Claude's own word, capitalised.
    static func effort(_ word: String) -> String {
        let lower = word.lowercased()
        return ClaudeEffort(rawValue: lower)?.title ?? lower.prefix(1).uppercased() + lower.dropFirst()
    }

    /// The effort to say: what Claude reported last, or the level the banner started with.
    static func effortTitle(_ banner: ClaudeBanner, live: ClaudeEffort?) -> String? {
        live?.title ?? banner.effort.map(effort)
    }

    /// "3 avisos de configuración".
    static func warningsLabel(_ count: Int) -> String { count == 1 ? "1 aviso de configuración" : "\(count) avisos de configuración" }
    /// "3 avisos", for a narrow island.
    static func warningsShortLabel(_ count: Int) -> String { count == 1 ? "1 aviso" : "\(count) avisos" }

    /// The banner fact by fact, as the tooltip lists it and VoiceOver reads it.
    static func details(_ banner: ClaudeBanner, effort live: ClaudeEffort?) -> [String] {
        var lines = ["Claude Code \(banner.version)"]
        if let model = banner.model { lines.append("Modelo: \(model)") }
        if let level = effortTitle(banner, live: live) { lines.append("Esfuerzo: \(level)") }
        if let plan = banner.plan { lines.append("Plan: \(plan)") }
        if let directory = banner.directory { lines.append("Carpeta: \(directory)") }
        return lines
    }

    /// What the warnings are worth to the dismissal memory: the same set of sentences is the same notice.
    static func digestSource(_ warnings: [ClaudeStartupWarning]) -> String { warnings.map(\.text).joined(separator: "\n") }

    /// Every warning as Claude wrote it, for the clipboard.
    static func clipboardText(_ warnings: [ClaudeStartupWarning]) -> String { warnings.map(\.text).joined(separator: "\n\n") }
}

/// One warning taken apart for the card: what kind it is in Spanish, the file it names, and its sentence with the rule it is about
/// set apart so it can be picked out in the text ("Bash(pnpm * exec prisma format*) has a wildcard before…").
struct StartupWarningParts: Equatable {
    var title: String
    var source: String?
    /// The rule the sentence starts with, when it starts with one; `message` goes on from it.
    var rule: String?
    var message: String

    private static let permission = try! NSRegularExpression(pattern: #"^Permission (allow|deny|ask) rule \(([^)]*)\):\s*(.*)$"#, options: [.dotMatchesLineSeparators])

    init(title: String, source: String?, rule: String?, message: String) {
        self.title = title; self.source = source; self.rule = rule; self.message = message
    }

    init(_ warning: ClaudeStartupWarning) {
        let text = warning.text
        let ns = text as NSString
        guard let match = Self.permission.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            self.init(title: "Aviso de Claude", source: warning.source, rule: nil, message: text)
            return
        }
        let kind = ns.substring(with: match.range(at: 1))
        let named = ns.substring(with: match.range(at: 2))
        let rest = ns.substring(with: match.range(at: 3))
        let split = Self.splitRule(rest)
        self.init(title: "Regla de permiso «\(kind)»", source: (warning.source?.isEmpty == false ? warning.source : nil) ?? (named.isEmpty ? nil : named),
                  rule: split.rule, message: split.message)
    }

    /// "Bash(pnpm --filter * exec prisma format*) has a wildcard…": the first word, parentheses and all, and the rest of the sentence.
    /// Without a rule up front the whole text is the message.
    static func splitRule(_ text: String) -> (rule: String?, message: String) {
        var depth = 0
        var end = text.endIndex
        for index in text.indices {
            let character = text[index]
            if character == "(" { depth += 1 }
            else if character == ")" { depth = max(0, depth - 1) }
            else if character.isWhitespace, depth == 0 { end = index; break }
        }
        let rule = String(text[..<end])
        let message = text[end...].trimmingCharacters(in: .whitespacesAndNewlines)
        // A rule is a tool with what it is for: "Bash(pnpm * exec prisma format*)". A first word that is only a word ("The rule…") is no rule.
        guard !message.isEmpty, let first = rule.first, first.isLetter, rule.contains("("), rule.hasSuffix(")"), rule.count <= 160, message.first?.isLowercase == true else {
            return (nil, text)
        }
        return (rule, message)
    }
}

/// Warnings that say the same thing about different rules, as one: Claude prints a warning per rule, and three rules with the same flaw are
/// three warnings with one sentence. The first keeps the sentence and the other rules follow it.
struct StartupWarningGroup: Equatable {
    var first: StartupWarningParts
    /// The other rules the sentence is about, in the order Claude printed them.
    var others: [String]

    var count: Int { 1 + others.count }

    static func groups(_ warnings: [ClaudeStartupWarning]) -> [StartupWarningGroup] {
        var groups: [StartupWarningGroup] = []
        for warning in warnings {
            let parts = StartupWarningParts(warning)
            if let rule = parts.rule,
               let index = groups.firstIndex(where: { $0.first.rule != nil && $0.first.title == parts.title && $0.first.source == parts.source && $0.first.message == parts.message }) {
                groups[index].others.append(rule)
            } else {
                groups.append(StartupWarningGroup(first: parts, others: []))
            }
        }
        return groups
    }
}

extension RecapSeenStore {
    /// Which sessions' startup warnings the user dismissed. The same memory as the recap's (a small list in the preferences, per session
    /// and per text), under its own key: the notice comes back only when Claude says something else.
    nonisolated(unsafe) static let startupWarnings = RecapSeenStore(key: "nook.startup.warnings.dismissed")

    func areDismissed(_ warnings: [ClaudeStartupWarning], in session: String) -> Bool {
        !warnings.isEmpty && !isNew(SessionInfoText.digestSource(warnings), in: session)
    }

    func dismiss(_ warnings: [ClaudeStartupWarning], in session: String) {
        guard !warnings.isEmpty else { return }
        markSeen(SessionInfoText.digestSource(warnings), in: session)
    }
}

// MARK: - The strip

/// The line over the conversation. Quiet on purpose: the model in the brightest word, the rest in the island's secondary grey, and the
/// notice for the warnings (amber, the island's colour for "look at this") at its end. What does not fit goes in this order: the version,
/// the plan, the folder's middle; the model stays.
struct SessionStrip: View {
    var banner: ClaudeBanner
    /// The effort Claude reports now; the banner's is the one the session started with and may be old.
    var effort: ClaudeEffort?
    /// The warnings still to show (none once the user dismissed them).
    var warnings: [ClaudeStartupWarning]
    /// The user's chat text size; the line follows it a point smaller.
    var chatSize = DisplaySettings.defaultChatSize
    /// The island is on screen; a card left open does not wait for it behind its back.
    var islandVisible = true
    var cardWidth = StartupWarningsCard.width
    var maxBodyHeight = StartupWarningsCard.maxBodyHeight
    var pasteboard = NSPasteboard.general
    /// Previews and render tests keep the card open.
    var keepsOpen = false
    var onDismiss: () -> Void = {}
    private let initiallyOpen: Bool
    /// The strip comes in with a fade of its own opacity, never with the layout: the conversation below changes size at once and only once.
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(banner: ClaudeBanner, effort: ClaudeEffort? = nil, warnings: [ClaudeStartupWarning] = [], chatSize: Double = DisplaySettings.defaultChatSize, islandVisible: Bool = true,
         cardWidth: CGFloat = StartupWarningsCard.width, maxBodyHeight: CGFloat = StartupWarningsCard.maxBodyHeight, pasteboard: NSPasteboard = .general,
         initiallyOpen: Bool = false, keepsOpen: Bool = false, onDismiss: @escaping () -> Void = {}) {
        self.banner = banner
        self.effort = effort
        self.warnings = warnings
        self.chatSize = chatSize
        self.islandVisible = islandVisible
        self.cardWidth = cardWidth
        self.maxBodyHeight = maxBodyHeight
        self.pasteboard = pasteboard
        self.keepsOpen = keepsOpen
        self.onDismiss = onDismiss
        self.initiallyOpen = initiallyOpen
    }

    /// The text's size and the line's height for a chat text size.
    static func fontSize(chatSize: Double) -> CGFloat { CGFloat(min(max(chatSize - 1, 9), 15)) }
    static func height(chatSize: Double) -> CGFloat { ceil(fontSize(chatSize: chatSize) * 1.25) + 4 }
    /// The air between the tab row and the line, the same the conversation leaves.
    static let topInset: CGFloat = 2
    /// What the strip takes of the pane's height, its inset included.
    static func room(chatSize: Double) -> CGFloat { height(chatSize: chatSize) + topInset }

    private var size: CGFloat { Self.fontSize(chatSize: chatSize) }
    private var height: CGFloat { Self.height(chatSize: chatSize) }

    var body: some View {
        HStack(spacing: 10) {
            info
            Spacer(minLength: 0)
            if !warnings.isEmpty {
                StartupWarningsNotice(warnings: warnings, size: size, rowHeight: height, islandVisible: islandVisible, cardWidth: cardWidth, maxBodyHeight: maxBodyHeight,
                                      pasteboard: pasteboard, initiallyOpen: initiallyOpen, keepsOpen: keepsOpen, onDismiss: onDismiss).layoutPriority(1)
            }
        }
        .frame(height: height)
        .padding(.top, Self.topInset)
        .opacity(shown ? 1 : 0)
        .onAppear { if reduceMotion { shown = true } else { withAnimation(.easeOut(duration: 0.18)) { shown = true } } }
    }

    // MARK: The banner's line

    /// The facts that stay when the line is short, in the order they are dropped from the end.
    private func line(plan: Bool, directory: Bool, version: Bool) -> Text {
        let quiet = Color.nookSecondary
        var text = Text("✻").font(.system(size: size, weight: .bold)).foregroundStyle(claudeSpinner.opacity(0.95))
        let separator = Text("  ·  ").foregroundStyle(Color.primary.opacity(0.22))
        var wrote = false
        func add(_ piece: Text) {
            text = text + (wrote ? separator : Text("  ")) + piece
            wrote = true
        }
        if let model = banner.model { add(Text(model).font(.system(size: size, weight: .medium)).foregroundStyle(Color.primary.opacity(0.8))) }
        if plan, let name = banner.plan { add(Text(name).font(.system(size: size)).foregroundStyle(quiet)) }
        if directory, let folder = banner.directory { add(Text(folder).font(.system(size: size - 0.5, design: .monospaced)).foregroundStyle(quiet)) }
        // A banner that named nothing else still says which Claude this is.
        if version || !wrote { add(Text(banner.model == nil && !wrote ? "Claude Code \(banner.version)" : "v\(banner.version)").font(.system(size: size)).foregroundStyle(quiet.opacity(0.85))) }
        return text
    }

    private var info: some View {
        ViewThatFits(in: .horizontal) {
            line(plan: true, directory: true, version: true).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            line(plan: true, directory: true, version: false).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            line(plan: false, directory: true, version: false).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            // The last one gives way instead of overflowing: a folder cut in its middle, a model cut at its end.
            line(plan: false, directory: true, version: false).lineLimit(1).truncationMode(.middle)
        }
        .help(SessionInfoText.details(banner, effort: effort).joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sesión de Claude")
        .accessibilityValue(SessionInfoText.details(banner, effort: effort).joined(separator: ". "))
    }
}

/// The warnings Claude printed as the session started: an amber pill that says how many, and the card it opens (`StartupWarningsCard`) hanging just under
/// the row the pill stands in, at the pill's trailing edge. The pointer on the pill or on the card holds the card open; leaving both closes it after a
/// moment (going from one to the other leaves both for a moment too). A press on the pill opens and closes it; "Descartar" closes it and tells its owner.
struct StartupWarningsNotice: View {
    var warnings: [ClaudeStartupWarning]
    /// The text's size, which the pill and the card follow.
    var size: CGFloat
    /// The height of the row the pill stands in: the card hangs from its bottom.
    var rowHeight: CGFloat
    /// The island is on screen; a card left open does not wait for it behind its back.
    var islandVisible = true
    var cardWidth = StartupWarningsCard.width
    var maxBodyHeight = StartupWarningsCard.maxBodyHeight
    var pasteboard = NSPasteboard.general
    /// Previews and render tests keep the card open.
    var keepsOpen = false
    /// The name of a coordinate space that starts where the card may (the pane's conversation). The pill may stand anywhere in it: the card hangs from the
    /// pill's trailing edge and, where that would take it out of the space at its start, moves right just far enough not to leave it. Without one the pill is
    /// taken to stand at the end of the row, as the strip's does.
    var containerSpace: String?
    var onDismiss: () -> Void = {}
    @State private var open: Bool
    @State private var overPill = false
    @State private var overCard = false
    /// Where the pill's trailing edge is in `containerSpace`.
    @State private var pillEdge: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(warnings: [ClaudeStartupWarning], size: CGFloat, rowHeight: CGFloat, islandVisible: Bool = true, cardWidth: CGFloat = StartupWarningsCard.width,
         maxBodyHeight: CGFloat = StartupWarningsCard.maxBodyHeight, pasteboard: NSPasteboard = .general, initiallyOpen: Bool = false, keepsOpen: Bool = false,
         containerSpace: String? = nil, onDismiss: @escaping () -> Void = {}) {
        self.warnings = warnings
        self.size = size
        self.rowHeight = rowHeight
        self.islandVisible = islandVisible
        self.cardWidth = cardWidth
        self.maxBodyHeight = maxBodyHeight
        self.pasteboard = pasteboard
        self.keepsOpen = keepsOpen
        self.containerSpace = containerSpace
        self.onDismiss = onDismiss
        _open = State(initialValue: initiallyOpen && !warnings.isEmpty)
    }

    /// How far right the card moves so that its leading edge is not left of the container's: none when the pill stands at the end of the row.
    static func cardShift(cardWidth: CGFloat, pillEdge: CGFloat?) -> CGFloat {
        guard let pillEdge else { return 0 }
        return max(0, cardWidth - pillEdge)
    }

    var body: some View {
        WarningsPill(count: warnings.count, open: open, size: size, onHover: { overPill = $0 }, action: toggle)
            .frame(height: rowHeight)
            .modifier(PillEdge(space: containerSpace) { pillEdge = $0 })
            .overlay(alignment: .topTrailing) {
                if open, !warnings.isEmpty {
                    StartupWarningsCard(warnings: warnings, width: cardWidth, maxBodyHeight: maxBodyHeight, fontSize: size, pasteboard: pasteboard, onDismiss: dismiss)
                        // It hangs over the conversation: the arrow shows over it, not the text's I-beam.
                        .pointerHole()
                        .onHover { overCard = $0 }
                        .offset(x: Self.cardShift(cardWidth: cardWidth, pillEdge: pillEdge), y: rowHeight + 4)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .onChange(of: warnings) { _, now in if now.isEmpty { open = false } }
            .onChange(of: islandVisible) { _, visible in if !visible { open = false } }
            .onDisappear { open = false; overPill = false; overCard = false }
            // Going from the pill to the card leaves both for a moment; leaving them for good closes the card.
            .task(id: overPill || overCard) {
                guard open, !keepsOpen, !(overPill || overCard) else { return }
                try? await Task.sleep(for: .seconds(0.8))
                if !Task.isCancelled { close() }
            }
    }

    private func animate(_ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(.easeOut(duration: 0.16), change) }
    }
    private func toggle() { animate { open.toggle() } }
    private func close() { animate { open = false } }
    private func dismiss() {
        animate { open = false }
        onDismiss()
    }
}

/// Reports where the pill's trailing edge is in a coordinate space, when it has one to report in.
private struct PillEdge: ViewModifier {
    var space: String?
    var report: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if let space {
            content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(space)).maxX } action: { report($0) }
        } else {
            content
        }
    }
}

/// The amber notice at the strip's end: how many warnings Claude printed. Its words shorten with the room there is.
private struct WarningsPill: View {
    var count: Int
    var open: Bool
    var size: CGFloat
    var onHover: (Bool) -> Void
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                content(SessionInfoText.warningsLabel(count))
                content(SessionInfoText.warningsShortLabel(count))
                content(nil)
            }
            .padding(.horizontal, 7).frame(height: max(16, size + 7))
            .background(infoAmber.opacity(open ? 0.2 : 0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(infoAmber.opacity(0.3), lineWidth: 0.7))
            .contentShape(Rectangle())
        }
        .nookPress(.squeeze, depth: PressDepth.card, strength: 0.5)
        .onHover(perform: onHover)
        .help("Claude avisó de \(count == 1 ? "un problema" : "\(count) problemas") en tus ajustes al iniciar. Pulsa para leerlos.")
        .accessibilityLabel(SessionInfoText.warningsLabel(count))
        .accessibilityHint("Abre los avisos para leerlos o descartarlos")
    }

    private func content(_ label: String?) -> some View {
        HStack(spacing: 4.5) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: size - 1.5, weight: .semibold))
            if let label { Text(label).font(.system(size: size - 0.5, weight: .medium)).lineLimit(1) } else { Text("\(count)").font(.system(size: size - 0.5, weight: .semibold)) }
            Image(systemName: "chevron.down").font(.system(size: 5.5, weight: .bold)).rotationEffect(.degrees(open ? 180 : 0)).opacity(0.7)
        }
        .foregroundStyle(infoAmber)
        .fixedSize()
    }
}

// MARK: - The notice opened

/// Every warning, whole. It floats over the conversation from the pill's corner, in the amber the island uses for notices.
struct StartupWarningsCard: View {
    var warnings: [ClaudeStartupWarning]
    var width = StartupWarningsCard.width
    /// The text's height before it scrolls; it follows the island's size.
    var maxBodyHeight = StartupWarningsCard.maxBodyHeight
    var fontSize: CGFloat = 10.5
    var pasteboard = NSPasteboard.general
    var onDismiss: () -> Void = {}
    @State private var bodyHeight: CGFloat
    @State private var copied = false

    static let width: CGFloat = 470
    static let maxBodyHeight: CGFloat = 124
    static let headerHeight: CGFloat = 28
    private static let surface = Color.nookCard

    init(warnings: [ClaudeStartupWarning], width: CGFloat = StartupWarningsCard.width, maxBodyHeight: CGFloat = StartupWarningsCard.maxBodyHeight, fontSize: CGFloat = 10.5,
         pasteboard: NSPasteboard = .general, onDismiss: @escaping () -> Void = {}) {
        self.warnings = warnings
        self.width = width
        self.maxBodyHeight = maxBodyHeight
        self.fontSize = fontSize
        self.pasteboard = pasteboard
        self.onDismiss = onDismiss
        _bodyHeight = State(initialValue: Self.estimatedHeight(of: warnings, width: width, fontSize: fontSize))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(StartupWarningGroup.groups(warnings).enumerated()), id: \.offset) { index, group in
                        if index > 0 { Rectangle().fill(Color.nookWash(0.07)).frame(height: 0.5).padding(.vertical, 8) }
                        row(group)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 12)
                .background(GeometryReader { Color.clear.preference(key: WarningsHeightKey.self, value: $0.size.height) })
            }
            .scrollIndicators(.automatic)
            .frame(height: min(max(bodyHeight, 20), maxBodyHeight))
            .onPreferenceChange(WarningsHeightKey.self) { if $0 > 0 { bodyHeight = $0 } }
            // A long notice scrolls; the fade says so.
            .nookScrollFade(active: bodyHeight > maxBodyHeight, surface: Self.surface)
        }
        .frame(width: width)
        // It covers the conversation and part of the composer, so its glass is as dark as the tab list's.
        .nookGlassCard(radius: 11, tint: infoAmber.opacity(0.12), dim: TabAgentListLayout.dim, clipsContent: true, fill: Self.surface, stroke: infoAmber.opacity(0.28))
        .nookCardShadow(0.55, radius: 14, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Avisos de configuración de Claude")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { copied = false }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(infoAmber)
            Text("Avisos de configuración").font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            Text("\(warnings.count)").font(.system(size: 9, weight: .semibold).monospacedDigit()).foregroundStyle(infoAmber)
                .padding(.horizontal, 5).padding(.vertical, 1.5).background(infoAmber.opacity(0.14), in: Capsule())
            Spacer(minLength: 8)
            Button(action: copy) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 8.5, weight: .semibold))
                    Text(copied ? "Copiado" : "Copiar").font(.system(size: 10))
                }.foregroundStyle(copied ? infoAmber : Color.nookSecondary).padding(.horizontal, 6).frame(height: 20).contentShape(Rectangle())
            }.nookPress(.squeeze, depth: PressDepth.card, strength: 0.5).help("Copiar los avisos tal como los escribió Claude").accessibilityLabel("Copiar los avisos")
            Button(action: onDismiss) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    Text("Descartar").font(.system(size: 10, weight: .medium))
                }.foregroundStyle(Color.primary.opacity(0.85)).padding(.horizontal, 7).frame(height: 20)
                    .background(Color.nookWash(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous)).contentShape(Rectangle())
            }.nookPress(.squeeze, depth: PressDepth.card, strength: 0.5).help("Quitar este aviso de la sesión. Solo vuelve si Claude avisa de algo distinto.").accessibilityLabel("Descartar los avisos")
        }.padding(.horizontal, 12).frame(height: Self.headerHeight)
    }

    /// One warning: what kind it is and the file it names, then Claude's sentence with the rule picked out, then the other rules it is about.
    private func row(_ group: StartupWarningGroup) -> some View {
        let parts = group.first
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(parts.title).font(.system(size: fontSize, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.92))
                Spacer(minLength: 6)
                if let source = parts.source {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text").font(.system(size: fontSize - 2))
                        Text(source).font(.system(size: fontSize - 1, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    }.help(source).foregroundStyle(Color.nookSecondary).padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Color.nookWash(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            sentence(parts).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            if !group.others.isEmpty {
                Text(group.others.count == 1 ? "Mismo aviso para otra regla:" : "Mismo aviso para otras \(group.others.count) reglas:")
                    .font(.system(size: fontSize - 0.5)).foregroundStyle(Color.nookSecondary).padding(.top, 3)
                ForEach(Array(group.others.enumerated()), id: \.offset) { _, rule in
                    Text(rule).font(.system(size: fontSize - 0.5, weight: .medium, design: .monospaced)).foregroundStyle(infoAmber.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.accessibilityElement(children: .combine)
    }

    private func sentence(_ parts: StartupWarningParts) -> Text {
        let message = Text(parts.message).font(.system(size: fontSize)).foregroundStyle(Color.primary.opacity(0.78))
        guard let rule = parts.rule else { return message }
        return Text(rule).font(.system(size: fontSize - 0.5, weight: .medium, design: .monospaced)).foregroundStyle(infoAmber.opacity(0.95)) + Text(" ") + message
    }

    private func copy() {
        pasteboard.clearContents()
        pasteboard.setString(SessionInfoText.clipboardText(warnings), forType: .string)
        copied = true
    }

    /// The text's height before SwiftUI has measured it, close enough that the card does not jump when it opens.
    static func estimatedHeight(of warnings: [ClaudeStartupWarning], width: CGFloat, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let line = font.ascender - font.descender + font.leading + 2
        var total: CGFloat = 2 + 12
        for (index, warning) in warnings.enumerated() {
            let box = (warning.text as NSString).boundingRect(with: NSSize(width: width - 24, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: [.font: font])
            total += 16 + 4 + (box.height / line).rounded(.up) * line + (index > 0 ? 17 : 0)
        }
        return total
    }
}

private struct WarningsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
