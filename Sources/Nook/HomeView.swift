import SwiftUI
import AppKit

// The home: what the island shows while it has no tab (and the first time Nook runs, the greeting).
//
//   HomeView          the empty island: the cat on its stage, a line to say what to do, the three ways to start (Claude Code, Codex, Terminal) as cards, and the way to
//                     follow a terminal that is already open (a button, or dragging the cat to its window)
//   GreetingView      the first time Nook runs, and whenever the user asks for it in Ajustes («Ver la bienvenida otra vez»): the cat waves, says who it is and what it does
//   HomeStage         the cat's stage: a window onto the island's black (it is black in both themes: a white cat does not read on the light theme's paper), with a glow,
//                     a mat and the cat itself (`HomePetView`: the real cat, drawn large)
//   HomeCard          one way to start: an icon tile, a name and a line; it lifts when the pointer comes onto it, its arrow leans out, and the cat looks at it
//   HomeMetrics       what fits, for the island's size: the stage's size and the cat's scale, the cards' height, which lines stay (plain numbers, checked for every preset)
//   HomeCopy          the words
//
// The cat reacts: it looks at the pointer from a way off and at the card the pointer is on, answers a click with a mew (and a hop), hops when an action is chosen, waves in
// the greeting, and can be picked up and dropped on a terminal window as the header's cat can. It moves only while the island is seen and the animations are on.

// MARK: - Words

enum HomeCopy {
    static let title = "Tu IA, a mano."
    static let subtitle = "Abre una sesión o conecta tu terminal."
    static let connect = "Conectar una terminal que ya uso"
    /// The same, for the room of a small island.
    static let connectShort = "Conectar una terminal"
    static let dragHint = "O arrastra el gatito a una ventana de Terminal."
    /// What the cat says when the pointer is on it.
    static let bubbleDrag = "Arrástrame a tu Terminal"
    static let bubbleHello = "¡Hola!"
    static let meows = ["¡Miau!", "¡Mrrp!", "¡Prrr!", "¡Miau, miau!"]
    static let opening = "Abriendo…"

    /// The line above the title, by the hour: the cat says good day.
    static func overline(hour: Int) -> String {
        switch hour {
        case 6..<13: "Buenos días"
        case 13..<20: "Buenas tardes"
        default: "Buenas noches"
        }
    }

    /// The line under a card's name.
    static func detail(_ kind: SessionKind) -> String {
        switch kind {
        case .claude: "Nueva sesión"
        case .codex: "Nueva sesión"
        case .shell: "Pestaña nueva"
        }
    }

    /// How a card says what it does to VoiceOver.
    static func spoken(_ kind: SessionKind) -> String {
        switch kind {
        case .claude: "Abrir una sesión nueva de Claude Code en Terminal"
        case .codex: "Abrir una sesión nueva de Codex en Terminal"
        case .shell: "Abrir una pestaña nueva en Terminal"
        }
    }

    // The greeting.
    static let greetingTitle = "¡Hola! Soy Nook."
    static let greetingLede = "Vivo en el notch de tu Mac y vigilo tus terminales por ti."
    static let start = "Empezar"
    static let understood = "Entendido"
    static let greetingHint = "Arrastra el gatito a una ventana de Terminal para conectarla."

    struct Feature: Equatable {
        var symbol: String
        var title: String
        var detail: String
    }
    static let features = [
        Feature(symbol: "terminal", title: "Sigo tus terminales", detail: "Claude Code, Codex o cualquier pestaña de Terminal."),
        Feature(symbol: "bell.badge", title: "Te aviso", detail: "Cuando terminan, preguntan o fallan; el sonido lo eliges tú."),
        Feature(symbol: "text.cursor", title: "Contestas desde aquí", detail: "Escribe, dicta o elige una opción sin cambiar de ventana."),
    ]

    /// The order of the cards.
    static let kinds: [SessionKind] = [.claude, .codex, .shell]
}

extension AppModel {
    /// The greeting is on screen: the first run (nothing opened yet, and it has not been dismissed), or it was asked for again in Ajustes.
    var showsGreeting: Bool { greetingReplay || (!hasBeenWelcomed && sessions.isEmpty) }
}

