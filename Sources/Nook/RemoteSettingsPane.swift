import SwiftUI
import AppKit

// The settings card's "Remoto" tab: the switch for Nook Remoto, the code a phone scans to pair with this Mac and the address and port it is on, the devices that have paired, what to
// know before using it, and a way to hide the tab again. The tab is in the card's bar only once the five taps on the version in «Acerca de» have unlocked it (`SettingsAbout.swift`).
//
//   RemotePanePresentation   what the tab says for each state of the remote (plain values, so the tests hold them to the words and tones)
//   RemotePaneState          what the tab shows, as values: the remote's status and link, its devices, and whether a phone has the page open
//   RemotePaneContent        the tab, drawn from a state and handing every choice to a closure, so it can be looked at in any state without a server
//   RemoteSettingsPane       the tab as the card holds it: its state is the model's `remote` (`RemoteAccess`), and what the user does goes to it
//
// A pairing code is good for one device: once a phone has paired, the remote makes another and the code on show follows it at once (it is read from `RemoteAccess.pairingURL` as
// it changes). A full list (`RemoteRegistry.maxDevices`) pairs nobody more until one is removed, so the code gives way to the reason.

// MARK: - What the tab says

enum RemotePanePresentation {
    /// The switch's row for each status: the state in a chip, a line under the title, and the tile's symbol.
    struct Header: Equatable {
        var chip: String
        var chipSymbol: String
        var tone: PermissionTone
        /// The tile's symbol, which says it too.
        var symbol: String
        var detail: String
        /// Something is being waited for: a small spinner goes before the line.
        var working: Bool
        /// What the switch shows: on while it is starting too, since the user has asked for it.
        var switchOn: Bool
        /// Why it could not start, or stopped by itself, in the server's own words: the tab shows them in a note of their own.
        var failure: String?
    }

    static func header(_ status: RemoteAccess.Status) -> Header {
        switch status {
        case .off:
            return Header(chip: "Apagado", chipSymbol: "circle.dashed", tone: .neutral, symbol: "iphone.slash",
                          detail: "Maneja Nook desde tu iPhone, en Safari, con el Wi-Fi de casa.", working: false, switchOn: false, failure: nil)
        case .starting:
            return Header(chip: "Activando", chipSymbol: "ellipsis.circle", tone: .neutral, symbol: "iphone.radiowaves.left.and.right",
                          detail: "Abriendo el puerto…", working: true, switchOn: true, failure: nil)
        case .on:
            return Header(chip: "Activo", chipSymbol: "checkmark.circle.fill", tone: .good, symbol: "iphone.radiowaves.left.and.right",
                          detail: "Escanea el código con tu iPhone.", working: false, switchOn: true, failure: nil)
        case .failed(let message):
            return Header(chip: "No se pudo", chipSymbol: "xmark.circle.fill", tone: .bad, symbol: "exclamationmark.triangle.fill",
                          detail: "Está apagado. Puedes volver a activarlo.", working: false, switchOn: false, failure: message)
        }
    }

