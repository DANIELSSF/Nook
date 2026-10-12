import SwiftUI
import AppKit

// The welcome of a Claude that has just started and has not been spoken to yet.
//
// Claude Code opens with a banner: its creature, "Claude Code v2.1.293", the model with its effort, the plan, the folder, and an empty box with a grey
// suggestion. Nook takes the banner out of the chat (`TerminalSession.banner`) and, once the conversation is under way, shows it as the quiet line of
// `SessionStrip`. Over an empty conversation that one line looked as if the island had ignored the command that started Claude, so while nothing has been
// said the conversation's place is a welcome: Claude's creature in its terracotta, the model in the headline, and the facts that tell this session from
// another (the plan, which is how a work account is told from a personal one; the folder; the effort).
//
//   ClaudeWelcome        the welcome: it picks, for the room it has, the fullest of five layouts (stacked, banner with the suggestion, banner, compact, line)
//   ClaudeCritter        Claude Code's creature, drawn in pixels of its own size, that blinks and glances now and then
//   CritterGeometry      the creature's grid (plain values)
//   ClaudeWelcomeText    the words (plan symbol, effort, folder in two parts, Claude's suggestion), apart from the views so they are tested without a window
//   ClaudeWelcomeMetrics the sizes that follow the chat's text size
//
// It reads nothing from the screen: the banner, the live effort, the warnings and the box's text arrive as values. The warnings stay reachable through the
// same notice the strip has (`StartupWarningsNotice`), in the welcome's first row.

// MARK: - Words

enum ClaudeWelcomeText {
    /// "Esfuerzo muy alto": the live level, or the one the banner started with. nil when neither says one.
    static func effort(_ banner: ClaudeBanner, live: ClaudeEffort?) -> String? {
        SessionInfoText.effortTitle(banner, live: live).map { "Esfuerzo " + $0.lowercased() }
    }

    /// "v2.1.293".
    static func version(_ banner: ClaudeBanner) -> String { "v" + banner.version }

    /// A symbol for the plan, so a work account and a personal one are told apart before the words are read: people for a team, one person for a personal
    /// plan, a building for a company's, a key for the API's. Any other plan gets the generic person.
    static func planSymbol(_ plan: String) -> String {
        let lower = plan.lowercased()
        if lower.contains("team") { return "person.2.fill" }
        if lower.contains("enterprise") { return "building.2.fill" }
        if lower.contains("api") { return "key.fill" }
        if lower.contains("max") || lower.contains("pro") || lower.contains("personal") { return "person.fill" }
        return "person.crop.circle.fill"
    }

    /// The folder in two parts, where it is and its own name, so the name can stand out: "~/Documents/ChatGPT/New project" is "~/Documents/ChatGPT/" and "New project".
    static func folder(_ path: String) -> (parent: String, name: String) {
        var text = path.trimmingCharacters(in: .whitespaces)
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        guard let slash = text.lastIndex(of: "/"), text.count > 1 else { return ("", text) }
        let name = String(text[text.index(after: slash)...])
        return name.isEmpty ? ("", text) : (String(text[...slash]), name)
    }