// MARK: - What fits

/// The home's measures for the room it has: the island's width and its height under the header. The stage takes what the cards leave it, and the lines that do not fit go
/// (the greeting's hint, the line under the title, the cards' second lines) before anything is cut.
struct HomeMetrics: Equatable {
    /// The bezel (5) and the margin the island's other panes keep from its edge (14).
    static let sideInset: CGFloat = 19
    static let topInset: CGFloat = 8
    static let bottomInset: CGFloat = 15
    static let widest: CGFloat = 640
    static let cardGap: CGFloat = 10
    static let heroGap: CGFloat = 16
    /// Where the cat of the home sits across its stage, as a fraction of its width.
    static let homeFraction: CGFloat = 0.4

    var contentWidth: CGFloat
    var stage: CGSize
    /// Points per rig unit for the cat on that stage.
    var scale: CGFloat
    var cardHeight: CGFloat
    /// Between the hero row and the cards.
    var gap: CGFloat
    var showsCardDetail: Bool
    /// The cards are too narrow for everything: they are snug (`snugCard`).
    var snugCards: Bool
    /// The height the content takes (the room is centred around it).
    var height: CGFloat { stage.height + gap + cardHeight }

    /// The least height the cat's stage may have.
    static let leastStage: CGFloat = 58
    static let mostStage: CGFloat = 132
    /// The widest card that is a snug one: the arrow and the second line go, and the tile and the margins shrink, so a name still fits the card.
    static let snugCard: CGFloat = 160
    /// The cat is about 31.4 rig units tall and stands `HomePetView.ground` points up, with a little air over its ears.
    static func scale(stageHeight: CGFloat) -> CGFloat { max(0.8, (stageHeight - HomePetView.ground - 5) / 31.4) }

    /// The scale of the cat on a stage of this size, with its home `homeFraction` of the way across: as big as the height allows, but no bigger than the width lets the whole cat be
    /// (its tail reaches 19.5 rig units to the left of home, and its body, a paw raised to wave or a ball it plays with, up to 22 to the right).
    static func scale(stage: CGSize, homeFraction: CGFloat) -> CGFloat {
        let home = stage.width * homeFraction
        let left = (home - 6) / 19.5, right = (stage.width - home - 6) / PetAnimation.reach.right
        return max(0.8, min(scale(stageHeight: stage.height), left, right))
    }

    static func of(size: CGSize) -> HomeMetrics {
        let room = size.height - topInset - bottomInset
        let contentWidth = min(max(0, size.width - 2 * sideInset), widest)
        let cardWidth = (contentWidth - 2 * cardGap) / 3
        let snug = cardWidth < snugCard
        let detail = cardWidth >= 150
        // From the fullest layout to the leanest: the first whose stage is as big as that layout wants it.
        var chosen: (card: CGFloat, gap: CGFloat, stage: CGFloat) = (44, 8, leastStage)
        let levels: [(card: CGFloat, gap: CGFloat, least: CGFloat)] = [(detail ? 54 : 46, 12, 84), (detail ? 50 : 44, 10, 72), (44, 8, leastStage)]
        for level in levels {
            let left = room - level.card - level.gap
            if left >= level.least { chosen = (level.card, level.gap, min(left, mostStage)); break }
            chosen = (level.card, level.gap, max(leastStage, min(left, level.least)))
        }
        // The cat strolls to the right of its home, so the stage is a good deal wider than the cat.
        let width = min(max(112, chosen.stage * 1.9), 240, max(112, contentWidth - heroGap - 200))
        let stage = CGSize(width: width.rounded(), height: chosen.stage.rounded())
        return HomeMetrics(contentWidth: contentWidth, stage: stage, scale: scale(stage: stage, homeFraction: homeFraction), cardHeight: chosen.card, gap: chosen.gap,
                           showsCardDetail: detail && chosen.card >= 50, snugCards: snug)
    }
}

// MARK: - The cat talks

/// What the cat is saying now, if anything: a few words in a bubble over its stage, which go by themselves.
@MainActor
final class HomeTalk: ObservableObject {
    @Published private(set) var line: String?
    private var task: Task<Void, Never>?

