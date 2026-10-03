import SwiftUI

// Liquid Glass for Nook, kept small on purpose.
//
// The island itself stays solid black and attached to the notch; glass is only used on a handful of surfaces that
// sit on top of it, the way System Settings uses it on macOS 26:
//
//   - floating cards and sheets (notice, joined-message warning, subagent list, recap card, connection sheet),
//   - the message field and the send button (the button lights up as tinted glass once there is text to send),
//   - the selected session tab (tinted with the session's color),
//   - the header icon buttons, which only show a glass disc while the pointer is over them.
//
// Everything falls back to the exact flat look Nook had before (`Color.white.opacity(0.055)` fills, hairline
// strokes, `Color(white: 0.115)` cards) when any of these is true:
//
//   - the Mac runs an OS older than macOS 26 (the package still deploys to macOS 14),
//   - Reduce Transparency or Increase Contrast is on,
//   - the surface floats over the terminal mirror and the mirror is light (see `nookDarkBackdrop`; the panel's mirror
//     now sits straight on the island's black, so it always counts as dark).
//
// Call sites: `nookGlassCard` (notice, joined warning, connection sheet in PanelView.swift; `SubagentList`; the recap
// card with `nookScrollFade`), `nookGlassSurface` (message field, send button, session tabs, welcome tiles) and
// `nookGlassButton` (`IconButton`). The island's content sets `\.nookDarkBackdrop` once. Each is a drop-in for the
// `.background(...)`/`.overlay(...)` pair or the `.buttonStyle(.plain)` it replaces.

// MARK: - Backdrop

private struct NookDarkBackdropKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether what shows behind the island's floating cards is dark. A light backdrop would turn glass light and wash
    /// out the island's white text, so cards that float over the mirror keep their solid fill unless this is true.
    /// The panel's mirror has no card of its own and sits on the island's black in every system appearance, so
    /// `NookPanel` sets it to true once on the island's content. Defaults to false, so a missing call keeps the solid look.
    var nookDarkBackdrop: Bool {
        get { self[NookDarkBackdropKey.self] }
        set { self[NookDarkBackdropKey.self] = newValue }
    }
}

private struct NookTintedGlassKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether glass may be tinted. True everywhere but in the offscreen renders made for review (`PanelRenderTests`),
    /// where a tinted glass surface (the send button with text to send) leaves the whole image empty; they turn it off.
    var nookTintedGlass: Bool {
        get { self[NookTintedGlassKey.self] }
        set { self[NookTintedGlassKey.self] = newValue }
    }
}

/// The conditions under which glass may be used, read from the environment.
private struct NookGlassGate: DynamicProperty {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nookDarkBackdrop) private var darkBackdrop

    /// `overMirror` is true for surfaces that can sit on top of the terminal mirror's text or light background.
    func allows(overMirror: Bool) -> Bool {
        !reduceTransparency && contrast != .increased && (!overMirror || darkBackdrop)
    }
}

// MARK: - Surface

private struct NookGlassSurface<S: Shape, F: ShapeStyle>: ViewModifier {
    var shape: S
    var tint: Color?
    var isActive: Bool
    var interactive: Bool
    var dim: Double
    var dimColor: Color
    var overMirror: Bool
    var clipsContent: Bool
    var fill: F
    var stroke: Color?
    var strokeShape: AnyShape?
    private var gate = NookGlassGate()
    @Environment(\.nookTintedGlass) private var tintedGlass

    init(shape: S, tint: Color?, isActive: Bool, interactive: Bool, dim: Double, dimColor: Color, overMirror: Bool, clipsContent: Bool, fill: F, stroke: Color?, strokeShape: AnyShape?) {
        self.shape = shape
        self.tint = tint
        self.isActive = isActive
        self.interactive = interactive
        self.dim = dim
        self.dimColor = dimColor
        self.overMirror = overMirror
        self.clipsContent = clipsContent
        self.fill = fill
        self.stroke = stroke
        self.strokeShape = strokeShape
    }

    @available(macOS 26.0, *)
    private var glass: Glass { Glass.regular.tint(tintedGlass ? tint : nil).interactive(interactive) }

    /// The hairline of the flat look. The surface's own shape draws it unless a different one was given, so the
    /// fallback strokes exactly the path the old code did.
    @ViewBuilder private var flatStroke: some View {
        if let stroke {
            if let strokeShape { strokeShape.stroke(stroke) } else { shape.stroke(stroke) }
        }
    }