    /// What Claude's grey suggestion proposes: `Try "write a test for <filepath>"` is `write a test for <filepath>`. nil for anything else: what the box holds
    /// besides that is text somebody typed in Claude's own terminal, which is no suggestion of Claude's.
    static func suggestion(from box: String?) -> String? {
        guard var text = box?.trimmingCharacters(in: .whitespacesAndNewlines), text.hasPrefix("Try ") else { return nil }
        text.removeFirst(4)
        let quotes: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("«", "»")]
        guard let first = text.first, let last = text.last, text.count > 2, quotes.contains(where: { $0.0 == first && $0.1 == last }) else { return nil }
        let inner = text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? nil : inner
    }

    /// The welcome fact by fact, for VoiceOver.
    static func spoken(_ banner: ClaudeBanner, effort live: ClaudeEffort?) -> String {
        var parts = ["Claude Code \(banner.version)"]
        if let model = banner.model { parts.append("Modelo \(model)") }
        if let effort = effort(banner, live: live) { parts.append(effort.lowercased()) }
        if let plan = banner.plan { parts.append("Plan \(plan)") }
        if let directory = banner.directory { parts.append("Carpeta \(directory)") }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Metrics

enum ClaudeWelcomeMetrics {
    /// The model's name, the lines under it and the creature's pixel for the user's chat text size. They follow it at about half its pace: the welcome is
    /// meant to be seen, and the island is small.
    static func headline(chatSize: Double) -> CGFloat { 16 + CGFloat(chatSize - DisplaySettings.defaultChatSize) * 0.8 }
    static func body(chatSize: Double) -> CGFloat { 10.5 + CGFloat(chatSize - DisplaySettings.defaultChatSize) * 0.5 }
    static func pixel(chatSize: Double) -> CGFloat { 2.6 * (1 + CGFloat(chatSize - DisplaySettings.defaultChatSize) * 0.035) }

    /// The least height the welcome needs, in its smallest layout (the line): under it the strip is what shows.
    static func minimumHeight(chatSize: Double) -> CGFloat {
        let line = max(CritterGeometry.height * pixel(chatSize: chatSize) * 0.4, (body(chatSize: chatSize) + 1) * 1.25)
        return ceil(line) + 2 * 6
    }
}

// MARK: - The creature

/// Claude Code's creature, on a grid of its own: a wide body with two narrow eyes, a stub at each side and four feet. One unit of the grid is `pixel` points.
enum CritterGeometry {
    static let arm: CGFloat = 1.5
    static let bodyWidth: CGFloat = 20
    static let bodyHeight: CGFloat = 12
    static let footHeight: CGFloat = 3
    static let footGap: CGFloat = 2

    static var width: CGFloat { bodyWidth + 2 * arm }
    static var height: CGFloat { bodyHeight + footGap + footHeight }

    static let body = CGRect(x: arm, y: 0, width: bodyWidth, height: bodyHeight)
    static let arms = [CGRect(x: 0, y: 3.5, width: arm, height: 2), CGRect(x: arm + bodyWidth, y: 3.5, width: arm, height: 2)]
    static let feet: [CGRect] = [0, 3, 15.5, 18.5].map { CGRect(x: arm + $0, y: bodyHeight + footGap, width: 1.5, height: footHeight) }
    static let eyes: [CGRect] = [4.3, 14.3].map { CGRect(x: arm + $0, y: 3.3, width: 1.4, height: 2.6) }
    /// Where the eyes' vertical middle is, which a blink closes them around.
    static let eyeLine: CGFloat = 3.3 + 1.3
    /// How far the eyes go to a side when the creature glances, in units.
    static let glance: CGFloat = 0.7
}

private struct CritterBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / CritterGeometry.width
        var path = Path()
        func add(_ frame: CGRect, _ radius: CGFloat) {
            path.addRoundedRect(in: CGRect(x: rect.minX + frame.minX * unit, y: rect.minY + frame.minY * unit, width: frame.width * unit, height: frame.height * unit),
                                cornerSize: CGSize(width: radius * unit, height: radius * unit), style: .continuous)
        }
        add(CritterGeometry.body, 1.1)
        CritterGeometry.arms.forEach { add($0, 0.4) }
        return path
    }
}

private struct CritterFeetShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / CritterGeometry.width
        var path = Path()
        for foot in CritterGeometry.feet {
            path.addRoundedRect(in: CGRect(x: rect.minX + foot.minX * unit, y: rect.minY + foot.minY * unit, width: foot.width * unit, height: foot.height * unit),
                                cornerSize: CGSize(width: 0.45 * unit, height: 0.45 * unit), style: .continuous)
        }
        return path
    }
}