    func say(_ text: String, for seconds: Double = 2.4) {
        line = text
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.line = nil
        }
    }

    /// Stops saying `text` (or whatever it says, with none given).
    func hush(_ text: String? = nil) {
        guard text == nil || line == text else { return }
        task?.cancel()
        line = nil
    }

    deinit { task?.cancel() }
}

/// A speech bubble: a white capsule with a little point toward the cat, as the stage's black shows it.
struct HomeBubble: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(Color.black.opacity(0.86)).lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 4.5)
            .background {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.white).frame(width: 7, height: 7).rotationEffect(.degrees(45)).offset(x: 9, y: 3)
                    Capsule().fill(Color.white)
                }
            }
            .fixedSize()
            .accessibilityHidden(true)
    }
}

// MARK: - The stage

/// The cat's stage: black (it is the island's own black, in a frame, whatever the theme: a white cat would not read on the paper), a soft glow behind the cat, the mat it sits
/// on and a few stars; the cat is `HomePetView`. Where it can talk, a bubble comes out at the top right.
struct HomeStage: View {
    @ObservedObject var model: AppModel
    var size: CGSize
    var scale: CGFloat
    var homeFraction: CGFloat = 0.4
    var lookAt: HomeGaze?
    var greetings = 0
    var cheers = 0
    var still: PetPose?
    @ObservedObject var talk: HomeTalk
    var onHover: (Bool) -> Void = { _ in }
    var onPoke: () -> Void = {}
    @Environment(\.islandSeen) private var seen
    private let gate = NookMotionGate()

    private static let radius: CGFloat = 18

