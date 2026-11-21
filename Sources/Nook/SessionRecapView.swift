import SwiftUI
import AppKit

// Claude Code prints a recap ("※ recap: …") when you come back to a session. Nook keeps it out of the mirror and
// offers it here: a small "Resumen" button in the session-tab row (it costs no mirror height) that opens a card
// over the top of the mirror. A recap the user has not opened yet is marked with a small mint badge, quietly.
//
// The summary Claude Code writes when it compacts the session's context (`CompactionSummary`) is offered the same way, by a
// second button beside it (`RecapKind.compaction`): both are icons alone, said in words by their tip, and the summary's card
// shows its Markdown as the mirror does, in the mirror's own view.
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

// MARK: - Kinds

/// What a button of this file offers: Claude's recap, or the summary of a compaction.
enum RecapKind: Equatable {
    case recap, compaction

    /// The words the button stands for, in its tip and the card's header.
    var title: String { self == .recap ? "Resumen" : "Resumen de la compactación" }
    var tip: NookTip {
        self == .recap ? NookTip("Resumen", detail: "Lo que Claude cuenta de esta sesión al volver a ella")
            : NookTip("Resumen de la compactación", detail: "Lo que Claude guardó de la conversación al compactar su contexto")
    }
    var tipID: String { self == .recap ? "sessionRecap" : "compactionSummary" }
    /// The key the seen state keeps it under: a session's recap and its compaction summary are read apart.
    func storeKey(_ session: String) -> String { self == .recap ? session : session + "#compaction" }
    /// The text worth showing; nil hides the button.
    func text(_ raw: String?) -> String? {
        switch self {
        case .recap: RecapText.clean(raw)
        case .compaction: CompactionSummary.shown(raw)
        }
    }
}

/// The kind's mark: Claude's own "※" for the recap, a compressed page for the compaction.
struct RecapKindGlyph: View {
    var kind: RecapKind
    var size: CGFloat = 10.5