/// The eyes. `open` is how much of their height shows (1 open, near 0 shut), `shift` how far they have gone to a side, in units. Both animate.
private struct CritterEyesShape: Shape {
    var open: CGFloat
    var shift: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(open, shift) }
        set { open = newValue.first; shift = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let unit = rect.width / CritterGeometry.width
        var path = Path()
        for eye in CritterGeometry.eyes {
            let height = max(0.35, eye.height * open)
            path.addRoundedRect(in: CGRect(x: rect.minX + (eye.minX + shift) * unit, y: rect.minY + (CritterGeometry.eyeLine - height / 2) * unit, width: eye.width * unit, height: height * unit),
                                cornerSize: CGSize(width: 0.5 * unit, height: 0.5 * unit), style: .continuous)
        }
        return path
    }
}

/// How the creature looks at the start; render tests use it to show a state that is gone in a moment.
enum ClaudeCritterLook { case resting, blinking, glancing }

struct ClaudeCritter: View {
    /// The size of one unit of the grid, in points.
    var pixel: CGFloat
    /// The eyes are shut / looking to a side (-1 left, 1 right).
    var blinking = false
    var glance = 0

    private static let top = TabRGB(0.90, 0.469, 0.335).mixed(with: TabRGB(1, 1, 1), by: 0.14).color
    private static let feet = TabRGB(0.90, 0.469, 0.335).scaled(by: 0.84).color

    var width: CGFloat { CritterGeometry.width * pixel }
    var height: CGFloat { CritterGeometry.height * pixel }