    var body: some View {
        let mint = Color(nsColor: NookPalette.mintOnBlack)
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(Color.black)
                // The glow behind the cat, and the mat it sits on.
                RadialGradient(colors: [mint.opacity(0.2), mint.opacity(0.06), .clear], center: UnitPoint(x: homeFraction, y: 0.62), startRadius: 2, endRadius: size.height * 0.95)
                    .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                Ellipse().fill(LinearGradient(colors: [mint.opacity(0.34), mint.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                    .frame(width: scale * 34, height: max(7, scale * 3.6))
                    .offset(x: size.width * homeFraction - scale * 17, y: -(HomePetView.ground + scale * 1.2 - max(7, scale * 3.6) / 2))
                stars
                HomePetStage(animated: model.animations && model.islandContentVisible && seen && gate.allows, pet: model.pet, scale: scale, homeFraction: homeFraction,
                             lookAt: lookAt, greetings: greetings, cheers: cheers, still: still, controller: model.controller, onHover: onHover, onPoke: onPoke)
            }
            if let line = talk.line {
                HomeBubble(text: line)
                    .padding(.top, 9).padding(.trailing, 11)
                    .transition(gate.allows ? .scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity) : .opacity)
            }
        }
        // The bubble pops out of the cat; with Reduce Motion it fades.
        .animation(gate.allows ? .spring(response: 0.32, dampingFraction: 0.68) : gate.fades ? .easeOut(duration: 0.15) : nil, value: talk.line)
        .frame(width: size.width, height: size.height)
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.75).allowsHitTesting(false))
    }

    /// A few stars, still: the night the cat lives in.
    private var stars: some View {
        ZStack {
            ForEach(Array(Self.starPlaces.enumerated()), id: \.offset) { _, star in
                Circle().fill(Color.white.opacity(star.alpha)).frame(width: star.size, height: star.size)
                    .position(x: size.width * star.x, y: size.height * star.y)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private static let starPlaces: [(x: CGFloat, y: CGFloat, size: CGFloat, alpha: Double)] = [
        (0.12, 0.2, 1.6, 0.34), (0.86, 0.3, 1.3, 0.24), (0.7, 0.14, 1.8, 0.3), (0.93, 0.68, 1.4, 0.2), (0.22, 0.52, 1.2, 0.2), (0.55, 0.1, 1.2, 0.18),
    ]
}

// MARK: - A card

/// One way to start, as a card: an icon tile in the colour of who it opens (terracotta for Claude, Nook's own mint for the plain terminal), its name and a line. The pointer on it
/// lifts it, brightens the tile and leans its arrow out; a click sinks it a little, hops the tile and sends the arrow off up and to the right. While a session is being opened
/// (Terminal takes a second to show its new tab) its arrow is replaced by dots that wave.
struct HomeCard: View {
    var kind: SessionKind
    var height: CGFloat
    var showsDetail: Bool
    /// The card is narrow: a smaller tile and margins, and no arrow.
    var snug = false
    var opening: Bool
    var dimmed: Bool
    var action: () -> Void
    var onHover: (Bool) -> Void
    @State private var hovering = false
    @State private var clicks = 0
    private let gate = NookMotionGate()

    private var tint: Color {
        switch kind { case .claude: Color.nookTerracotta; case .codex: Color.nookInfo; case .shell: Color.nookMint }
    }
    private var tile: Color {
        switch kind { case .claude: Color.nookTerracottaFill; case .codex: Color.nookInfo; case .shell: Color.nookMintFill }
    }
    /// The colour of the dots that wave while the session opens: the tile's, for AppKit.
    private var dotColor: NSColor {
        switch kind { case .claude: NookPalette.terracottaFill; case .codex: NookPalette.info; case .shell: NookPalette.mintFill }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button {
            clicks += 1
            action()
        } label: {
            HStack(spacing: snug ? 8 : 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: snug ? 8 : 9, style: .continuous).fill(tile.opacity(hovering ? 0.3 : 0.18))
                    Image(systemName: kind.symbol).font(.system(size: snug ? 11.5 : 13, weight: .semibold)).foregroundStyle(tint)
                }.frame(width: snug ? 26 : 30, height: snug ? 26 : 30).clickMotion(.pop, trigger: clicks)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.system(size: snug ? 11.5 : 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    if showsDetail { Text(HomeCopy.detail(kind)).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).lineLimit(1) }
                }
                Spacer(minLength: snug ? 0 : 4)
                if opening {
                    OpeningDots(color: dotColor)
                } else if !snug {
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovering ? tint : Color.nookTertiary)
                        .offset(x: hovering ? 1.5 : 0, y: hovering ? -1.5 : 0)
                        .clickMotion(.nudgeUpRight, trigger: clicks)
                }
            }
            .padding(.horizontal, snug ? 9 : 11).frame(maxWidth: .infinity).frame(height: height)
            .nookGlassSurface(in: shape, interactive: true, dim: 0.55, dimColor: Color.nookCard, fill: Color.nookCard, stroke: Color.nookWash(hovering ? 0.16 : 0.1, light: hovering ? 0.2 : 0.12))
            .contentShape(shape)
            .offset(y: hovering && gate.allows ? -1.5 : 0)
            .shadow(color: Color.nookShadow(hovering ? 0.3 : 0.16), radius: hovering ? 7 : 3, y: hovering ? 3 : 1)
        }
        .buttonStyle(NookPressStyle(motion: .none, depth: PressDepth.card))
        .animation(gate.allows ? .easeOut(duration: 0.16) : nil, value: hovering)
        .onHover { inside in hovering = inside; onHover(inside) }
        .opacity(dimmed ? 0.55 : 1)
        .accessibilityLabel(HomeCopy.spoken(kind))
        .accessibilityValue(opening ? HomeCopy.opening : "")
    }
}

/// Three dots that rise and fall in turn while something is on its way, in the card's colour: the header's working dots (`WorkingDotsView`, an AppKit view on its own
/// clock), so they cost nothing through the island's hosting view, hold still with the motion off and stop while nobody can see the island.
private struct OpeningDots: View {
    var color: NSColor
    @Environment(\.islandSeen) private var seen
    private let gate = NookMotionGate()

    var body: some View {
        WorkingDots(waving: gate.allows, running: seen, color: color).frame(width: WorkingDotsView.side, height: WorkingDotsView.side).accessibilityHidden(true)
    }
}

// MARK: - The home

