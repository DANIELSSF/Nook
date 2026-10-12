import SwiftUI
import AppKit

// The question before quitting, in the island (`AppModel.quitPrompt`): "¿Seguro que quieres salir?", asked by a sad cat.
//
// The island's content is dimmed under a scrim and the question is a card over it, so the user's eyes have one place to go: the cat (the same cat, drooped: `PetAnimation.sad`),
// the question, what quitting does and does not do (`QuitAlert.detail`), and two buttons, «Quedarme» (the default: Enter, Esc and a click on the scrim all mean it) and «Salir»
// (the destructive one). A hint says that ⌘Q again quits, which is what the model does with it (`AppModel.shouldTerminate`).
//
// It comes in with a short fade of the scrim and a spring of the card, and goes with a fade; with Reduce Motion it only fades. The keyboard goes to the question while it is up
// (`QuitKeys`), and back to where it was (the message field, usually) when it goes.

// MARK: - Words

enum QuitCopy {
    static let stay = "Quedarme"
    static let quit = "Salir"
    static let hint = "Pulsa ⌘Q otra vez para salir"
    /// What VoiceOver says when the question appears.
    static let spoken = QuitAlert.question + " " + QuitAlert.detail
}

// MARK: - The card

struct QuitPromptView: View {
    /// How the user dressed the cat (`AppModel.pet`): the sad cat is theirs.
    var look = PetLook()
    var stay: () -> Void
    var quit: () -> Void
    /// The cat holds still (previews and renders).
    var stillCat = false
    @State private var appeared = false
    @Environment(\.colorScheme) private var scheme
    private let gate = NookMotionGate()

    /// The card's width: its own, or what the island leaves.
    static let width: CGFloat = 438

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // The island's content, dimmed. A click on it is the same as «Quedarme»: the question is gone and nothing else happened.
                Color.black.opacity(scheme == .dark ? 0.64 : 0.46)
                    .contentShape(Rectangle())
                    .onTapGesture { stay() }
                    .pointerHole()
                    .accessibilityHidden(true)
                card(in: geometry.size)
                    .scaleEffect(appeared || !gate.allows ? 1 : 0.93)
                    .offset(y: appeared || !gate.allows ? 0 : 8)
                    .opacity(appeared || !gate.allows ? 1 : 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(QuitKeys(onStay: stay))
        .onAppear {
            withAnimation(gate.allows ? .spring(response: 0.42, dampingFraction: 0.78) : .easeOut(duration: 0.12)) { appeared = true }
        }
    }

    private func card(in size: CGSize) -> some View {
        let width = min(Self.width, max(300, size.width - 40))
        // The cat's stage gives up height before the card is cut: in the smallest island the card has about 150 points.
        let stage = CGSize(width: size.height < 215 ? 108 : 124, height: size.height < 215 ? 92 : 108)
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return HStack(alignment: .center, spacing: 16) {
            SadStage(size: stage, look: look, still: stillCat)
            VStack(alignment: .leading, spacing: 0) {
                Text(QuitAlert.question).font(.system(size: 16, weight: .semibold, design: .rounded)).tracking(-0.2).fixedSize(horizontal: false, vertical: true)
                Text(QuitAlert.detail).font(.system(size: 11)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true).padding(.top, 5)
                HStack(spacing: 8) {
                    StayButton(action: stay)
                    QuitButton(action: quit)
                }.padding(.top, 12)
                HStack(spacing: 5) {
                    Text("Pulsa").font(.system(size: 9.5))
                    KeyCap(text: "⌘Q")
                    Text("otra vez para salir").font(.system(size: 9.5))
                }.foregroundStyle(Color.nookTertiary).padding(.top, 9)
                    .accessibilityElement(children: .ignore).accessibilityLabel(QuitCopy.hint)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(width: width)
        .background(Color.nookCardRaised, in: shape)
        .overlay(shape.strokeBorder(Color.nookWash(0.12, light: 0.14), lineWidth: 0.75))
        .shadow(color: Color.black.opacity(scheme == .dark ? 0.55 : 0.28), radius: 26, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(QuitCopy.spoken)
    }
}

/// The sad cat's stage: black, as the home's is (a white cat does not read on the paper), with a cold glow where the home's is mint, and the cat on it.
private struct SadStage: View {
    var size: CGSize
    var look: PetLook
    var still: Bool
    @Environment(\.islandSeen) private var seen
    private let gate = NookMotionGate()

    var body: some View {
        let cold = Color(nsColor: NookPalette.info)
        let scale = max(1.4, min((size.height - HeaderPetView.ground - 8) / 31.4, (size.width - 16) / PetAnimation.sadReach))
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black)
            RadialGradient(colors: [cold.opacity(0.2), cold.opacity(0.05), .clear], center: UnitPoint(x: 0.5, y: 0.6), startRadius: 2, endRadius: size.height * 0.9)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            SadCatStage(animated: !still && gate.allows && seen, look: look, scale: scale)
        }
        .frame(width: size.width, height: size.height)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.75).allowsHitTesting(false))
    }
}