    var body: some View {
        ZStack {
            CritterBodyShape().fill(LinearGradient(colors: [Self.top, claudeSpinner], startPoint: .top, endPoint: .bottom))
            CritterFeetShape().fill(Self.feet)
            CritterEyesShape(open: blinking ? 0.1 : 1, shift: CGFloat(glance) * CritterGeometry.glance).fill(Color.black.opacity(0.88))
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - The welcome

struct ClaudeWelcome: View {
    var banner: ClaudeBanner
    /// The effort Claude reports now; the banner's is the one the session started with and may be old.
    var effort: ClaudeEffort?
    /// What Claude's box holds (`TerminalSession.suggestion`); only its grey `Try "…"` suggestion is shown, and only as the chip that takes it.
    var suggestion: String?
    /// The warnings still to show (none once the user dismissed them).
    var warnings: [ClaudeStartupWarning]
    var chatSize = DisplaySettings.defaultChatSize
    /// The island is on screen; a card left open does not wait for it behind its back.
    var islandVisible = true
    /// The app's animation preference: the creature blinks and the welcome comes in only with it on (and Reduce Motion off).
    var animated = true
    var cardWidth = StartupWarningsCard.width
    var maxBodyHeight = StartupWarningsCard.maxBodyHeight
    var pasteboard = NSPasteboard.general
    /// Previews and render tests keep the warnings' card open.
    var keepsOpen = false
    var onUseSuggestion: () -> Void = {}
    var onDismissWarnings: () -> Void = {}
    private let warningsOpen: Bool
    @State private var arrived: Bool
    @State private var blink: Bool
    @State private var glance: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nobody can see the island (`\.islandSeen`): what moves here pauses.
    @Environment(\.islandSeen) private var seen
    @Environment(\.tabTint) private var tint

    /// The coordinate space the warnings' card keeps inside: the welcome's own.
    private static let space = "claudeWelcome"

    init(banner: ClaudeBanner, effort: ClaudeEffort? = nil, suggestion: String? = nil, warnings: [ClaudeStartupWarning] = [], chatSize: Double = DisplaySettings.defaultChatSize,
         islandVisible: Bool = true, animated: Bool = true, cardWidth: CGFloat = StartupWarningsCard.width, maxBodyHeight: CGFloat = StartupWarningsCard.maxBodyHeight,
         pasteboard: NSPasteboard = .general, warningsOpen: Bool = false, keepsOpen: Bool = false, look: ClaudeCritterLook = .resting,
         onUseSuggestion: @escaping () -> Void = {}, onDismissWarnings: @escaping () -> Void = {}) {
        self.banner = banner
        self.effort = effort
        self.suggestion = suggestion
        self.warnings = warnings
        self.chatSize = chatSize
        self.islandVisible = islandVisible
        self.animated = animated
        self.cardWidth = cardWidth
        self.maxBodyHeight = maxBodyHeight
        self.pasteboard = pasteboard
        self.warningsOpen = warningsOpen
        self.keepsOpen = keepsOpen
        self.onUseSuggestion = onUseSuggestion
        self.onDismissWarnings = onDismissWarnings
        // A welcome that is not animated is simply there; one that is comes in (`arrived`), and its creature starts as the look says.
        _arrived = State(initialValue: !animated)
        _blink = State(initialValue: look == .blinking)
        _glance = State(initialValue: look == .glancing ? 1 : 0)
    }

    private var motion: Bool { animated && !reduceMotion }
    private var small: CGFloat { ClaudeWelcomeMetrics.body(chatSize: chatSize) }
    private var headline: CGFloat { ClaudeWelcomeMetrics.headline(chatSize: chatSize) }
    private var pixel: CGFloat { ClaudeWelcomeMetrics.pixel(chatSize: chatSize) }
    private var suggested: String? { ClaudeWelcomeText.suggestion(from: suggestion) }
    /// The strip's measures: the notice is the one the strip has.
    private var noticeSize: CGFloat { SessionStrip.fontSize(chatSize: chatSize) }
    private var noticeHeight: CGFloat { SessionStrip.height(chatSize: chatSize) }

    var body: some View {
        ViewThatFits(in: .vertical) {
            stacked
            banner(suggestion: true)
            banner(suggestion: false)
            compact
            line
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: Self.space)
        // The welcome stands over the conversation's (still empty) text: the arrow shows over it, not the text's I-beam.
        .pointerHole()
        .opacity(arrived || !motion ? 1 : 0)
        .offset(y: arrived || !motion ? 0 : 5)
        .onAppear { if motion, !arrived { withAnimation(.easeOut(duration: 0.3)) { arrived = true } } else { arrived = true } }
        // Nobody can see the island (`\.islandSeen`, the screens asleep or locked): the creature holds still too.
        .task(id: motion && islandVisible && seen) { await lifeOfTheCreature(alive: motion && islandVisible && seen) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sesión de Claude nueva")
    }

    // MARK: Layouts

    /// Room to spare: the creature over its words, all centred.
    private var stacked: some View {
        VStack(spacing: 7) {
            critter(scale: 1.3).padding(.bottom, 7)
            HStack(spacing: 9) { eyebrow; notice }.zIndex(1)
            headlineRow
            detailRow.padding(.top, 1)
            if let text = suggested { suggestionRow(text).padding(.top, 8) }
        }.padding(.vertical, 12).padding(.horizontal, 18)
    }

    /// The creature beside its words, and under them Claude's suggestion when there is one.
    private func banner(suggestion withSuggestion: Bool) -> some View {
        VStack(spacing: 11) {
            HStack(alignment: .center, spacing: 17) {
                critter(scale: 1)
                IdentityColumn(spacing: 5) {
                    eyebrow
                    headlineRow
                    detailRow
                    if !warnings.isEmpty { notice.zIndex(1) }
                }
            }
            // Over what comes after it: the card of the warnings hangs over the rest of the welcome.
            .zIndex(1)
            if withSuggestion, let text = suggested { suggestionRow(text) }
        }.padding(.vertical, 8).padding(.horizontal, 18)
    }

    /// Less room: a smaller creature and the two lines that matter, the version at the end of the first.
    private var compact: some View {
        HStack(alignment: .center, spacing: 12) {
            critter(scale: 0.62)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    headlineText(size: headline - 3)
                    effortLabel
                    Spacer(minLength: 6)
                    Text(ClaudeWelcomeText.version(banner)).font(.system(size: small - 1, design: .monospaced)).foregroundStyle(Color.nookSecondary).lineLimit(1)
                    notice
                }.zIndex(1)
                detailRow
            }
        }.padding(.vertical, 6).padding(.horizontal, 16)
    }

    /// The least: one line, like the strip's but with the creature. The model and the plan stay whole; the folder gives way.
    private var line: some View {
        HStack(spacing: 9) {
            critter(scale: 0.4)
            Text(banner.model ?? "Claude Code").font(.system(size: small + 1, weight: .semibold, design: .rounded)).foregroundStyle(Color.primary.opacity(0.92))
                .lineLimit(1).layoutPriority(1)
            if let plan = banner.plan {
                dot
                Text(plan).font(.system(size: small)).foregroundStyle(Color.nookSecondary).lineLimit(1).layoutPriority(1)
            }
            if let directory = banner.directory {
                dot
                Text(directory).font(.system(size: small - 0.5, design: .monospaced)).foregroundStyle(Color.nookSecondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            notice
        }.padding(.vertical, 6).padding(.horizontal, 16)
    }

    private var dot: some View { Text("·").font(.system(size: small)).foregroundStyle(Color.primary.opacity(0.28)) }

    // MARK: Pieces

    private func critter(scale: CGFloat) -> some View {
        ClaudeCritter(pixel: pixel * scale, blinking: blink, glance: glance)
            // A soft terracotta light behind it, so it sits in the black and not on it.
            .background {
                RadialGradient(colors: [claudeSpinner.opacity(0.2), claudeSpinner.opacity(0.07), .clear], center: .center, startRadius: 0, endRadius: pixel * scale * 17)
                    .frame(width: pixel * scale * 40, height: pixel * scale * 34).allowsHitTesting(false)
            }
            .frame(width: CritterGeometry.width * pixel * scale, height: CritterGeometry.height * pixel * scale)
    }

    /// "Claude Code v2.1.293".
    private var eyebrow: some View {
        HStack(spacing: 7) {
            if banner.model != nil {
                Text("Claude Code").font(.system(size: small - 0.5, weight: .medium)).foregroundStyle(Color.primary.opacity(0.62))
            }
            Text(ClaudeWelcomeText.version(banner)).font(.system(size: small - 1, design: .monospaced)).foregroundStyle(Color.nookSecondary)
        }
        .lineLimit(1).fixedSize()
        .accessibilityHidden(true)
    }

    @ViewBuilder private var notice: some View {
        if !warnings.isEmpty {
            StartupWarningsNotice(warnings: warnings, size: noticeSize, rowHeight: noticeHeight, islandVisible: islandVisible, cardWidth: cardWidth, maxBodyHeight: maxBodyHeight,
                                  pasteboard: pasteboard, initiallyOpen: warningsOpen, keepsOpen: keepsOpen, containerSpace: Self.space, onDismiss: onDismissWarnings)
                .layoutPriority(2)
        }
    }

    private var headlineRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            headlineText(size: headline)
            effortLabel
        }
        // The one element that says the whole welcome to VoiceOver; the rows around it are its parts.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claude Code")
        .accessibilityValue(ClaudeWelcomeText.spoken(banner, effort: effort))
    }

    private func headlineText(size: CGFloat) -> some View {
        Text(banner.model ?? "Claude Code").font(.system(size: size, weight: .semibold, design: .rounded)).tracking(-0.25)
            .foregroundStyle(Color.primary.opacity(0.96)).lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
    }

    @ViewBuilder private var effortLabel: some View {
        if let words = ClaudeWelcomeText.effort(banner, live: effort) {
            HStack(spacing: 5) {
                EffortGlyph(effort: effort ?? banner.effort.flatMap(ClaudeEffort.init(rawValue:)), color: Color.primary.opacity(0.62), size: small + 1.5)
                Text(words).font(.system(size: small)).foregroundStyle(Color.primary.opacity(0.66)).lineLimit(1)
            }.fixedSize().accessibilityHidden(true)
        }
    }

    /// The plan and the folder, side by side; the folder gives way first.
    private var detailRow: some View {
        HStack(spacing: 9) {
            planCapsule
            folder
        }
    }

    /// The plan, in the tab's colour: it is what tells this account from another, so it is the one chip of colour among the words.
    @ViewBuilder private var planCapsule: some View {
        if let plan = banner.plan {
            let height = small + 9
            // As round as a capsule, in circular corners: a stroked `Capsule`, or a continuous corner as round as the height allows, leaves a short tick at each end.
            let shape = RoundedRectangle(cornerRadius: height / 2, style: .circular)
            HStack(spacing: 5) {
                Image(systemName: ClaudeWelcomeText.planSymbol(plan)).font(.system(size: small - 1, weight: .semibold)).foregroundStyle(tint.marker)
                Text(plan).font(.system(size: small, weight: .medium)).foregroundStyle(tint.voiceText).lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 9).frame(height: height)
            .background(tint.accent.opacity(0.2), in: shape)
            .overlay(shape.strokeBorder(tint.accent.opacity(0.5), lineWidth: 0.8))
            .accessibilityHidden(true)
        }
    }

    /// The folder's name stands out from where it is.
    @ViewBuilder private var folder: some View {
        if let directory = banner.directory {
            let parts = ClaudeWelcomeText.folder(directory)
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: small - 1, weight: .medium)).foregroundStyle(Color.nookSecondary)
                (Text(parts.parent).font(.system(size: small - 0.5, design: .monospaced)).foregroundStyle(Color.nookSecondary)
                    + Text(parts.name).font(.system(size: small - 0.5, weight: .medium, design: .monospaced)).foregroundStyle(Color.primary.opacity(0.86)))
                    .lineLimit(1).truncationMode(.middle)
            }.layoutPriority(-1).accessibilityHidden(true)
        }
    }

    private func suggestionRow(_ text: String) -> some View {
        CappedWidth(limit: 440) { suggestionChip(text) }
            // Only the layout that is on screen says it: the composer does not repeat the suggestion while this chip does.
            .preference(key: ClaudeWelcomeSuggestionKey.self, value: true)
    }

    /// Claude's grey suggestion as a chip that puts it in the message field, which is what Tab does there.
    private func suggestionChip(_ text: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button(action: onUseSuggestion) {
            HStack(spacing: 7) {
                Image(systemName: "sparkle").font(.system(size: small - 1, weight: .semibold)).foregroundStyle(claudeSpinner)
                Text("Prueba").font(.system(size: small)).foregroundStyle(Color.nookSecondary)
                Text("«\(text)»").font(.system(size: small, design: .monospaced)).foregroundStyle(Color.primary.opacity(0.9)).lineLimit(1).truncationMode(.tail)
                Text("⇥").font(.system(size: small - 1.5, weight: .medium, design: .rounded)).foregroundStyle(Color.primary.opacity(0.66))
                    .padding(.horizontal, 4.5).frame(height: small + 1)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .padding(.horizontal, 11).frame(height: small + 15)
            // A card of its own over the black, glass where there is glass: it is a button, so it has to look like one.
            .nookGlassSurface(in: shape, interactive: true, dim: 0.8, dimColor: Color.nookChip, fill: Color.nookWash(0.07, light: 0.05), stroke: Color.nookWash(0.13, light: 0.16))
            .contentShape(shape)
        }
        .nookPress(.none, depth: PressDepth.card)
        .nookTip(NookTip("Usar la sugerencia de Claude", detail: "La pone en tu mensaje · ⇥ también lo hace"), id: "welcome-suggestion")
        .accessibilityLabel("Usar la sugerencia de Claude")
        .accessibilityValue(text)
    }

    // MARK: Life

    /// The creature blinks every few seconds and now and then glances to a side. It does nothing while the island is out of sight, with Reduce Motion, or with
    /// the app's animations off: then it simply looks ahead.
    private func lifeOfTheCreature(alive: Bool) async {
        guard alive else { blink = false; glance = 0; return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.4...5.0)))
            guard !Task.isCancelled else { return }
            if Int.random(in: 0..<4) == 0 {
                withAnimation(.easeOut(duration: 0.14)) { glance = Bool.random() ? -1 : 1 }
                try? await Task.sleep(for: .seconds(1.1))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.14)) { glance = 0 }
            } else {
                withAnimation(.easeIn(duration: 0.06)) { blink = true }
                try? await Task.sleep(for: .seconds(0.13))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.09)) { blink = false }
            }
        }
    }
}