struct HomeView: View {
    @ObservedObject var model: AppModel
    /// The hour the greeting line goes by; the clock's, unless a preview or a test gives one.
    var hour: Int?
    /// A pose to draw for the cat instead of a living one: previews and renders.
    var staticCat: PetPose?
    @StateObject private var talk = HomeTalk()
    @State private var lookAt: HomeGaze?
    @State private var cheers = 0
    @State private var opening: SessionKind?
    @State private var appeared = false
    private let gate = NookMotionGate()

    init(model: AppModel, hour: Int? = nil, staticCat: PetPose? = nil) {
        self.model = model
        self.hour = hour
        self.staticCat = staticCat
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = HomeMetrics.of(size: geometry.size)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: metrics.gap) {
                    HStack(alignment: .center, spacing: HomeMetrics.heroGap) {
                        HomeStage(model: model, size: metrics.stage, scale: metrics.scale, homeFraction: HomeMetrics.homeFraction, lookAt: lookAt, cheers: cheers, still: staticCat, talk: talk,
                                  onHover: stageHover, onPoke: poked)
                        words(height: metrics.stage.height)
                    }
                    HStack(spacing: HomeMetrics.cardGap) {
                        ForEach(Array(HomeCopy.kinds.enumerated()), id: \.element) { index, kind in
                            HomeCard(kind: kind, height: metrics.cardHeight, showsDetail: metrics.showsCardDetail, snug: metrics.snugCards, opening: opening == kind, dimmed: opening != nil && opening != kind,
                                     action: { start(kind) }, onHover: { inside in aim(at: index, inside) })
                                // One after another they rise into place; with Reduce Motion they only fade in, in the same order.
                                .offset(y: appeared || !gate.allows ? 0 : 10).opacity(appeared || !gate.fades ? 1 : 0)
                                .animation(gate.allows ? .spring(response: 0.42, dampingFraction: 0.8).delay(0.05 * Double(index) + 0.08)
                                           : gate.fades ? .easeOut(duration: 0.2).delay(0.05 * Double(index) + 0.08) : nil, value: appeared)
                        }
                    }
                }.frame(width: metrics.contentWidth)
                Spacer(minLength: 0)
            }
            .padding(.top, HomeMetrics.topInset).padding(.bottom, HomeMetrics.bottomInset)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear { appeared = true }
        // Terminal takes a moment to show its new tab (the home goes with the first one); if nothing came of it (a refused permission), the cards are free again.
        .task(id: opening) {
            guard let kind = opening else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled, opening == kind { opening = nil }
        }
        .accessibilityElement(children: .contain)
    }

    /// The line, the way to follow a terminal that is open, and the tip about the cat: they give way (the tip first) when the stage leaves them little room.
    private func words(height: CGFloat) -> some View {
        let overline = HomeCopy.overline(hour: hour ?? Calendar.current.component(.hour, from: Date()))
        return ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 0) {
                Text(overline.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(Color.nookSecondary)
                title.padding(.top, 3)
                Text(HomeCopy.subtitle).font(.system(size: 11)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                connectButton.padding(.top, 10)
                Label(HomeCopy.dragHint, systemImage: "hand.draw").font(.system(size: 9.5)).foregroundStyle(Color.nookTertiary).labelStyle(.titleAndIcon).padding(.top, 7)
            }
            VStack(alignment: .leading, spacing: 0) {
                title
                Text(HomeCopy.subtitle).font(.system(size: 11)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                connectButton.padding(.top, 9)
            }
            VStack(alignment: .leading, spacing: 8) {
                title
                connectButton
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
    }

    private var title: some View {
        Text(HomeCopy.title).font(.system(size: 21, weight: .semibold, design: .rounded)).tracking(-0.3).lineLimit(1).minimumScaleFactor(0.8)
    }

    private var connectButton: some View {
        HomeConnectButton(action: { model.showConnections() }, onHover: { inside in lookAt = inside ? HomeGaze(dx: 1, dy: 0.1) : nil })
    }

    // MARK: What happens

    private func start(_ kind: SessionKind) {
        guard opening == nil else { return }
        opening = kind
        cheers += 1
        talk.hush()
        model.create(kind)
    }

    private func aim(at index: Int, _ inside: Bool) {
        guard inside else { lookAt = nil; return }
        // The cards are under the cat: it looks down, and further to the right the further along the card is.
        lookAt = HomeGaze(dx: [CGFloat(0.25), 0.7, 1][min(index, 2)], dy: -0.9)
    }

    private func stageHover(_ over: Bool) {
        if over { talk.say(HomeCopy.bubbleDrag, for: 4) } else { talk.hush(HomeCopy.bubbleDrag) }
    }

    private func poked() { talk.say(HomeCopy.meows.randomElement() ?? "¡Miau!", for: 1.8) }
}

/// «Conectar una terminal que ya uso»: a small pill that lights as the pointer comes onto it.
struct HomeConnectButton: View {
    var action: () -> Void
    var onHover: (Bool) -> Void
    @State private var hovering = false
    @State private var clicks = 0

    var body: some View {
        Button {
            clicks += 1
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "link").font(.system(size: 10.5, weight: .semibold)).clickMotion(.spin, trigger: clicks)
                ViewThatFits(in: .horizontal) {
                    Text(HomeCopy.connect).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(HomeCopy.connectShort).font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
            }
            .foregroundStyle(Color.primary.opacity(0.88))
            .padding(.horizontal, 11).frame(height: 26)
            .background(Color.nookWash(hovering ? 0.13 : 0.075, light: hovering ? 0.13 : 0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(NookPressStyle(motion: .none, depth: PressDepth.card))
        .onHover { inside in hovering = inside; onHover(inside) }
        .help("Elige una pestaña de Terminal que ya tengas abierta para seguirla aquí")
    }
}

// MARK: - The greeting

/// The first time Nook runs: the cat waves and says who it is and what it does. «Empezar» ends it for good (`AppModel.markWelcomed`) and leaves the home; asked for again from
/// Ajustes (the island may have tabs by then) it closes with «Entendido» and gives the island back.
struct GreetingView: View {
    @ObservedObject var model: AppModel
    /// A pose to draw for the cat instead of a living one: previews and renders.
    var staticCat: PetPose?
    @StateObject private var talk = HomeTalk()
    @State private var greetings = 0
    @State private var appeared = false
    private let gate = NookMotionGate()

    init(model: AppModel, staticCat: PetPose? = nil) {
        self.model = model
        self.staticCat = staticCat
    }

    /// Whether the greeting is a replay over an island that has tabs.
    private var isReplay: Bool { model.greetingReplay }

    var body: some View {
        GeometryReader { geometry in
            let room = CGSize(width: geometry.size.width - 2 * HomeMetrics.sideInset, height: geometry.size.height - HomeMetrics.topInset - HomeMetrics.bottomInset)
            let stageHeight = min(max(room.height, HomeMetrics.leastStage), 160)
            let stage = CGSize(width: min(max(120, stageHeight * 1.12), 190), height: stageHeight)
            // Beside the button the hint has what the text column leaves it: a narrow column puts it under the button.
            let tight = min(room.width, 640) - stage.width - 20 < 300
            HStack(alignment: .center, spacing: 20) {
                HomeStage(model: model, size: stage, scale: HomeMetrics.scale(stage: stage, homeFraction: 0.5), homeFraction: 0.5, greetings: greetings, still: staticCat, talk: talk)
                content(tight: tight)
            }
            .frame(width: min(room.width, 640), height: room.height)
            .padding(.top, HomeMetrics.topInset).padding(.bottom, HomeMetrics.bottomInset)
            .frame(width: geometry.size.width, height: geometry.size.height)
            // It rises into place; with Reduce Motion it only fades in.
            .opacity(appeared || !gate.fades ? 1 : 0).offset(y: appeared || !gate.allows ? 0 : 8)
            .animation(gate.fades ? .easeOut(duration: 0.32) : nil, value: appeared)
        }
        .onAppear { appeared = true }
        .task {
            // The island's content comes on a moment after it opens: the cat waves once it is there, and again if the user stays. A cat that is asleep (Nook opened at night) is
            // woken first, gently, and waves when it is up.
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            if model.petBedtime.wake(.greeting) {
                try? await Task.sleep(for: .seconds(PetAnimation.wakeLength() + 0.8))
                guard !Task.isCancelled else { return }
            }
            greet()
            try? await Task.sleep(for: .seconds(9))
            guard !Task.isCancelled else { return }
            greeted()
        }
        .accessibilityElement(children: .contain)
    }

    private func greet() {
        greetings += 1
        talk.say(HomeCopy.bubbleHello, for: 3.2)
    }
    private func greeted() { greetings += 1 }

    private func content(tight: Bool) -> some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 0) {
                heading
                features.padding(.top, 12)
                actions(tight: tight).padding(.top, 14)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(HomeCopy.greetingTitle).font(.system(size: 21, weight: .semibold, design: .rounded)).tracking(-0.3)
                features.padding(.top, 10)
                actions(tight: tight).padding(.top, 12)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(HomeCopy.greetingTitle).font(.system(size: 19, weight: .semibold, design: .rounded)).tracking(-0.3)
                actions(tight: tight)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(HomeCopy.greetingTitle).font(.system(size: 22, weight: .semibold, design: .rounded)).tracking(-0.3).lineLimit(1).minimumScaleFactor(0.8)
            Text(HomeCopy.greetingLede).font(.system(size: 11.5)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var features: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) { ForEach(HomeCopy.features, id: \.title) { FeatureTile(feature: $0, compact: false) } }
            VStack(alignment: .leading, spacing: 7) { ForEach(HomeCopy.features, id: \.title) { FeatureTile(feature: $0, compact: true) } }
        }
    }

    /// The button, and beside it (under it, when the column is narrow) how else to connect.
    private func actions(tight: Bool) -> some View {
        let button = GreetingButton(title: isReplay ? HomeCopy.understood : HomeCopy.start, action: dismiss)
        let hint = Label(HomeCopy.greetingHint, systemImage: "hand.draw").font(.system(size: 9.5)).foregroundStyle(Color.nookTertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        return Group {
            if tight {
                VStack(alignment: .leading, spacing: 8) { button; if !isReplay { hint } }
            } else {
                HStack(spacing: 10) { button; if !isReplay { hint } }
            }
        }
    }

    private func dismiss() {
        // A fade to what was under it, which Reduce Motion keeps.
        withAnimation(gate.fades ? .easeInOut(duration: 0.25) : nil) {
            model.markWelcomed()
            model.greetingReplay = false
        }
    }
}

/// One thing Nook does, in the greeting: a symbol, what it is in a few words and a line about it.
private struct FeatureTile: View {
    var feature: HomeCopy.Feature
    var compact: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        Group {
            if compact {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: feature.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.nookMint).frame(width: 16, height: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(feature.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(feature.detail).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: feature.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.nookMint)
                    Text(feature.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(feature.detail).font(.system(size: 9.5)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color.nookCard, in: shape)
                .overlay(shape.strokeBorder(Color.nookWash(0.1, light: 0.12), lineWidth: 0.75))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The greeting's one button: Nook's mint, with the label in the colour that reads on it, and a little arrow that leans out as the pointer comes.
private struct GreetingButton: View {
    var title: String
    var action: () -> Void
    @State private var hovering = false
    @State private var clicks = 0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            clicks += 1
            action()
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).offset(x: hovering ? 2 : 0).clickMotion(.nudgeRight, trigger: clicks)
            }
            .foregroundStyle(scheme == .dark ? Color.black.opacity(0.85) : Color.white)
            .padding(.horizontal, 15).frame(height: 30)
            .background((scheme == .dark ? Color.nookMintFill : Color.nookMint).opacity(hovering ? 1 : 0.94), in: Capsule())
            .contentShape(Capsule())
            .shadow(color: Color.nookMintFill.opacity(hovering ? 0.4 : 0.2), radius: hovering ? 8 : 4, y: 2)
        }
        .buttonStyle(NookPressStyle(motion: .none, depth: PressDepth.card))
        .animation(.easeOut(duration: 0.14), value: hovering)
        .onHover { hovering = $0 }
        .keyboardShortcut(.defaultAction)
    }
}
