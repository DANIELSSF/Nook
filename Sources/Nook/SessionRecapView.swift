import SwiftUI
import AppKit

// Claude Code prints a recap ("※ recap: …") when you come back to a session. Nook keeps it out of the mirror and
// offers it here: a small "Resumen" button in the session-tab row (it costs no mirror height) that opens a card
// over the top of the mirror. A recap the user has not opened yet is marked with a small mint badge, quietly.
//
// Integration (PanelView.swift, `sessionTabs`), inside `if let selected = model.selected { … }`, before the
// "arrow.up.right.square" IconButton:
//
//     ObservedRecapButton(object: selected, id: \.id, recap: \.recap)
//
// and `.zIndex(1)` on `sessionTabs` in `content`'s VStack, so the open card draws over the session pane.

// MARK: - Text

/// The recap's text handling, apart from the views so it can be tested without a window.
enum RecapText {
    /// The recap on one line: whitespace collapsed, Claude's own "※ recap:" label dropped if it slipped through.
    /// Nil when nothing is left to show.
    static func clean(_ recap: String?) -> String? {
        guard let recap else { return nil }
        var text = recap.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.hasPrefix("※") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if text.lowercased().hasPrefix("recap:") { text = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        return text.isEmpty ? nil : text
    }

    /// A recap usually opens with what the session is about ("Mejorando Nook para tus sesiones de Claude: ya
    /// publiqué …"). That lead-in becomes the card's title when it is short and has no sentence of its own;
    /// otherwise the whole text is the body. The body starts with a capital because it now follows a title.
    static func split(_ text: String) -> (topic: String?, body: String) {
        guard let colon = text.range(of: ": ") else { return (nil, text) }
        let head = String(text[..<colon.lowerBound])
        let rest = String(text[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        let sentenceMarks: Set<Character> = [".", "…", "!", "?", "`", "/", "\\", "(", ")"]
        guard (8...64).contains(head.count), !rest.isEmpty, !head.contains(where: sentenceMarks.contains) else { return (nil, text) }
        return (head, rest.prefix(1).uppercased() + rest.dropFirst())
    }

    /// A short digest that survives relaunches (`hashValue` does not), to tell one recap from another.
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}

// MARK: - Seen state

/// Which recap the user has already opened, per session. A recap is "new" until its card has been opened once.
/// Remembered across launches (a small list in `UserDefaults`), because the recap stays in the terminal's
/// history and would otherwise come back as new every time Nook starts.
final class RecapSeenStore: ObservableObject {
    /// Only the main thread touches it (views and button actions), hence `nonisolated(unsafe)`.
    nonisolated(unsafe) static let shared = RecapSeenStore()
    /// Sessions remembered at most; the oldest are forgotten first.
    static let limit = 64

    private struct Entry: Codable, Equatable { var session: String; var digest: String }
    @Published private var entries: [Entry]
    private let defaults: UserDefaults?
    private let key: String

    /// Pass `nil` for `defaults` to keep everything in memory (previews and tests).
    init(defaults: UserDefaults? = .standard, key: String = "nook.recap.seen") {
        self.defaults = defaults
        self.key = key
        entries = defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func isNew(_ recap: String, in session: String) -> Bool {
        entries.first { $0.session == session }?.digest != RecapText.digest(recap)
    }

    func markSeen(_ recap: String, in session: String) {
        guard isNew(recap, in: session) else { return }
        entries.removeAll { $0.session == session }
        entries.append(Entry(session: session, digest: RecapText.digest(recap)))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        if let data = try? JSONEncoder().encode(entries) { defaults?.set(data, forKey: key) }
    }
}

// MARK: - Button

/// "※ Resumen" for the tab row's right controls. Takes no space while the session has no recap. Clicking it opens
/// the recap's card below it; the card closes when the pointer leaves for a moment, like the subagents list.
struct SessionRecapButton: View {
    /// Identifies the session, so each one remembers on its own whether its recap was read.
    var sessionID: String
    /// The session's latest recap as plain text (`TerminalSession.recap`); nil or blank hides the button.
    var recap: String?
    /// Leave the card open while the pointer is elsewhere; previews and tests turn it on.
    var keepsOpen: Bool
    /// Where "Copiar" writes; tests use a private pasteboard so they do not touch the user's clipboard.
    var pasteboard: NSPasteboard
    /// The card's width and the height of its text before it scrolls; they follow the island's size (`PaneLayout`).
    var cardWidth: CGFloat
    var maxBodyHeight: CGFloat
    @ObservedObject private var store: RecapSeenStore
    @State private var open: Bool
    /// Whether the recap was unread when the card opened: the card says "nuevo" even after it is marked read.
    @State private var openedAsNew = false
    @State private var overButton = false
    @State private var overCard = false

    init(sessionID: String, recap: String?, store: RecapSeenStore = .shared, initiallyOpen: Bool = false, keepsOpen: Bool = false, pasteboard: NSPasteboard = .general,
         cardWidth: CGFloat = SessionRecapCard.width, maxBodyHeight: CGFloat = SessionRecapCard.maxBodyHeight) {
        self.sessionID = sessionID
        self.recap = recap
        self.keepsOpen = keepsOpen
        self.pasteboard = pasteboard
        self.cardWidth = cardWidth
        self.maxBodyHeight = maxBodyHeight
        _store = ObservedObject(wrappedValue: store)
        _open = State(initialValue: initiallyOpen)
    }

    static let height: CGFloat = 22
    private var text: String? { RecapText.clean(recap) }
    private var isNew: Bool { text.map { store.isNew($0, in: sessionID) } ?? false }

    var body: some View {
        // Without a recap the body is empty, so the tab row's HStack adds no gap for it.
        if let text {
            button(new: isNew)
                .overlay(alignment: .topTrailing) {
                    if open {
                        SessionRecapCard(text: text, isNew: openedAsNew, pasteboard: pasteboard, width: cardWidth, maxBodyHeight: maxBodyHeight)
                            .onHover { overCard = $0 }
                            // Hangs from the button's top edge, then drops below the tab row.
                            .offset(y: Self.height + 8)
                            .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                }
                .zIndex(1)
                .onAppear { if open { openedAsNew = store.isNew(text, in: sessionID); store.markSeen(text, in: sessionID) } }
                // A new recap while the card is open is read as it arrives.
                .onChange(of: text) { _, new in
                    guard open else { return }
                    openedAsNew = store.isNew(new, in: sessionID); store.markSeen(new, in: sessionID)
                }
                .onChange(of: sessionID) { _, _ in open = false }
                // The recap going away takes the card with it.
                .onDisappear { open = false; overButton = false; overCard = false }
                // Moving from the button to the card leaves both for a moment; leaving them for good closes the card.
                .task(id: overButton || overCard) {
                    guard open, !keepsOpen, !(overButton || overCard) else { return }
                    try? await Task.sleep(for: .seconds(0.7))
                    if !Task.isCancelled { withAnimation(.easeOut(duration: 0.16)) { open = false } }
                }
        }
    }

    private func button(new: Bool) -> some View {
        Button { toggle() } label: {
            HStack(spacing: 4) {
                Text("※").font(.system(size: 9.5, weight: .semibold))
                Text("Resumen").font(.system(size: 9, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 5.5, weight: .bold)).rotationEffect(.degrees(open ? 180 : 0)).opacity(0.7)
            }
            .fixedSize()
            // Unread: brighter than the quiet resting state, plus a mint badge like the one on the collapsed notch.
            .foregroundStyle(new || open ? Color.primary.opacity(0.88) : Color.secondary)
            .padding(.horizontal, 7).frame(height: Self.height)
            .background(Color.white.opacity(open ? 0.12 : (new ? 0.09 : 0.055)), in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .topTrailing) {
                if new {
                    Circle().fill(RecapPalette.accent).frame(width: 5.5, height: 5.5)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1.2).padding(-1.2))
                        .offset(x: 2, y: -2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { overButton = $0 }
        .help(new ? "Resumen nuevo de esta sesión" : "Resumen de esta sesión")
        .accessibilityLabel("Resumen de la sesión")
        .accessibilityValue(new ? "nuevo" : "")
    }

    private func toggle() {
        guard let text else { return }
        if !open {
            openedAsNew = store.isNew(text, in: sessionID)
            store.markSeen(text, in: sessionID)
        }
        withAnimation(.easeOut(duration: 0.16)) { open.toggle() }
    }
}

/// `SessionRecapButton` for an observable session: re-renders when the recap changes and starts fresh (card
/// closed) for each session. Generic so this file does not depend on `TerminalSession`.
struct ObservedRecapButton<Object: ObservableObject>: View {
    @ObservedObject var object: Object
    var id: KeyPath<Object, String>
    var recap: KeyPath<Object, String?>
    var cardWidth: CGFloat = SessionRecapCard.width
    var maxBodyHeight: CGFloat = SessionRecapCard.maxBodyHeight

    var body: some View {
        let session = object[keyPath: id]
        SessionRecapButton(sessionID: session, recap: object[keyPath: recap], cardWidth: cardWidth, maxBodyHeight: maxBodyHeight).id(session)
    }
}

private enum RecapPalette {
    /// Nook's mint accent.
    static let accent = Color(red: 0.32, green: 0.73, blue: 0.61)
}

// MARK: - Card

/// The recap itself, as a card in the island's visual language (same surface as the subagents list): a header
/// with a copy button, the session's topic as a title when the recap opens with one, then the text.
struct SessionRecapCard: View {
    var text: String
    /// Shows the "nuevo" tag.
    var isNew = false
    var pasteboard: NSPasteboard = .general
    /// The card's width and the text's height before it scrolls; in the Normal island they are the two constants below.
    var width = SessionRecapCard.width
    var maxBodyHeight = SessionRecapCard.maxBodyHeight
    @State private var bodyHeight: CGFloat
    @State private var copied = false

    static let width: CGFloat = 360
    /// The card scrolls past this; it must stay inside the panel, below the tab row.
    static let maxBodyHeight: CGFloat = 124

    init(text: String, isNew: Bool = false, pasteboard: NSPasteboard = .general, width: CGFloat = SessionRecapCard.width, maxBodyHeight: CGFloat = SessionRecapCard.maxBodyHeight) {
        self.text = text
        self.isNew = isNew
        self.pasteboard = pasteboard
        self.width = width
        self.maxBodyHeight = maxBodyHeight
        _bodyHeight = State(initialValue: Self.estimatedHeight(of: text, width: width))
    }

    var body: some View {
        let parts = RecapText.split(text)
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 5) {
                    if let topic = parts.topic {
                        Text(topic).font(.system(size: Self.topicSize, weight: .semibold)).foregroundStyle(.primary)
                    }
                    Text(parts.body).font(.system(size: Self.bodySize)).lineSpacing(Self.bodySpacing).foregroundStyle(Color.primary.opacity(0.8))
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.top, 3).padding(.bottom, 12)
                .background(GeometryReader { Color.clear.preference(key: RecapHeightKey.self, value: $0.size.height) })
            }
            .scrollIndicators(.automatic)
            .frame(height: min(max(bodyHeight, 20), maxBodyHeight))
            .onPreferenceChange(RecapHeightKey.self) { bodyHeight = $0 }
            // A long recap scrolls; the fade says so.
            .nookScrollFade(active: bodyHeight > maxBodyHeight, surface: Self.surface)
        }
        .frame(width: width)
        .nookGlassCard(radius: 11, clipsContent: true, fill: Self.surface)
        .shadow(color: .black.opacity(0.55), radius: 14, y: 5)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { copied = false }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("※").font(.system(size: 10)).foregroundStyle(.tertiary)
            Text("Resumen").font(.system(size: 9, weight: .semibold))
            if isNew {
                Text("nuevo").font(.system(size: 7.5, weight: .semibold)).foregroundStyle(RecapPalette.accent)
                    .padding(.horizontal, 4).padding(.vertical, 1.5)
                    .background(RecapPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
            }
            Spacer(minLength: 8)
            Button(action: copy) {
                HStack(spacing: 4) {
                    Text(copied ? "Copiado" : "Copiar").font(.system(size: 8.5))
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 7, weight: .semibold)).frame(width: 15, height: 11)
                        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 3))
                }.foregroundStyle(copied ? RecapPalette.accent : Color.secondary)
            }.buttonStyle(.plain).help("Copiar el resumen")
        }.padding(.horizontal, 12).frame(height: 26)
    }

    private func copy() {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
    }

    private static let surface = Color(white: 0.115)
    private static let topicSize: CGFloat = 11
    private static let bodySize: CGFloat = 10.5
    private static let bodySpacing: CGFloat = 2.5

    /// The body's height before SwiftUI has measured it, close enough that the card does not jump when it opens.
    static func estimatedHeight(of text: String, width cardWidth: CGFloat = SessionRecapCard.width) -> CGFloat {
        let parts = RecapText.split(text)
        let font = NSFont.systemFont(ofSize: bodySize)
        let width = cardWidth - 24
        let box = (parts.body as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let lines = (box.height / (font.ascender - font.descender + font.leading)).rounded(.up)
        let topic: CGFloat = parts.topic == nil ? 0 : 14 + 5
        return topic + lines * (font.ascender - font.descender + font.leading + bodySpacing) + 3 + 12
    }
}

private struct RecapHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
