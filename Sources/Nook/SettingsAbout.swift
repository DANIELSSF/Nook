import SwiftUI

// «Acerca de», at the bottom of the settings card's Isla tab: the version of Nook, and behind it the way to Nook Remoto. Nook Remoto stays out of the card until someone who knows taps the
// version five times in a row, as Android keeps its developer options behind the build number. The line looks like plain text (no button, no hover, no pointer, no tooltip), but it
// feels the press, says how many taps are left from the third one, and tells VoiceOver what it is for.
//
//   NookVersion            the line «Nook 0.2.1 (3)», read from the bundle (with something sensible where the bundle has no version: a test run, `swift run`)
//   UnlockTapCounter       the five taps in a row (plain values and a clock that is handed in, so the tests hold it to the count and to the pause)
//   SettingsAboutNote      what the line says for each tap, and for how long
//   SettingsAboutSection   the section

// MARK: - The version

/// The version of Nook as the «Acerca de» line says it.
struct NookVersion: Equatable {
    var short: String?
    var build: String?

    init(short: String?, build: String?) {
        self.short = Self.clean(short)
        self.build = Self.clean(build)
    }

    /// From an Info.plist's dictionary (`CFBundleShortVersionString` and `CFBundleVersion`).
    init(info: [String: Any]?) {
        self.init(short: info?["CFBundleShortVersionString"] as? String, build: info?["CFBundleVersion"] as? String)
    }

    /// This app's own. Where the app is not a bundle of its own (the tests run inside their runner; `swift run` has no Info.plist), `Bundle.main` has other numbers or none, and the
    /// line says what it has.
    static var current: NookVersion { NookVersion(info: Bundle.main.infoDictionary) }