    /// The glass, the dimming over it, or the flat look of a resting surface, all behind the content. The glass sits
    /// behind the content instead of wrapping it: text keeps exactly the colors it has on a flat surface (inside
    /// the effect, secondary and tertiary labels lose contrast).
    @available(macOS 26.0, *)
    @ViewBuilder private var glassLayer: some View {
        ZStack {
            shape.fill(Color.clear).glassEffect(isActive ? glass : .identity, in: shape)
            if isActive {
                // Over the glass, under the content: keeps text legible and pulls the surface toward the island's
                // darkness while the glass keeps its rim light and a little of the depth behind it.
                if dim > 0 { shape.fill(dimColor.opacity(dim)) }
            } else {
                // A resting surface (an unselected tab, an empty send button) stays flat, as before.
                shape.fill(fill)
                flatStroke
            }
        }
        .animation(.easeOut(duration: 0.16), value: isActive)
    }

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), gate.allows(overMirror: overMirror) {
            if clipsContent {
                content.clipShape(shape).background { glassLayer }
            } else {
                content.background { glassLayer }
            }
        } else if clipsContent {
            // The order the old card code had: fill, clip to the corners, hairline outside the clip.
            content.background(fill).clipShape(shape).overlay { flatStroke }
        } else {
            content.background(fill, in: shape).overlay { flatStroke }
        }
    }
}

extension View {
    /// A background surface: Liquid Glass on macOS 26+, and the flat `fill` plus hairline `stroke` the island used
    /// before everywhere else (older systems, Reduce Transparency, Increase Contrast).
    ///
    /// - Parameters:
    ///   - tint: Colors the glass; pass a translucent color (`accent.opacity(0.3)`) to keep it subtle.
    ///   - isActive: When false the surface stays flat even on macOS 26 (an unselected tab, a disabled send button).
    ///   - interactive: Glass that answers the pointer (press and hover); for things that are buttons.
    ///   - dim: Opacity of `dimColor` laid over the glass, under the content. Raises contrast and pulls the glass
    ///     toward the island's darkness; the rest of the glass (rim light, depth) shows through.
    ///   - dimColor: Black by default; use the surface's own flat color to keep its brightness close to the flat look.
    ///   - overMirror: The surface can overlap the terminal mirror; glass is then used only with a dark backdrop.
    ///   - clipsContent: Clips the content to `shape` (a scroll view inside a card); the flat look keeps the order
    ///     fill, clip, hairline.
    ///   - fill: The flat look used as the fallback.
    ///   - stroke: The flat hairline used as the fallback; glass draws its own rim, so it is not drawn over glass.
    ///   - strokeShape: A different shape for the flat stroke, for fills whose stroke never matched their radius.
    func nookGlassSurface<S: Shape, F: ShapeStyle>(
        in shape: S,
        tint: Color? = nil,
        isActive: Bool = true,
        interactive: Bool = false,
        dim: Double = 0,
        dimColor: Color = .black,
        overMirror: Bool = false,
        clipsContent: Bool = false,
        fill: F,
        stroke: Color? = Color.primary.opacity(0.055),
        strokeShape: AnyShape? = nil
    ) -> some View {
        modifier(NookGlassSurface(shape: shape, tint: tint, isActive: isActive, interactive: interactive, dim: dim, dimColor: dimColor, overMirror: overMirror, clipsContent: clipsContent, fill: fill, stroke: stroke, strokeShape: strokeShape))
    }

