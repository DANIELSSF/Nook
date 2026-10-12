import SwiftUI
import AppKit
import Combine

// The cue that screen vision took a picture of the screen. Claude decides some of those on its own, so the user is told each time, in the island itself and
// in either of its states: a small pill that hangs under the island (the collapsed one or the open one), says it in a line, and goes after a few seconds.
// It takes no clicks and no keys, and it comes after the picture is taken, so it is never in one (and Nook's windows are left out of every picture anyway).
//
//   ScreenVisionCueStyle   what the cue says, in what colour and for how long (plain values)
//   ScreenVisionCuePill    the pill: an eye that settles, and the words. Terracotta when it was Claude who looked (in Nook a colour says who is speaking:
//                          terracotta is Claude's), the tab's colour when it was the user's own message that carried the screen
//   ScreenVisionCue        the window that holds it under the island, where it goes (`frame`) and how long it stays
//
// The message's own capture is also told where the user is looking: the composer's chip flashes once (`ScreenVisionChip`).

// MARK: - What it says

struct ScreenVisionCueStyle: Equatable {
    var origin: ScreenVisionOrigin
    var title: String
    /// A capture of several displays says how many, so it does not pass for one.
    var detail: String?
    var symbol: String
    /// How long it stays.
    var hold: TimeInterval

    /// Claude's own look stays long enough to be read; the user's message, which they just sent, only needs to be acknowledged.
    static let claudeHold: TimeInterval = 3.6
    static let composerHold: TimeInterval = 2.0

    init(_ capture: ScreenVisionCapture) {
        origin = capture.origin
        title = capture.cue
        detail = capture.shots.count > 1 ? "\(capture.shots.count) pantallas" : nil
        symbol = "eye"
        hold = capture.origin == .claude ? Self.claudeHold : Self.composerHold
    }

    /// What VoiceOver says: the cue is announced as it comes, since it goes by itself.
    var spoken: String { detail.map { "\(title). \($0)" } ?? title }

    /// Claude's own look wears Claude's terracotta; the user's wears the colour of their tab.
    func color(tint: TabTint) -> Color { origin == .claude ? claudeSpinner : tint.voice.marker.color }
}

// MARK: - The pill

/// What the window shows: the cue now, which tab's colour the user's own would wear, and whether it is on its way out. A new cue is a new pill.
final class ScreenVisionCueState: ObservableObject {
    @Published var style: ScreenVisionCueStyle?
    @Published var tint = TabTint.mint
    @Published var leaving = false
    @Published var serial = 0
    /// The app's animation preference; Reduce Motion is read by the views.
    var animated = true
}

struct ScreenVisionCuePill: View {
    var style: ScreenVisionCueStyle
    var tint: TabTint
    /// The cue is on its way out.
    var leaving = false
    var motion = true
    @State private var entered: Bool
    @State private var settled: Bool

    static let height: CGFloat = 28
    static let eye: CGFloat = 20

    /// `entered` starts the pill already in (render tests and previews); without motion it always is.
    init(style: ScreenVisionCueStyle, tint: TabTint, leaving: Bool = false, motion: Bool = true, entered: Bool = false) {
        self.style = style
        self.tint = tint
        self.leaving = leaving
        self.motion = motion
        _entered = State(initialValue: entered || !motion)
        _settled = State(initialValue: entered || !motion)
    }

