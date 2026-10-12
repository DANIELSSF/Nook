import AppKit

// The sound an alert may make (`AppModel.raiseAlert`). For a long time alerts were silent on purpose, Terminal having its own bell;
// now the user picks: a switch for every tab at once, one per tab, and which of the Mac's own sounds says what happened.
//
// Plain values and their persistence here, the decision with the model, and the playing behind a protocol: a model plays through
// a silent player until the running app gives it the real one (`AppDelegate`), so no test or preview ever makes a noise.

/// One of the Mac's own alert sounds (`/System/Library/Sounds`), the soft and pleasant ones.
enum AlertSound: String, CaseIterable, Identifiable {
    case glass, ping, pop, purr, tink, funk, hero, submarine, bottle
    var id: String { rawValue }

    /// The name `NSSound(named:)` knows it by.
    var systemName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var title: String {
        switch self {
        case .glass: "Cristal"
        case .ping: "Ping"
        case .pop: "Pop"
        case .purr: "Ronroneo"
        case .tink: "Tintineo"
        case .funk: "Funk"
        case .hero: "Héroe"
        case .submarine: "Submarino"
        case .bottle: "Botella"
        }
    }
}

/// How alerts sound: whether they do at all (every tab at once; each tab has its own switch too, `TerminalSession.alertSoundOn`),
/// the sound for each kind of alert, so the ear tells a finished turn from a question, and how loud.
struct AlertSoundSettings: Equatable {
    /// On unless the user turns it off.
    var enabled = true
    /// The agent finished its turn.
    var finished = AlertSound.glass
    /// The agent asks something: a permission, a choice, a question.
    var question = AlertSound.ping
    /// The agent stopped with an error.
    var failed = AlertSound.funk
    /// 0…1, against the Mac's own volume.
    var volume = 0.6 {
        didSet { if !(0...1).contains(volume) { volume = volume.isFinite ? min(max(volume, 0), 1) : 0.6 } }
    }

    func sound(for kind: NookAlert.Kind) -> AlertSound {
        switch kind { case .finished: finished; case .question: question; case .failed: failed }
    }
    mutating func setSound(_ sound: AlertSound, for kind: NookAlert.Kind) {
        switch kind { case .finished: finished = sound; case .question: question = sound; case .failed: failed = sound }
    }

    /// What an alert of `kind` plays on a tab whose own switch is `tabOn`: nothing unless both switches are on.
    func sound(for kind: NookAlert.Kind, tabOn: Bool) -> AlertSound? {
        enabled && tabOn && volume > 0 ? sound(for: kind) : nil
    }

    // MARK: Persistence

    enum Key {
        static let enabled = "alertSound.enabled"
        static let finished = "alertSound.finished"
        static let question = "alertSound.question"
        static let failed = "alertSound.failed"
        static let volume = "alertSound.volume"
        /// The tabs whose own switch is off, by id; every other tab's is on.
        static let mutedTabs = "alertSound.mutedTabs"
    }

    /// What is stored; anything missing or unreadable (an old build, a hand-edited plist) is the default.
    static func load(from defaults: UserDefaults) -> AlertSoundSettings {
        var settings = AlertSoundSettings()
        func sound(_ key: String, _ fallback: AlertSound) -> AlertSound { defaults.string(forKey: key).flatMap(AlertSound.init(rawValue:)) ?? fallback }
        if let enabled = defaults.object(forKey: Key.enabled) as? Bool { settings.enabled = enabled }
        settings.finished = sound(Key.finished, settings.finished)
        settings.question = sound(Key.question, settings.question)
        settings.failed = sound(Key.failed, settings.failed)
        if let volume = defaults.object(forKey: Key.volume) as? Double { settings.volume = volume }
        return settings
    }

    func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: Key.enabled)
        defaults.set(finished.rawValue, forKey: Key.finished)
        defaults.set(question.rawValue, forKey: Key.question)
        defaults.set(failed.rawValue, forKey: Key.failed)
        defaults.set(volume, forKey: Key.volume)
    }
}

/// Plays an alert's sound. The model starts with `SilentAlertSoundPlayer`; the running app installs `SystemAlertSoundPlayer`.
protocol AlertSoundPlaying: AnyObject {
    func play(_ sound: AlertSound, volume: Double)
}

/// Plays nothing: what every model has until the running app gives it the real player.
final class SilentAlertSoundPlayer: AlertSoundPlaying {
    func play(_ sound: AlertSound, volume: Double) {}
}

/// The Mac's own sounds, through `NSSound`. Each is loaded once; one still playing starts over, so two alerts in a row are two
/// sounds and not a sound that ignored the second.
final class SystemAlertSoundPlayer: AlertSoundPlaying {
    private var loaded: [AlertSound: NSSound] = [:]

    func play(_ sound: AlertSound, volume: Double) {
        guard let player = loaded[sound] ?? NSSound(named: sound.systemName) else { return }
        loaded[sound] = player
        if player.isPlaying { player.stop() }
        player.volume = Float(min(max(volume, 0), 1))
        player.play()
    }
}