// MARK: - What the welcome says to the composer

/// Whether the welcome shows Claude's suggestion as its chip (not every layout has room for it). The message field's placeholder says the suggestion when the
/// welcome does not, and not when it does: the suggestion is on screen once.
struct ClaudeWelcomeSuggestionKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// MARK: - Layouts

/// The welcome's words as one column: its first row ("Claude Code v2.1.293"), its headline and its details, one under the other and flush left, as wide as
/// the widest of them. The warnings' notice, when there is one (the last subview), stands at the end of the first row in the room that row leaves, so it picks
/// the words it says by that room (and stands after the first row's words when the other rows are narrower than they are).
struct IdentityColumn: Layout {
    var spacing: CGFloat
    /// The air between the first row's words and the notice.
    var gap: CGFloat = 8

    private struct Measures {
        var rows: [CGSize]
        var notice: CGSize?
        var size: CGSize
    }

    private func measure(_ subviews: Subviews, width: CGFloat?) -> Measures {
        let rowViews = Array(subviews.prefix(3))
        let rows = rowViews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        guard rows.count == 3 else { return Measures(rows: rows, notice: nil, size: CGSize(width: rows.map(\.width).max() ?? 0, height: rows.map(\.height).reduce(0, +))) }
        let base = rows.map(\.width).max() ?? 0
        var wide = base
        var notice: CGSize?
        if subviews.count > 3 {
            let room = max(0, base - rows[0].width - gap)
            let size = subviews[3].sizeThatFits(ProposedViewSize(width: room, height: nil))
            notice = size
            wide = max(base, rows[0].width + gap + size.width)
        }
        let first = max(rows[0].height, notice?.height ?? 0)
        return Measures(rows: rows, notice: notice, size: CGSize(width: wide, height: first + spacing + rows[1].height + spacing + rows[2].height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measure(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measures = measure(subviews, width: bounds.width)
        guard measures.rows.count == 3 else { return }
        let first = max(measures.rows[0].height, measures.notice?.height ?? 0)
        var y = bounds.minY
        subviews[0].place(at: CGPoint(x: bounds.minX, y: y + (first - measures.rows[0].height) / 2), anchor: .topLeading, proposal: ProposedViewSize(measures.rows[0]))
        if let notice = measures.notice, subviews.count > 3 {
            subviews[3].place(at: CGPoint(x: bounds.minX + measures.size.width - notice.width, y: y + (first - notice.height) / 2), anchor: .topLeading, proposal: ProposedViewSize(notice))
        }
        y += first + spacing
        subviews[1].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: measures.size.width, height: measures.rows[1].height))
        y += measures.rows[1].height + spacing
        subviews[2].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: measures.size.width, height: measures.rows[2].height))
    }
}

/// Lays its one child out as wide as it wants up to `limit`, never wider than the room it is offered (a flexible frame would fill the room instead).
private struct CappedWidth: Layout {
    var limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? limit, limit), height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