    /// `nookGlassSurface` with the island's usual resting fill, `Color.white.opacity(0.055)`.
    func nookGlassSurface<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        isActive: Bool = true,
        interactive: Bool = false,
        dim: Double = 0,
        dimColor: Color = .black,
        overMirror: Bool = false,
        stroke: Color? = Color.primary.opacity(0.055),
        strokeShape: AnyShape? = nil
    ) -> some View {
        nookGlassSurface(in: shape, tint: tint, isActive: isActive, interactive: interactive, dim: dim, dimColor: dimColor, overMirror: overMirror, fill: Color.white.opacity(0.055), stroke: stroke, strokeShape: strokeShape)
    }

    /// A floating card: glass over a dark backdrop, the opaque `fill` card otherwise. Cards can overlap the terminal
    /// mirror, so glass is only used when `nookDarkBackdrop` is true, and `dim` (the card's own surface color laid
    /// over the glass) keeps the text over it clean.
    func nookGlassCard<F: ShapeStyle>(radius: CGFloat, tint: Color? = nil, dim: Double = 0.6, dimColor: Color = Color(white: 0.115), clipsContent: Bool = false, fill: F, stroke: Color = Color.white.opacity(0.09)) -> some View {
        nookGlassSurface(in: RoundedRectangle(cornerRadius: radius), tint: tint, dim: dim, dimColor: dimColor, overMirror: true, clipsContent: clipsContent, fill: fill, stroke: stroke)
    }

    /// `nookGlassCard` with the card surface of the subagent list and the recap: `Color(white: 0.115)`.
    func nookGlassCard(radius: CGFloat = 11, tint: Color? = nil, dim: Double = 0.6) -> some View {
        nookGlassCard(radius: radius, tint: tint, dim: dim, fill: Color(white: 0.115))
    }
}

// MARK: - Buttons

/// For borderless icon buttons: nothing at rest, a small glass disc while the pointer is over the button or it is
/// pressed, like a toolbar button in System Settings. Use it through `nookGlassButton()`, which keeps `.plain`
/// wherever glass is not available.
@available(macOS 26.0, *)
struct NookGlassButtonStyle: ButtonStyle {
    /// Colors the disc; nil keeps it neutral.
    var tint: Color?

    init(tint: Color? = nil) { self.tint = tint }

    func makeBody(configuration: Configuration) -> some View {
        NookGlassButtonBody(configuration: configuration, tint: tint)
    }
}

@available(macOS 26.0, *)
private struct NookGlassButtonBody: View {
    let configuration: ButtonStyleConfiguration
    var tint: Color?
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let lit = isEnabled && (hovering || configuration.isPressed)
        // Two points inside the label's frame, so a 28 pt hit area shows a 24 pt disc.
        let disc = Circle().inset(by: 2)
        configuration.label
            // The glass is a background, not a wrapper: the icon keeps the colors it has without glass.
            .background { Color.clear.glassEffect(lit ? Glass.regular.tint(tint).interactive() : .identity, in: disc) }
            .contentShape(disc)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.14), value: lit)
    }
}

private struct NookGlassButtonModifier: ViewModifier {
    var tint: Color?
    private var gate = NookGlassGate()

    init(tint: Color?) { self.tint = tint }

    func body(content: Content) -> some View {
        // Icon buttons sit on the island's black, never on the mirror.
        if #available(macOS 26.0, *), gate.allows(overMirror: false) {
            content.buttonStyle(NookGlassButtonStyle(tint: tint))
        } else {
            content.buttonStyle(.plain)
        }
    }
}

extension View {
    /// Replaces `.buttonStyle(.plain)` on a borderless icon button: glass appears on hover and press on macOS 26+,
    /// and the button stays exactly `.plain` on older systems and with Reduce Transparency or Increase Contrast.
    func nookGlassButton(tint: Color? = nil) -> some View {
        modifier(NookGlassButtonModifier(tint: tint))
    }
}

// MARK: - Scroll fade

private struct NookScrollFade: ViewModifier {
    var active: Bool
    var height: CGFloat
    var surface: Color
    private var gate = NookGlassGate()

    init(active: Bool, height: CGFloat, surface: Color) {
        self.active = active
        self.height = height
        self.surface = surface
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), gate.allows(overMirror: true) {
            // A glass card has no opaque surface to fade into, so the content itself fades out.
            if active {
                content.mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: height)
                    }
                }
            } else {
                content
            }
        } else {
            content.overlay(alignment: .bottom) {
                if active {
                    LinearGradient(colors: [surface.opacity(0), surface], startPoint: .top, endPoint: .bottom)
                        .frame(height: height).allowsHitTesting(false)
                }
            }
        }
    }
}

extension View {
    /// The fade at the bottom of a scrolling card that has more to show. On a solid card it is a gradient into the
    /// card's `surface`; on a glass card (`nookGlassCard`) it masks the content instead, since glass has no solid
    /// color to fade into.
    func nookScrollFade(active: Bool, height: CGFloat = 14, surface: Color = Color(white: 0.115)) -> some View {
        modifier(NookScrollFade(active: active, height: height, surface: surface))
    }
}