    var body: some View {
        switch kind {
        case .recap: Text("※").font(.system(size: size, weight: .semibold))
        case .compaction: Image(systemName: "rectangle.compress.vertical").font(.system(size: size - 0.5, weight: .medium))
        }
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
    /// The recap, or the compaction's summary.
    var kind: RecapKind
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

    init(sessionID: String, recap: String?, kind: RecapKind = .recap, store: RecapSeenStore = .shared, initiallyOpen: Bool = false, keepsOpen: Bool = false,
         pasteboard: NSPasteboard = .general, cardWidth: CGFloat = SessionRecapCard.width, maxBodyHeight: CGFloat = SessionRecapCard.maxBodyHeight) {
        self.sessionID = sessionID
        self.kind = kind
        self.recap = recap
        self.keepsOpen = keepsOpen
        self.pasteboard = pasteboard
        self.cardWidth = cardWidth
        self.maxBodyHeight = maxBodyHeight
        _store = ObservedObject(wrappedValue: store)
        _open = State(initialValue: initiallyOpen)
    }

    static let height: CGFloat = 22
    private var text: String? { kind.text(recap) }
    private var key: String { kind.storeKey(sessionID) }
    private var isNew: Bool { text.map { store.isNew($0, in: key) } ?? false }
    @State private var hovering = false

    var body: some View {
        // Without a recap the body is empty, so the tab row's HStack adds no gap for it.
        if let text {
            button(new: isNew)
                .overlay(alignment: .topTrailing) {
                    if open {
                        SessionRecapCard(text: text, kind: kind, isNew: openedAsNew, pasteboard: pasteboard, width: cardWidth, maxBodyHeight: maxBodyHeight)
                            // It hangs over the conversation: the arrow shows over it, not the text's I-beam.
                            .pointerHole()
                            .onHover { overCard = $0 }
                            // Hangs from the button's top edge, then drops below the tab row.
                            .offset(y: Self.height + 8)
                            .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                }
                .zIndex(1)
                .onAppear { if open { openedAsNew = store.isNew(text, in: key); store.markSeen(text, in: key) } }
                // A new recap while the card is open is read as it arrives.
                .onChange(of: text) { _, new in
                    guard open else { return }
                    openedAsNew = store.isNew(new, in: key); store.markSeen(new, in: key)
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

    /// The button is its mark alone, in a small square chip; its tip says what it is (`RecapKind.tip`), as VoiceOver does.
    private func button(new: Bool) -> some View {
        Button { toggle() } label: {
            RecapKindGlyph(kind: kind)
            .frame(width: Self.height, height: Self.height)
            // Unread or under the pointer: brighter than the quiet resting state; unread also wears a mint badge like the one on the
            // collapsed notch.
            .foregroundStyle(new || open || hovering ? Color.primary.opacity(0.88) : Color.nookSecondary)
            .background(Color.nookWash(open ? 0.12 : hovering ? 0.10 : (new ? 0.09 : 0.055)), in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .topTrailing) {
                if new {
                    Circle().fill(RecapPalette.accent).frame(width: 5.5, height: 5.5)
                        .overlay(Circle().stroke(Color.nookScreenSolid, lineWidth: 1.2).padding(-1.2))
                        .offset(x: 2, y: -2)
                }
            }
            .contentShape(Rectangle())
        }
        .nookPress(.pop)
        .onHover { overButton = $0; hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        // Not while its card is open: the card says it.
        .nookTip(open ? nil : kind.tip, id: kind.tipID)
        .accessibilityLabel(kind.title)
        .accessibilityValue(new ? "nuevo" : "")
    }

    private func toggle() {
        guard let text else { return }
        if !open {
            openedAsNew = store.isNew(text, in: key)
            store.markSeen(text, in: key)
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
    var kind: RecapKind = .recap
    var cardWidth: CGFloat = SessionRecapCard.width
    var maxBodyHeight: CGFloat = SessionRecapCard.maxBodyHeight

    var body: some View {
        let session = object[keyPath: id]
        SessionRecapButton(sessionID: session, recap: object[keyPath: recap], kind: kind, cardWidth: cardWidth, maxBodyHeight: maxBodyHeight).id(session)
    }
}

private enum RecapPalette {
    /// Nook's mint accent.
    static let accent = Color.nookMint
}

// MARK: - Card

/// The recap itself, as a card in the island's visual language (same surface as the subagents list): a header
/// with a copy button, the session's topic as a title when the recap opens with one, then the text.
struct SessionRecapCard: View {
    var text: String
    var kind: RecapKind = .recap
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

    init(text: String, kind: RecapKind = .recap, isNew: Bool = false, pasteboard: NSPasteboard = .general, width: CGFloat = SessionRecapCard.width,
         maxBodyHeight: CGFloat = SessionRecapCard.maxBodyHeight) {
        self.text = text
        self.kind = kind
        self.isNew = isNew
        self.pasteboard = pasteboard
        self.width = width
        self.maxBodyHeight = maxBodyHeight
        _bodyHeight = State(initialValue: Self.estimatedHeight(of: text, width: width))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if kind == .compaction { summary } else { recapBody }
        }
        .frame(width: width)
        .nookGlassCard(radius: 11, clipsContent: true, fill: Self.surface)
        .nookCardShadow(0.55, radius: 14, y: 5)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { copied = false }
        }
    }

    /// The compaction's summary, long and in Markdown, in the mirror's own view: its headings, lists, `code` and blocks look as in
    /// the conversation, it scrolls from its top, and it can be selected and copied (the reply's own copy button copies it too).
    private var summary: some View {
        LiveTerminalSurface(text: TranscriptRenderer.indented("⏺ ", text), transcript: true, fontSize: Self.summaryFontSize, opensAtTop: true, showsWayBack: false)
            .padding(.leading, 8).padding(.trailing, 4).padding(.bottom, 8)
            .frame(height: maxBodyHeight)
    }

    private var recapBody: some View {
        let parts = RecapText.split(text)
        return ScrollView(.vertical) {
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

    private var header: some View {
        HStack(spacing: 6) {
            RecapKindGlyph(kind: kind, size: 10).foregroundStyle(Color.nookTertiary)
            Text(kind.title).font(.system(size: 9, weight: .semibold))
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
                        .background(Color.nookWash(0.09), in: RoundedRectangle(cornerRadius: 3))
                }.foregroundStyle(copied ? RecapPalette.accent : Color.nookSecondary)
            }.nookPress(.squeeze, depth: PressDepth.card, strength: 0.5).help(kind == .recap ? "Copiar el resumen" : "Copiar el resumen de la compactación")
        }.padding(.horizontal, 12).frame(height: 26)
    }

    private func copy() {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
    }

    private static let surface = Color.nookCard
    /// The summary's text: a point under the chat's default, in a card narrower than the conversation.
    static let summaryFontSize: Double = 10
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
