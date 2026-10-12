import SwiftUI
import AppKit

// The "Gato" tab of the settings card: who the cat is, how much it does, what it looks like and whether it cheers. A picture of the
// cat, as the island's black shows it, answers every choice at once; nothing here animates or runs a timer: the pictures are drawn when
// what they show changes. The choices live in `PetPreferences` (and are saved by `AppModel.pet`).

private let mint = PermissionPalette.mint

/// The cat on the island's black, as a picture: drawn once for what it shows, with no timer and no animation.
struct PetThumbnail: View {
    var look: PetLook
    var pose: PetPose = PetPose()
    /// Points per rig unit: the cat is about 31 units tall.
    var scale: CGFloat
    var corner: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: corner, style: .continuous), with: .color(.black))
            context.withCGContext { cg in
                // The canvas counts down from its top; the cat is drawn up from its feet.
                cg.translateBy(x: size.width / 2, y: size.height - size.height * 0.1)
                cg.scaleBy(x: scale, y: -scale)
                PetPainter.draw(pose, look: look, in: cg)
            }
        }
    }
}

struct PetSettingsPane: View {
    @ObservedObject var model: AppModel
    /// The tallest the tab may be: past it the list scrolls instead of the card running off the screen.
    var maxHeight: CGFloat

    private var prefs: PetPreferences { model.pet }

    var body: some View {
        // At its own height when it fits, in a scroll view when it does not.
        ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical) { content }.scrollIndicators(.automatic)
        }.frame(maxHeight: maxHeight)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            portrait
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Carácter")
                HStack(spacing: 4) {
                    ForEach(PetPersonality.allCases) { personality in
                        PetChoiceChip(title: personality.title, selected: prefs.personality == personality, label: "Carácter \(personality.title)") { model.pet.personality = personality }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Actividad")
                HStack(spacing: 4) {
                    ForEach(PetActivity.allCases) { activity in
                        PetChoiceChip(title: activity.title, selected: prefs.activity == activity, label: "Actividad \(activity.title)") { model.pet.activity = activity }
                    }
                }
                Text(prefs.activity.blurb).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Pelaje")
                HStack(spacing: 4) {
                    ForEach(PetCoat.allCases) { coat in
                        CoatSwatch(coat: coat, accessory: prefs.accessory, selected: prefs.coat == coat) { model.pet.coat = coat }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Accesorio")
                HStack(spacing: 4) {
                    ForEach(PetAccessory.allCases) { accessory in
                        PetChoiceChip(title: accessory.title, selected: prefs.accessory == accessory, label: "Accesorio \(accessory.title)") { model.pet.accessory = accessory }
                    }
                }
            }
            celebrationRow
            footer
        }.padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 15)
    }

    /// The cat as it will look (with how it carries itself), beside what the chosen character is like.
    private var portrait: some View {
        HStack(spacing: 12) {
            PetThumbnail(look: prefs.look, pose: PetLife.resting(PetAnimation.sit(time: 0), temperament: .of(prefs.personality)), scale: 1.55, corner: 12)
                .frame(width: 92, height: 68)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Tu gato").font(.system(size: 12.5, weight: .semibold))
                Text(prefs.personality.blurb).font(.system(size: 10.5)).foregroundStyle(Color.primary.opacity(0.72)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.frame(height: 68)
    }

    private var celebrationRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Celebra cuando termina una tarea").font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.85))
                Text("Un saltito de alegría cuando Claude acaba.").font(.system(size: 10)).foregroundStyle(Color.nookSecondary)
            }
            Spacer(minLength: 6)
            Toggle("Celebra cuando termina una tarea", isOn: Binding(get: { prefs.celebrates }, set: { model.pet.celebrates = $0 }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(mint)
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "pawprint").font(.system(size: 10)).foregroundStyle(Color.nookSecondary)
            Text("Con Reducir movimiento, o con «Animaciones de la mascota» apagadas en el menú de la barra, el gato se queda quieto.")
                .font(.system(size: 10)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One of a row of choices: a small chip, mint when it is the one chosen. Like the island's size presets.
private struct PetChoiceChip: View {
    var title: String
    var selected: Bool
    var label: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .medium)).lineLimit(1)
                .frame(maxWidth: .infinity).frame(height: 26)
                .foregroundStyle(selected ? Color.nookText : Color.primary.opacity(0.78))
                .background(selected ? mint.opacity(0.22) : Color.nookWash(hovering ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(mint.opacity(selected ? 0.55 : 0), lineWidth: 0.8))
                .contentShape(Rectangle())
        // A text chip gives a little squeeze, as the island's other text chips do (gentle: it stands a few points from the next one).
        }.nookPress(.squeeze, depth: PressDepth.card, strength: 0.35).onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(label)
    }
}

/// A coat: a small picture of the cat in it (with what it wears now), and its name under it.
private struct CoatSwatch: View {
    var coat: PetCoat
    var accessory: PetAccessory
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                PetThumbnail(look: PetLook(coat: coat, accessory: accessory), scale: 0.86, corner: 9)
                    .frame(maxWidth: .infinity).frame(height: 38)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(mint.opacity(selected ? 0.9 : hovering ? 0.28 : 0), lineWidth: selected ? 1.4 : 1))
                Text(coat.title).font(.system(size: 9.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                    .foregroundStyle(selected ? Color.nookText : Color.primary.opacity(0.7))
            }.contentShape(Rectangle())
        // Half a pop: the swatches stand close together.
        }.nookPress(.pop, strength: 0.5).onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel("Pelaje \(coat.title)")
    }
}