    // The words of the tab outside its states.
    static let title = "Nook Remoto"
    static let switchLabel = "Activar Nook Remoto"
    static let retry = "Reintentar"
    static let pairTitle = "Emparejar el iPhone"
    static let qrLabel = "Código QR para emparejar el iPhone"
    static let qrMissing = "No se pudo dibujar el código. Copia el enlace."
    static let preparing = "Preparando el código…"
    static let oneDevicePerCode = "Cada código empareja un dispositivo; después aparece otro."
    static let addressTitle = "Dirección"
    static let portTitle = "Puerto"
    static let copyLink = "Copiar enlace para el iPhone"
    static let copiedLink = "Enlace copiado"
    static let copyHelp = "Con el Portapapeles universal, pégalo en Safari desde el iPhone."
    static let devicesTitle = "Dispositivos"
    static let pageOpen = "Página abierta"
    static let noDevices = "Aún no hay ninguno. Aparecerá aquí cuando escanee el código."
    static let remove = "Quitar"
    static let removeHelp = "Olvidar este dispositivo: para volver tendrá que escanear otro código"
    static let howTitle = "Cómo se usa"
    static let hide = "Ocultar Nook Remoto"
    static let hideNote = "Lo apaga y quita esta pestaña. Para volver a verla, toca cinco veces la versión en Isla → Acerca de."
    static let shareNote = "Quien tenga el código o el enlace puede usar Nook desde su teléfono mientras esté activo: no lo compartas ni lo muestres en una pantalla compartida."
    static let facts: [(symbol: String, lead: String, text: String)] = [
        ("qrcode.viewfinder", "Escanea el código.", "Con la app Cámara del iPhone, en el mismo Wi-Fi de casa que este Mac, y toca el enlace: se abre en Safari. El Escáner de códigos lo abre en un navegador aparte que no sirve. O copia el enlace y pégalo en Safari, con el Portapapeles universal."),
        ("macbook", "Solo en el teléfono.", "La página no se abre en este Mac, a propósito."),
        ("arrow.triangle.2.circlepath", "Se apaga al cerrar Nook.", "Cada vez que lo activas hay un código nuevo: los teléfonos de antes tienen que escanear otra vez."),
    ]

    /// The list is full: what the code's place says instead of the code.
    static func fullTitle(_ limit: Int) -> String { "Ya hay \(limit) dispositivos emparejados" }
    static let fullDetail = "Quita uno de la lista para emparejar otro."

    /// «Quitar iPhone · Safari»: what VoiceOver calls a device's button.
    static func removeLabel(_ device: RemoteDevice) -> String { "\(remove) \(device.label)" }

    /// When a device was last seen, in a few words. The registry tells the tab of a device's activity every ten seconds at most (`RemoteRegistry.seenGranularity`), so under half a
    /// minute is "ahora".
    static func lastSeen(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<30: return "ahora"
        case ..<3600: return "hace \(max(1, Int(seconds / 60))) min"
        case ..<86_400: return "hace \(Int(seconds / 3600)) h"
        default: return "hace \(Int(seconds / 86_400)) d"
        }
    }

    /// The symbol of a device's row, from the label the registry gives it ("iPhone · Safari").
    static func deviceSymbol(_ label: String) -> String {
        let device = label.components(separatedBy: " · ").first ?? label
        switch device {
        case "iPhone", "Android": return "iphone"
        case "iPad": return "ipad"
        case "Mac": return "laptopcomputer"
        case "Windows", "Linux": return "desktopcomputer"
        default: return "globe"
        }
    }
}

// MARK: - The state

/// Everything the tab shows, as values.
struct RemotePaneState: Equatable {
    var status: RemoteAccess.Status = .off
    /// The code's link while on. It changes each time a phone pairs.
    var pairingURL: URL?
    var devices: [RemoteDevice] = []
    /// A phone has the page open right now.
    var watching = false

    /// No room for another phone: the code would pair nobody.
    var full: Bool { devices.count >= RemoteRegistry.maxDevices }
}

// MARK: - The tab

struct RemotePaneContent: View {
    var state: RemotePaneState
    /// The tallest the tab may be: past it the tab scrolls instead of the card running off the screen.
    var maxHeight: CGFloat
    /// Called when something that changes the tab's height has changed, so the card's window can follow.
    var onContentChange: () -> Void = {}
    var setOn: (Bool) -> Void = { _ in }
    var copyLink: (URL) -> Void = { _ in }
    var remove: (RemoteDevice) -> Void = { _ in }
    var hide: () -> Void = {}
    /// The time «visto» is counted from; nil is the time it is (and the tab keeps it up to date while it is open).
    var now: Date?

    @State private var copied = false
    /// Goes up with every copy: «Enlace copiado» goes back to «Copiar enlace…» a moment after the last one.
    @State private var copies = 0
    private let gate = NookMotionGate()

