import SwiftUI

// The picker for the island's theme (Ajustes → Isla → Apariencia): three small pictures of the island, one in each look, with the choice named under
// each. Sistema is the island split down a diagonal, light on one side and dark on the other, since it is whichever macOS is.
//
// The pictures draw with fixed colours (the island's own black and paper), not the settings card's: they show what the island will look like, whatever
// the card around them is.

struct ThemePicker: View {
    @Binding var selection: ThemePreference

    static let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(ThemePreference.allCases) { theme in
                ThemeChoice(theme: theme, selected: selection == theme) { selection = theme }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Apariencia")
    }
}

private struct ThemeChoice: View {
    var theme: ThemePreference
    var selected: Bool
    var choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                ThemeThumbnail(theme: theme)
                    .frame(height: ThemeThumbnail.height)
                    .overlay(RoundedRectangle(cornerRadius: ThemeThumbnail.radius, style: .continuous)
                        .strokeBorder(selected ? Color.nookMint : Color.nookWash(hovering ? 0.28 : 0.16, light: hovering ? 0.30 : 0.18), lineWidth: selected ? 2 : 0.8))
                HStack(spacing: 4) {
                    Image(systemName: theme.symbol).nookIconMotion(.pop).font(.system(size: 10, weight: .medium))
                    Text(theme.title).font(.system(size: 11, weight: selected ? .semibold : .medium)).lineLimit(1)
                }.foregroundStyle(selected ? Color.nookText : Color.nookSecondary)
            }.contentShape(Rectangle())
        }.nookPress(.none, depth: PressDepth.card).frame(maxWidth: .infinity)
            .onHover { hovering = $0 }
            .help(theme.detail)
            .accessibilityLabel("Apariencia \(theme.title)").accessibilityHint(theme.detail)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The island in miniature: its black strip (with the notch's black in the middle of it), the paper or the black under it, a tab, two lines of text and
/// the composer.
struct ThemeThumbnail: View {
    var theme: ThemePreference

    static let height: CGFloat = 58
    static let radius: CGFloat = 8

    private static let paper = Color(red: 0.953, green: 0.941, blue: 0.914)
    private static let ink = Color(red: 0.110, green: 0.105, blue: 0.095)

    var body: some View {
        ZStack {
            switch theme {
            case .light: Self.island(light: true)
            case .dark: Self.island(light: false)
            case .system:
                Self.island(light: true)
                Self.island(light: false).mask(Diagonal())
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .accessibilityHidden(true)
    }

    /// The lower right half of the picture: where Sistema shows the dark island.
    private struct Diagonal: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }

    /// One island, light or dark, filling its frame.
    private static func island(light: Bool) -> some View {
        let mint = Color(red: 0.18, green: 0.64, blue: 0.51)
        return ZStack(alignment: .top) {
            Color.black
            VStack(spacing: 0) {
                // The header strip: the notch (a little blacker than nothing, so it reads as a notch) and the cat's stage.
                HStack(spacing: 0) {
                    Circle().fill(Color.white.opacity(0.7)).frame(width: 4, height: 4).padding(.leading, 7)
                    Spacer()
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Color(white: 0.06)).frame(width: 30, height: 9)
                    Spacer()
                    Circle().fill(Color.white.opacity(0.3)).frame(width: 3.5, height: 3.5).padding(.trailing, 7)
                }.frame(height: 10)
                ZStack(alignment: .top) {
                    if light {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(paper)
                    }
                    VStack(alignment: .leading, spacing: 3.5) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(mint.opacity(light ? 0.55 : 0.8)).frame(width: 26, height: 5)
                        RoundedRectangle(cornerRadius: 1.2, style: .continuous).fill((light ? ink : Color.white).opacity(0.38)).frame(width: 64, height: 2.4)
                        RoundedRectangle(cornerRadius: 1.2, style: .continuous).fill((light ? ink : Color.white).opacity(0.24)).frame(width: 46, height: 2.4)
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(light ? Color.white : Color.white.opacity(0.09))
                            .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder((light ? ink : Color.white).opacity(0.14), lineWidth: 0.5))
                            .frame(height: 9)
                    }.padding(EdgeInsets(top: 5, leading: 7, bottom: 5, trailing: 7))
                }.padding(.horizontal, 2).padding(.bottom, 2)
            }
        }
    }
}