    var body: some View {
        let color = style.color(tint: tint)
        let shown = entered && !leaving
        // Not a `Capsule`: stroked, it leaves a short tick at each end where its arcs meet no straight side.
        let shape = RoundedRectangle(cornerRadius: Self.height / 2, style: .circular)
        HStack(spacing: 7) {
            eye(color)
            HStack(spacing: 5) {
                Text(style.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.nookWash(0.95))
                if let detail = style.detail {
                    Text("·").font(.system(size: 11.5)).foregroundStyle(Color.nookWash(0.4))
                    Text(detail).font(.system(size: 11)).foregroundStyle(Color.nookWash(0.66))
                }
            }
        }
        .lineLimit(1).fixedSize()
        .padding(.leading, 4).padding(.trailing, 13).frame(height: Self.height)
        .background(Color.black, in: shape)
        // The edge starts bright and settles with the eye.
        .overlay(shape.strokeBorder(color.opacity(settled ? 0.45 : 0.95), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.5), radius: 9, y: 3)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown || !motion ? 1 : 0.94, anchor: .top)
        .offset(y: shown || !motion ? 0 : -5)
        .animation(motion ? .easeOut(duration: leaving ? 0.3 : 0.2) : nil, value: shown)
        .onAppear {
            entered = true
            if motion { withAnimation(.easeOut(duration: 0.9)) { settled = true } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.spoken)
    }

    /// The eye in a disc of the cue's colour, a little larger and brighter as it comes, then settling.
    private func eye(_ color: Color) -> some View {
        ZStack {
            Circle().fill(color.opacity(settled ? 0.2 : 0.4))
            Image(systemName: style.symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color).scaleEffect(settled ? 1 : 1.2)
        }.frame(width: Self.eye, height: Self.eye)
    }
}

/// The window's content: the pill centred in room that is larger than it, so the pill's own width never has to be measured.
struct ScreenVisionCueRoot: View {
    @ObservedObject var state: ScreenVisionCueState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let style = state.style {
                ScreenVisionCuePill(style: style, tint: state.tint, leaving: state.leaving, motion: state.animated && !reduceMotion).id(state.serial)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The window

/// What the cue needs of the island that carries it. `NotchController` is the real one; tests pass their own, so no test touches the real island.
protocol ScreenVisionCueHost: AnyObject {
    var cueModel: AppModel { get }
    /// The island as it stands now, collapsed or open, in screen coordinates, and the screen it is on.
    var cueIsland: CGRect { get }
    var cueScreen: CGRect { get }
    /// How far something that hangs under the collapsed island (an alert's peek) takes it lower.
    var cueDrop: CGFloat { get }
    /// A window under the island that the pill must not cover (the settings card).
    var cueAvoids: CGRect? { get }
    var cueLevel: NSWindow.Level { get }
}

/// Shows the pill under the island while a capture is fresh. Nothing runs between captures: no timer, no animation, no window on screen.
final class ScreenVisionCue {
    /// The window is larger than the pill and transparent, and ignores the pointer: the pill sits in the middle of it.
    static let windowSize = CGSize(width: 380, height: 62)
    /// Between the island's bottom edge and the pill's top edge.
    static let gap: CGFloat = 6
    /// Kept between the pill and the screen's edges.
    static let margin: CGFloat = 8
    static let leaveSeconds = 0.35

    private weak var host: ScreenVisionCueHost?
    private let holdScale: Double
    private let state = ScreenVisionCueState()
    private var panel: NotchPanel?
    private var hideWork: DispatchWorkItem?
    private var goneWork: DispatchWorkItem?
    private var watches: [AnyCancellable] = []

    /// `holdScale` shortens the times, for tests.
    init(host: ScreenVisionCueHost, holdScale: Double = 1) {
        self.host = host
        self.holdScale = holdScale
        let model = host.cueModel
        watches.append(model.screenVision.$lastCapture.compactMap { $0 }.receive(on: DispatchQueue.main).sink { [weak self] in self?.present($0) })
        // The island opening or closing under the pill, or an alert's peek growing from the collapsed one, moves where it hangs.
        watches.append(model.$expanded.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reposition() })
        watches.append(model.$alert.map { $0?.id }.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reposition() })
    }

    deinit { cancel() }

    /// The pill is on screen (or on its way out).
    var isShowing: Bool { panel?.isVisible == true && state.style != nil }
    var style: ScreenVisionCueStyle? { state.style }
    var windowFrame: CGRect? { panel?.frame }
    /// What the tests look at: the window, whether the pill is on its way out, whether it moves, the colour a message's wears, and how many cues there have been.
    var window: NSPanel? { panel }
    var isLeaving: Bool { state.leaving }
    var animates: Bool { state.animated }
    var tint: TabTint { state.tint }
    var count: Int { state.serial }