    private typealias Copy = RemotePanePresentation

    /// The side of the code's paper, in points: 4.6 cm on a MacBook's screen, which a phone reads at arm's length.
    static let paper: CGFloat = 232

    /// Everything the tab's height depends on.
    private struct Layout: Equatable {
        var status: RemoteAccess.Status
        var link: Bool
        var devices: Int
        var watching: Bool
    }
    private var layout: Layout { Layout(status: state.status, link: state.pairingURL != nil, devices: state.devices.count, watching: state.watching) }

    var body: some View {
        // The tab at its own height when it fits, in a scroll view when it does not.
        ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical) { content }.scrollIndicators(.automatic)
        }
        .frame(maxHeight: maxHeight)
        .onChange(of: layout) { _, _ in onContentChange() }
        // A link that has been used is of no use on the iPhone: the button offers the new one.
        .onChange(of: state.pairingURL) { _, _ in copied = false }
        .task(id: copies) {
            guard copies > 0 else { return }
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled { copied = false }
        }
    }

    private var content: some View {
        let shown = Copy.header(state.status)
        return VStack(alignment: .leading, spacing: 14) {
            mainSwitch(shown)
            if let failure = shown.failure { failureNote(failure).transition(.opacity) }
            if case .on(let url, let port) = state.status {
                VStack(alignment: .leading, spacing: 14) {
                    pairing(address: url.host ?? url.absoluteString, port: port)
                    devices
                }.transition(.opacity)
            }
            guidance
            hideRow
        }
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 15)
        .animation(gate.allows ? .easeOut(duration: 0.18) : nil, value: layout)
    }

    // MARK: The switch

    /// A state chip as one element for VoiceOver: its word, and not the name the system gives its symbol («Seleccionado»).
    private func stateChip(_ text: String, symbol: String, tone: PermissionTone) -> some View {
        StateChip(text: text, symbol: symbol, tone: tone).accessibilityElement(children: .ignore).accessibilityLabel(text)
    }

    /// The switch for Nook Remoto, as the sound tab has its own: a tile that says it, the name and the state, and what it is in a line.
    private func mainSwitch(_ shown: RemotePanePresentation.Header) -> some View {
        HStack(alignment: .center, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(shown.tone == .good ? Color.nookMintFill.opacity(0.2) : shown.tone.wash)
                Image(systemName: shown.symbol).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(shown.tone == .neutral ? Color.nookSecondary : shown.tone.color)
                    .contentTransition(.symbolEffect(.replace))
            }.frame(width: 34, height: 34).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(Copy.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    stateChip(shown.chip, symbol: shown.chipSymbol, tone: shown.tone)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if shown.working { ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 10, height: 10) }
                    Text(shown.detail).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Toggle(Copy.switchLabel, isOn: Binding(get: { shown.switchOn }, set: setOn))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Color.nookMintFill)
        }
        .accessibilityElement(children: .contain).accessibilityLabel(Copy.title)
    }

    /// It could not start, or stopped by itself (the network changed): the server's words, and a button to try again.
    private func failureNote(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(PermissionPalette.red).padding(.top, 1).accessibilityHidden(true)
                Text(message).font(.system(size: 10.5)).foregroundStyle(Color.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            RowButton(title: Copy.retry, symbol: "arrow.clockwise", prominent: true) { setOn(true) }
        }
        .padding(.horizontal, 11).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
        .background(PermissionPalette.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(PermissionPalette.red.opacity(0.42), lineWidth: 0.9))
        .accessibilityElement(children: .contain)
    }

    // MARK: Pairing

    /// The code, and under it where this Mac is: the address and, larger, the port, then the link to copy.
    private func pairing(address: String, port: Int) -> some View {
        let host = AddressCell(title: Copy.addressTitle, value: address, prominent: false)
        let number = AddressCell(title: Copy.portTitle, value: "\(port)", prominent: true)
        return VStack(alignment: .leading, spacing: 9) {
            SectionLabel(Copy.pairTitle)
            VStack(spacing: 10) {
                codePlace(address: address, port: port)
                // Side by side, the port as wide as its digits; a long address (IPv6) takes a line to itself and the port the next.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { host; number.fixedSize(horizontal: true, vertical: false) }
                    VStack(spacing: 8) { host; number }
                }
                if !state.full, let link = state.pairingURL {
                    CopyLinkButton(copied: copied) {
                        copyLink(link)
                        copied = true
                        copies += 1
                        AccessibilityNotification.Announcement(Copy.copiedLink).post()
                    }
                }
            }
            .padding(12).frame(maxWidth: .infinity)
            .background(Color.nookWash(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.nookWash(0.07), lineWidth: 0.6))
        }
    }

    /// Where the code goes: the code itself, or, when it would pair nobody (the list is full) or is not ready yet, a short note in its place that says why.
    @ViewBuilder
    private func codePlace(address: String, port: Int) -> some View {
        if state.full {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(PermissionPalette.amber).padding(.top, 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Copy.fullTitle(RemoteRegistry.maxDevices)).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(Copy.fullDetail).font(.system(size: 10.5)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .background(PermissionPalette.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(PermissionPalette.amber.opacity(0.42), lineWidth: 0.9))
            .accessibilityElement(children: .ignore).accessibilityLabel(Copy.fullTitle(RemoteRegistry.maxDevices)).accessibilityValue(Copy.fullDetail)
        } else if let link = state.pairingURL {
            VStack(spacing: 8) {
                // A new code (after a phone has paired) takes the old one's place with a fade.
                QRCodeView(text: link.absoluteString, side: Self.paper, label: Copy.qrLabel, value: "\(Copy.addressTitle) \(address), \(Copy.portTitle.lowercased()) \(port)", missing: Copy.qrMissing)
                    .id(link).transition(.opacity)
                Text(Copy.oneDevicePerCode).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .animation(gate.fades ? .easeOut(duration: 0.25) : nil, value: link)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 10, height: 10)
                Text(Copy.preparing).font(.system(size: 10.5)).foregroundStyle(Color.nookSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(Color.nookWash(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: Devices

    private var devices: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                SectionLabel(Copy.devicesTitle)
                Spacer(minLength: 4)
                // A phone has the page open right now: a symbol and words, never colour alone.
                if state.watching { stateChip(Copy.pageOpen, symbol: "iphone.radiowaves.left.and.right", tone: .good).transition(.opacity) }
            }
            if state.devices.isEmpty {
                Text(Copy.noDevices).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
            } else {
                // Who was seen when is counted again every so often while the tab is open.
                TimelineView(.periodic(from: .now, by: 20)) { context in
                    VStack(spacing: 4) {
                        ForEach(state.devices) { device in
                            DeviceRow(device: device, seen: Copy.lastSeen(device.lastSeen, now: now ?? context.date)) { remove(device) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Guidance

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(Copy.howTitle)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(Copy.facts.enumerated()), id: \.offset) { _, fact in RemoteFact(symbol: fact.symbol, lead: fact.lead, text: fact.text) }
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.shield").font(.system(size: 10)).foregroundStyle(Color.nookSecondary).accessibilityHidden(true)
                Text(Copy.shareNote).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Hiding the tab

    private var hideRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                RowButton(title: Copy.hide, symbol: "eye.slash", prominent: false) { hide() }
                Spacer(minLength: 0)
            }
            Text(Copy.hideNote).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 11)
        .overlay(alignment: .top) { Rectangle().fill(Color.nookWash(0.08)).frame(height: 0.5) }
    }
}

// MARK: - The tab in the card

struct RemoteSettingsPane: View {
    @ObservedObject var remote: RemoteAccess
    var maxHeight: CGFloat
    var onContentChange: () -> Void = {}
    /// «Ocultar Nook Remoto»: the card leaves the tab, and the remote is locked again (`SettingsCard.hideRemote`).
    var onHide: () -> Void
    /// Where the link goes when it is copied: the general pasteboard. A test passes its own, so it never touches the user's.
    var copy: (String) -> Void = RemoteSettingsPane.copyToPasteboard

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    var body: some View {
        RemotePaneContent(state: RemotePaneState(status: remote.status, pairingURL: remote.pairingURL, devices: remote.devices, watching: remote.watching),
                          maxHeight: maxHeight, onContentChange: onContentChange,
                          setOn: { on in if on { remote.start() } else { remote.stop() } },
                          copyLink: { copy($0.absoluteString) },
                          remove: { remote.remove($0) },
                          hide: onHide)
    }
}

// MARK: - Pieces

/// The address or the port: a small label over the value, which can be selected and copied. The port is the one the user asks about, so it is the large one.
private struct AddressCell: View {
    var title: String
    var value: String
    var prominent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(title)
            Text(value).font(.system(size: prominent ? 20 : 13, weight: prominent ? .bold : .medium, design: .monospaced))
                .foregroundStyle(prominent ? Color.nookMint : Color.primary.opacity(0.9)).lineLimit(1).minimumScaleFactor(0.7).textSelection(.enabled)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.nookWash(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(value)
    }
}

/// «Copiar enlace para el iPhone»: a chip as wide as the card, mint with a check for a moment once it has copied.
private struct CopyLinkButton: View {
    var copied: Bool
    var action: () -> Void
    @State private var hovering = false

    private typealias Copy = RemotePanePresentation

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .semibold)).contentTransition(.symbolEffect(.replace))
                Text(copied ? Copy.copiedLink : Copy.copyLink).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(copied ? Color.nookText : Color.primary.opacity(0.85))
            .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 28)
            .background(copied ? Color.nookMintFill.opacity(0.22) : Color.nookWash(hovering ? 0.13 : 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.nookMintFill.opacity(copied ? 0.55 : 0), lineWidth: 0.8))
            .contentShape(Rectangle())
        }
        .nookPress(.squeeze, depth: PressDepth.card, strength: 0.4)
        .onHover { hovering = $0 }
        .help(Copy.copyHelp)
        .accessibilityLabel(copied ? Copy.copiedLink : Copy.copyLink).accessibilityHint(Copy.copyHelp)
    }
}