    /// «Nook 0.2.1 (3)»; with only one of the two, that one; with neither, that it is not a release build.
    var line: String {
        switch (short, build) {
        case let (short?, build?): return "Nook \(short) (\(build))"
        case let (short?, nil): return "Nook \(short)"
        case let (nil, build?): return "Nook (\(build))"
        case (nil, nil): return "Nook (versión de desarrollo)"
        }
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - The five taps

/// The taps on the version line, counted the way Android counts the taps on its build number: taps in a row, each within `window` of the one before, count; a pause longer than that starts
/// the count over. The first two say nothing, so a stray click tells nobody; from the third on, the line says how many are left; the fifth one unlocks. Once it is unlocked, a tap only says so.
struct UnlockTapCounter: Equatable {
    /// Taps in a row that unlock.
    static let needed = 5
    /// The tap from which the user is told how many are left.
    static let hintsFrom = 3
    /// The longest pause between one tap and the next that does not start the count over.
    static let window: TimeInterval = 2

    enum Outcome: Equatable {
        /// One of the first taps: nothing to say.
        case counting
        /// This many are left.
        case remaining(Int)
        /// That was the last one.
        case unlocked
        /// Nothing to count: it is unlocked already.
        case alreadyUnlocked
    }

    /// Taps counted so far in this run.
    private(set) var count = 0
    private var last: TimeInterval?

    /// A tap at `now`, in seconds on a clock that does not go back (one that did, as a clock set by hand can, starts the count over).
    mutating func tap(at now: TimeInterval, alreadyUnlocked: Bool = false) -> Outcome {
        if alreadyUnlocked {
            reset()
            return .alreadyUnlocked
        }
        if let last, now - last > Self.window || now < last { count = 0 }
        count += 1
        last = now
        if count >= Self.needed {
            reset()
            return .unlocked
        }
        return count >= Self.hintsFrom ? .remaining(Self.needed - count) : .counting
    }

    mutating func reset() {
        count = 0
        last = nil
    }
}

// MARK: - What the line says

/// What the line shows beside the version for a moment after a tap.
struct SettingsAboutNote: Equatable {
    enum Kind: Equatable {
        /// A count: how many taps are left.
        case progress
        /// It worked.
        case done
        /// An aside.
        case quiet
    }

    var text: String
    var kind: Kind
    /// How long it stays, in seconds, unless another tap replaces it.
    var lifetime: TimeInterval

    /// What a tap that came out as `outcome` says; nothing for the first two taps.
    static func make(for outcome: UnlockTapCounter.Outcome) -> SettingsAboutNote? {
        switch outcome {
        case .counting: return nil
        // The count is out of date once the pause that would start it over has passed, so the hint goes then.
        case .remaining(let left): return SettingsAboutNote(text: SettingsAboutCopy.remaining(left), kind: .progress, lifetime: UnlockTapCounter.window)
        case .unlocked: return SettingsAboutNote(text: SettingsAboutCopy.unlocked, kind: .done, lifetime: 3)
        case .alreadyUnlocked: return SettingsAboutNote(text: SettingsAboutCopy.alreadyUnlocked, kind: .quiet, lifetime: 2.5)
        }
    }
}

enum SettingsAboutCopy {
    static let title = "Acerca de"
    // "Desbloquear", never "activar": turning the server on is what the Remoto tab calls activating.
    static let unlocked = "Nook Remoto desbloqueado"
    static let alreadyUnlocked = "Nook Remoto ya está desbloqueado"
    /// What VoiceOver says after the version: the way to it, since there is nothing to see; and, once it is unlocked, that it is.
    static let hint = "Púlsalo cinco veces seguidas para desbloquear Nook Remoto."
    static let hintUnlocked = "Nook Remoto ya está desbloqueado."

    /// «Faltan 2 toques para desbloquear Remoto», and «Falta 1 toque…» for the last one: short enough to sit beside the whole version
    /// in the card's width.
    static func remaining(_ taps: Int) -> String {
        taps == 1 ? "Falta 1 toque para desbloquear Remoto" : "Faltan \(taps) toques para desbloquear Remoto"
    }
}

// MARK: - The section

struct SettingsAboutSection: View {
    var version: NookVersion
    @ObservedObject var remote: RemoteAccess
    /// The fifth tap worked (the card takes the user to the new tab after a beat).
    var onUnlocked: () -> Void = {}
    /// Seconds on a clock that never goes back; the tests hand in their own.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    @State private var taps = UnlockTapCounter()
    @State private var note: SettingsAboutNote?
    /// Goes up with every tap: the note's lifetime starts over, and the one that was running is cancelled.
    @State private var tapID = 0
    private let gate = NookMotionGate()

    /// How far the line sinks while it is pressed: a little less than an icon does (`PressDepth.icon`), since a line of text is wider than an icon and the same share is more points.
    private static let pressDepth: CGFloat = 0.94

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(SettingsAboutCopy.title)
            HStack(spacing: 8) {
                // Plain text that feels the press: no chrome, no hover, no pointer, no tooltip (a sunk line, or a dimmed one where nothing may move, is the whole answer).
                Button(action: tap) {
                    Text(version.line).font(.system(size: 11)).foregroundStyle(Color.nookSecondary).lineLimit(1)
                        .padding(.vertical, 3).padding(.trailing, 8).contentShape(Rectangle())
                }.nookPress(.none, depth: Self.pressDepth)
                    .accessibilityLabel(version.line)
                    .accessibilityHint(remote.unlocked ? SettingsAboutCopy.hintUnlocked : SettingsAboutCopy.hint)
                Spacer(minLength: 6)
                // Where the two do not fit (a long version, no version at all), it is the version that gives way: what a tap says matters more.
                if let note { noteView(note).layoutPriority(1).transition(.opacity) }
            }.frame(height: 20)
        }
        .animation(gate.fades ? .easeOut(duration: 0.16) : nil, value: note)
        .task(id: tapID) {
            guard let lifetime = note?.lifetime else { return }
            try? await Task.sleep(for: .seconds(lifetime))
            if !Task.isCancelled { note = nil }
        }
    }

    private func noteView(_ note: SettingsAboutNote) -> some View {
        HStack(spacing: 4) {
            if note.kind == .done { Image(systemName: "checkmark.circle.fill").font(.system(size: 10, weight: .semibold)) }
            Text(note.text).font(.system(size: 10, weight: note.kind == .done ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .foregroundStyle(note.kind == .quiet ? Color.nookSecondary : Color.nookMint)
        .accessibilityElement(children: .combine)
    }

    private func tap() {
        let outcome = taps.tap(at: clock(), alreadyUnlocked: remote.unlocked)
        if outcome == .unlocked {
            remote.unlock()
            onUnlocked()
        }
        note = SettingsAboutNote.make(for: outcome)
        tapID += 1
        // What the line says is for the eyes; VoiceOver is told it too.
        if let note { AccessibilityNotification.Announcement(note.text).post() }
    }
}
