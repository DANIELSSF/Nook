import SwiftUI

// What the list of models and Claude's own model picker (its card) have in common: a row of the list, the two ways to choose a model, and the
// effort stepper. Both show what Claude's /model picker offers (Claude Code's list of the account's models, in its order), laid out the same way:
//
//   FamilyBadge        the family's symbol (see `ClaudeModelFamily`) in a small round badge
//   ModelRowLabel      a row: the badge, the name, Claude's description under it, a mark on the one in use, and the picker's number when it has one
//   ModelScopeButtons  «Usar por defecto» (Enter in Claude's picker) and «Solo esta sesión» (S), each with its key
//   EffortStepper      the effort's ring and ‹ › to change it, as Claude's picker has under its rows

// MARK: - Rows

/// The family's symbol in a small round badge: the mark a model wears in the list.
struct FamilyBadge: View {
    var family: ClaudeModelFamily
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: family.symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.88))
            .frame(width: size, height: size).background(Color.primary.opacity(0.08), in: Circle())
            .accessibilityHidden(true)
    }
}

/// A row of the list of models: what is in it, not the button around it (the popover and the card each have their own). The name and Claude's description
/// share one line when they fit, which most do; else the description goes under the name, in two lines at the most (the whole of it is in the row's tooltip,
/// `ModelRowLabel.help`).
struct ModelRowLabel: View {
    var choice: ClaudeModelChoice
    /// The number Claude's picker prints for it, in the card; the popover has none.
    var number: Int?
    /// The row the keyboard or a click has chosen to act on.
    var selected = false
    /// The user's chat text size over the design's, for the card (the popover is at the design's size).
    var scale: CGFloat = 1
    @Environment(\.tabTint) private var tint

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let number { numberBox(number) }
            FamilyBadge(family: choice.family, size: 22 * scale)
            words.frame(maxWidth: .infinity, minHeight: 22 * scale, alignment: .leading)
            if choice.isCurrent { CurrentMark().frame(minHeight: 22 * scale) }
        }
    }

    private var name: some View {
        Text(choice.label).font(.system(size: 11.5 * scale, weight: choice.isCurrent ? .semibold : .medium))
    }

    @ViewBuilder private var words: some View {
        if let detail = choice.detail {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    name.lineLimit(1).fixedSize()
                    Text(detail).font(.system(size: 10.5 * scale)).foregroundStyle(Color.nookSecondary).lineLimit(1).fixedSize()
                }
                VStack(alignment: .leading, spacing: 1.5) {
                    name.fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.system(size: 10.5 * scale)).foregroundStyle(Color.nookSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            name.fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Whether the name and the description take one line in `width` points of room (what the row's text has, less the badge and the mark), at the user's
    /// text size: for the estimates, which have to know how tall a row is before it is laid out.
    static func fitsOneLine(_ choice: ClaudeModelChoice, width: CGFloat, scale: CGFloat = 1) -> Bool {
        guard let detail = choice.detail else { return true }
        let nameWidth = (choice.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5 * scale, weight: choice.isCurrent ? .semibold : .medium)]).width
        let detailWidth = (detail as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5 * scale)]).width
        return ceil(nameWidth) + 8 + ceil(detailWidth) <= width
    }

    private func numberBox(_ number: Int) -> some View {
        Text("\(number)").font(.system(size: 10 * scale, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(selected ? Color.black.opacity(0.8) : Color.nookSecondary)
            .frame(width: 17 * scale, height: 17 * scale)
            .background(selected ? tint.accent : Color.nookWash(0.09), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .padding(.top, 2.5 * scale)
    }

    /// The tooltip: the model, Claude's description whole, and what it is (the one in use, or an alias).
    static func help(for choice: ClaudeModelChoice) -> String {
        var lines = [choice.label]
        if let detail = choice.detail { lines.append(detail) }
        if choice.isAlias { lines.append("Alias: \(ModelMenuPlan.aliasesCaption).") }
        if choice.isCurrent { lines.append("Es el modelo que usa esta pestaña.") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - The two ways to choose

/// The two buttons that apply the model chosen in the list, as Claude's picker has them: «Usar por defecto» (Enter: the new sessions start with it too)
/// and «Solo esta sesión» (S: this session only, which Nook asks Claude's picker for with its arrows and the S key, so a Terminal tab needs the
/// Accessibility permission). Both wait for a model to be chosen.
struct ModelScopeButtons: View {
    var selection: ClaudeModelChoice?
    var needsAccessibility = false
    /// The user's chat text size over the design's, for the card.
    var scale: CGFloat = 1
    var onChoose: (ClaudeModelChoice, ClaudeModelScope) -> Void
    @State private var hovered: ClaudeModelScope?
    @Environment(\.tabTint) private var tint

    static func title(_ scope: ClaudeModelScope) -> String { scope == .default ? "Usar por defecto" : "Solo esta sesión" }
    static func key(_ scope: ClaudeModelScope) -> String { scope == .default ? "↵" : "S" }

    /// What each button does, for its tooltip.
    static func help(_ scope: ClaudeModelScope, for choice: ClaudeModelChoice?, needsAccessibility: Bool) -> String {
        guard let choice else { return "Elige antes un modelo de la lista." }
        switch scope {
        case .default:
            // A model with an id goes as `/model <id>`, a message; any other is chosen in Claude's picker with the keys.
            return "Usar «\(choice.label)» por defecto: las sesiones nuevas empezarán con él (Enter en el selector de Claude)."
                + (choice.argument == nil && needsAccessibility ? "\nNook lo elige en el selector de Claude; en una pestaña de Terminal necesita el permiso de Accesibilidad." : "")
        case .sessionOnly:
            return "Usar «\(choice.label)» solo en esta sesión (S en el selector de Claude), sin cambiar el modelo por defecto."
                + (needsAccessibility ? "\nEn una pestaña de Terminal Nook necesita el permiso de Accesibilidad para pulsar las teclas." : "")
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            button(.default, primary: true)
            button(.sessionOnly, primary: false)
        }
    }

    private func button(_ scope: ClaudeModelScope, primary: Bool) -> some View {
        let enabled = selection != nil
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let hovering = hovered == scope && enabled
        return Button {
            if let selection { onChoose(selection, scope) }
        } label: {
            HStack(spacing: 6) {
                Text(Self.title(scope)).font(.system(size: 11 * scale, weight: .semibold)).lineLimit(1).fixedSize()
                Text(Self.key(scope)).font(.system(size: 9 * scale, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 4.5).frame(height: 15 * scale)
                    .background(primary ? Color.black.opacity(0.14) : Color.nookWash(0.09), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .foregroundStyle(primary ? Color.black.opacity(0.85) : Color.primary.opacity(0.88))
            .padding(.horizontal, 10).frame(height: 28 * scale)
            .background(primary ? tint.accent.opacity(hovering ? 0.92 : 0.82) : Color.nookWash(hovering ? 0.15 : 0.09), in: shape)
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.4)
        }
        .nookPress(.none, depth: PressDepth.card).disabled(!enabled)
        .onHover { inside in hovered = inside ? scope : (hovered == scope ? nil : hovered) }
        .help(Self.help(scope, for: selection, needsAccessibility: needsAccessibility))
        .accessibilityLabel(Self.title(scope)).accessibilityHint(Self.help(scope, for: selection, needsAccessibility: needsAccessibility))
    }
}

// MARK: - Effort

/// The effort's ring (the chip's) and ‹ › to take it up or down one level, as the picker has under its rows. `named` adds the level's name. Each step
/// is `onStep(-1)` or `onStep(1)`; a level at either end cannot go further.
struct EffortStepper: View {
    var effort: ClaudeEffort?
    var named = true
    /// The user's chat text size over the design's, for the card.
    var scale: CGFloat = 1
    var onStep: (Int) -> Void

    static func help(_ effort: ClaudeEffort?) -> String {
        guard let effort else { return "Esfuerzo de Claude: aún sin leer.\nLas flechas lo cambian." }
        return "Esfuerzo de Claude: \(effort.title). \(effort.detail).\nLas flechas lo cambian."
    }

    var body: some View {
        HStack(spacing: 6) {
            EffortGlyph(effort: effort, color: Color.primary.opacity(0.85), size: 12 * scale)
            if named { Text(effort.map { "Esfuerzo: \($0.title)" } ?? "Esfuerzo").font(.system(size: 11 * scale, weight: .medium)).lineLimit(1) }
            HStack(spacing: 2) {
                step(-1, symbol: "chevron.left", help: "Menos esfuerzo")
                step(1, symbol: "chevron.right", help: "Más esfuerzo")
            }
        }
        .help(Self.help(effort))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Esfuerzo de Claude").accessibilityValue(EffortChip.spoken(effort: effort))
    }

    private func step(_ delta: Int, symbol: String, help: String) -> some View {
        let levels = ClaudeEffort.allCases
        let at = effort.flatMap { levels.firstIndex(of: $0) }
        // With no level read the arrows start from the middle of the scale.
        let atEnd = at.map { delta < 0 ? $0 == 0 : $0 == levels.count - 1 } ?? false
        return Button { onStep(delta) } label: {
            Image(systemName: symbol).font(.system(size: 9 * scale, weight: .bold)).foregroundStyle(Color.primary.opacity(0.85))
                .frame(width: 22 * scale, height: 22 * scale).background(Color.nookWash(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle()).opacity(atEnd ? 0.35 : 1)
        }.nookPress(symbol: symbol).disabled(atEnd).accessibilityLabel(help)
    }
}