/// A device that has paired: its mark, what it is and when it was last seen, and «Quitar».
private struct DeviceRow: View {
    var device: RemoteDevice
    var seen: String
    var remove: () -> Void

    private typealias Copy = RemotePanePresentation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Copy.deviceSymbol(device.label)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.primary.opacity(0.75)).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text("Visto \(seen)").font(.system(size: 9.5)).foregroundStyle(Color.nookSecondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            RemoveButton(label: Copy.removeLabel(device), action: remove)
        }
        .padding(.leading, 9).padding(.trailing, 6).padding(.vertical, 4).frame(minHeight: 38)
        .background(Color.nookWash(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// «Quitar»: a small quiet button on a device's row.
private struct RemoveButton: View {
    var label: String
    var action: () -> Void
    @State private var hovering = false

    private typealias Copy = RemotePanePresentation

    var body: some View {
        Button(action: action) {
            Text(Copy.remove).font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.85))
                .padding(.horizontal, 9).frame(height: 22)
                .background(Color.nookWash(hovering ? 0.13 : 0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .nookPress(.none, depth: PressDepth.card, strength: 0.5)
        .onHover { hovering = $0 }
        .help(Copy.removeHelp).accessibilityLabel(label).accessibilityHint(Copy.removeHelp)
    }
}

/// One of the plain lines about how it works: a symbol, a lead word and the rest.
private struct RemoteFact: View {
    var symbol: String
    var lead: String
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).frame(width: 14).accessibilityHidden(true)
            (Text(lead + " ").fontWeight(.semibold).foregroundStyle(Color.primary.opacity(0.85)) + Text(text))
                .font(.system(size: 10.5)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