/// «Quedarme»: the default. Nook's mint, with the label in the colour that reads on it.
private struct StayButton: View {
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
                Image(systemName: "heart.fill").font(.system(size: 10, weight: .semibold)).clickMotion(.pulse, trigger: clicks)
                Text(QuitCopy.stay).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(scheme == .dark ? Color.black.opacity(0.85) : Color.white)
            .padding(.horizontal, 16).frame(height: 30)
            .background((scheme == .dark ? Color.nookMintFill : Color.nookMint).opacity(hovering ? 1 : 0.94), in: Capsule())
            .contentShape(Capsule())
            .shadow(color: Color.nookMintFill.opacity(hovering ? 0.42 : 0.22), radius: hovering ? 8 : 4, y: 2)
        }
        .buttonStyle(NookPressStyle(motion: .none, depth: PressDepth.card))
        .animation(.easeOut(duration: 0.14), value: hovering)
        .onHover { hovering = $0 }
        .keyboardShortcut(.defaultAction)
        .accessibilityHint("Cierra la pregunta y deja Nook abierto")
    }
}

/// «Salir»: the destructive one. A coral outline and wash, so it reads as the way out and not as the way on.
private struct QuitButton: View {
    var action: () -> Void
    @State private var hovering = false
    @State private var clicks = 0

    var body: some View {
        Button {
            clicks += 1
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "power").font(.system(size: 10, weight: .semibold)).clickMotion(.pop, trigger: clicks)
                Text(QuitCopy.quit).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.nookCoral)
            .padding(.horizontal, 14).frame(height: 30)
            // A circular capsule: the continuous one's stroke leaves a tick at each end.
            .background(Color.nookCoralFill.opacity(hovering ? 0.2 : 0.11), in: Capsule(style: .circular))
            .overlay(Capsule(style: .circular).strokeBorder(Color.nookCoralFill.opacity(hovering ? 0.6 : 0.38), lineWidth: 0.9))
            .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(NookPressStyle(motion: .none, depth: PressDepth.card))
        .animation(.easeOut(duration: 0.14), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityHint("Cierra Nook; tus terminales siguen abiertas")
    }
}

/// A key on the keyboard, as a hint says it: «⌘Q» in a small rounded cap.
struct KeyCap: View {
    var text: String

    var body: some View {
        Text(text).font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundStyle(Color.nookSecondary)
            .padding(.horizontal, 5).frame(height: 15)
            .background(Color.nookWash(0.07, light: 0.06), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous).strokeBorder(Color.nookWash(0.16, light: 0.16), lineWidth: 0.6))
    }
}

// MARK: - The keyboard

/// Takes the keyboard for the question while it is up, so Enter and Esc reach it whatever the island had under it (the message field takes Enter as «send»), and gives it
/// back to what had it when the question goes. It draws nothing and takes no clicks.
private struct QuitKeys: NSViewRepresentable {
    var onStay: () -> Void

    func makeNSView(context: Context) -> QuitKeyView { QuitKeyView() }
    func updateNSView(_ view: QuitKeyView, context: Context) { view.onStay = onStay }
}

final class QuitKeyView: NSView {
    var onStay: (() -> Void)?
    private weak var previous: NSResponder?

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // After this pass: SwiftUI is still putting the view in its place.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, window.firstResponder !== self else { return }
            let held = window.firstResponder
            self.previous = held === window ? nil : held
            window.makeFirstResponder(self)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, window.firstResponder === self {
            // The question is gone: the keyboard goes back to the field it was in, if that is still there.
            if let previous = previous as? NSView, previous.window === window { window.makeFirstResponder(previous) } else { window.makeFirstResponder(nil) }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 53: onStay?()   // Return, Enter and Esc
        default: break   // nothing else is for the field behind the question
        }
    }

    override func cancelOperation(_ sender: Any?) { onStay?() }
}