    /// Where the window goes: centred under the island, the pill `gap` below its bottom edge (or below what hangs from it), kept on the screen. With no
    /// room under the island the pill sits over its lower part instead, as the settings card does.
    static func frame(window: CGSize = windowSize, island: CGRect, screen: CGRect, avoiding: CGRect? = nil, extraDrop: CGFloat = 0) -> CGRect {
        let edge = min(island.minY, avoiding?.minY ?? island.minY) - extraDrop
        let room = (window.height - ScreenVisionCuePill.height) / 2
        let x = min(max(island.midX - window.width / 2, screen.minX + margin), screen.maxX - margin - window.width)
        let y = max(edge - gap + room - window.height, screen.minY + margin - room)
        return CGRect(x: x, y: y, width: window.width, height: window.height)
    }

    func present(_ capture: ScreenVisionCapture) {
        guard let host else { return }
        hideWork?.cancel(); goneWork?.cancel()
        let style = ScreenVisionCueStyle(capture)
        state.animated = host.cueModel.animations
        state.tint = host.cueModel.selected?.tint ?? .mint
        state.leaving = false
        state.style = style
        state.serial += 1
        let panel = ensurePanel(host)
        place(panel, host)
        panel.orderFrontRegardless()
        Self.announce(style)
        let work = DispatchWorkItem { [weak self] in self?.leave() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + style.hold * holdScale, execute: work)
    }

    /// The pill goes: it fades, and the window is put away once it has.
    private func leave() {
        guard state.style != nil else { return }
        state.leaving = true
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        goneWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaveSeconds * max(holdScale, 0.05), execute: work)
    }

    /// Puts the cue away at once (the screen changed under it).
    func cancel() {
        hideWork?.cancel(); goneWork?.cancel()
        hideWork = nil; goneWork = nil
        finish()
    }

    private func finish() {
        panel?.orderOut(nil)
        state.leaving = false
        state.style = nil
    }

    /// The island it hangs from moved (opened, closed, or took the size a card asked for): the pill goes where it hangs now.
    func reposition() {
        guard isShowing, let host, let panel else { return }
        place(panel, host)
    }

    private func place(_ panel: NotchPanel, _ host: ScreenVisionCueHost) {
        let frame = Self.frame(island: host.cueIsland, screen: host.cueScreen, avoiding: host.cueAvoids, extraDrop: host.cueDrop)
        if panel.frame != frame { panel.setFrame(frame, display: panel.isVisible) }
    }

    private func ensurePanel(_ host: ScreenVisionCueHost) -> NotchPanel {
        if let panel { panel.level = host.cueLevel; return panel }
        let panel = NotchPanel(contentRect: CGRect(origin: .zero, size: Self.windowSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.capturePrivacy = host.cueModel.capturePrivacy
        panel.allowsKey = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.level = host.cueLevel
        let hosting = NSHostingView(rootView: ScreenVisionCueRoot(state: state).environment(\.colorScheme, .dark))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    /// A cue that goes by itself cannot wait for VoiceOver to reach it: it is read out as it comes.
    private static func announce(_ style: ScreenVisionCueStyle) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: style.spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

extension NotchController: ScreenVisionCueHost {
    var cueModel: AppModel { model }
    var cueIsland: CGRect { model.expanded ? panel.frame : compactFrame }
    var cueScreen: CGRect { screen.frame }
    /// An alert's peek grows the collapsed island downward by its chin.
    var cueDrop: CGFloat { model.expanded || peekingAlert == nil ? 0 : AlertPeekLayout(compact: compactFrame.size).chin }
    var cueAvoids: CGRect? { settingsCardFrame }
    /// Above the island's own panels, as the agent pill's tooltip is.
    var cueLevel: NSWindow.Level { NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2) }
}
