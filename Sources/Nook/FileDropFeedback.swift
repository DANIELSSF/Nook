import SwiftUI

/// What the composer (or the question card standing in its place) shows while files are dragged over the island: an outline
/// and glow in the tab's color (mint unless the user chose another: it outlines the composer, which wears it), and a tag on its
/// top edge that says what dropping does. It is drawn over the composer and takes no room, so nothing moves, and it exists only
/// during a drag: no timers, no animation left running.
struct FileDropFeedback: View {
    @ObservedObject var state: FileDropState
    var radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tabTint) private var tint

    var body: some View {
        ZStack {
            if state.files > 0 { zone }
        }
        // With Reduce Motion the outline appears and goes at once instead of fading.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state.files > 0)
        .allowsHitTesting(false)
    }

    private var label: String { state.files > 1 ? "Suelta para añadir las rutas" : "Suelta para añadir la ruta" }

    private var zone: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let color = tint.accent
        return shape.fill(color.opacity(0.1))
            .overlay(shape.strokeBorder(color.opacity(0.85), lineWidth: 1.5))
            .shadow(color: color.opacity(0.42), radius: 10)
            .overlay(alignment: .top) { FileDropTag(symbol: "arrow.down.doc.fill", text: label).offset(y: -FileDropTag.overhang) }
            .transition(.opacity)
            // Only a drag puts this in the accessibility tree, so it says what the island will do with the files.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }
}

/// The small tag, in the tab's color, that sits on the composer's top edge: the drop hint while dragging, the confirmation afterwards.
struct FileDropTag: View {
    var symbol: String
    var text: String
    @Environment(\.tabTint) private var tint
    static let height: CGFloat = 22
    /// How far the tag rises above the edge it sits on: half its height, so it straddles the outline.
    static let overhang: CGFloat = height / 2

    var body: some View {
        Label { Text(text) } icon: { Image(systemName: symbol) }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color(white: 0.06)).lineLimit(1)
            .padding(.horizontal, 10).frame(height: Self.height)
            .background(tint.accent, in: Capsule())
            .fixedSize()
    }
}
