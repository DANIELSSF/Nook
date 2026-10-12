import AppKit

// How the user shapes the cat: who it is (personality), how much it does (activity), what it looks like (coat, accessory) and
// whether it cheers when Claude finishes. Plain values with their ranges, defaults and persistence, and nothing about views:
// the director reads the first two and the celebration switch, the painter the look, and the settings card edits all of them.
//
// Every default is the cat Nook always had (white, no accessory, a bit of everything), so a Mac that never opens the settings
// sees no difference in how the cat looks.

/// Who the cat is: it decides which gestures it favours and how its face rests.
enum PetPersonality: String, CaseIterable, Identifiable {
    case curious, playful, calm, sleepy
    var id: String { rawValue }

    var title: String {
        switch self { case .curious: "Curioso"; case .playful: "Juguetón"; case .calm: "Tranquilo"; case .sleepy: "Dormilón" }
    }
    /// One line for the settings card.
    var blurb: String {
        switch self {
        case .curious: "De todo un poco: mira, se asea, se asoma y juega."
        case .playful: "Caza bichitos, juega con la bolita y no para quieto."
        case .calm: "Se estira, bosteza y se echa a descansar un rato."
        case .sleepy: "Bosteza, se acurruca y se echa la siesta enseguida."
        }
    }
}

/// How much the cat does on its own. "None" still breathes, blinks and flicks an ear (and still reacts to what happens), but
/// starts no gesture.
enum PetActivity: String, CaseIterable, Identifiable {
    case none, low, normal, high
    var id: String { rawValue }

    var title: String {
        switch self { case .none: "Ninguna"; case .low: "Poca"; case .normal: "Normal"; case .high: "Mucha" }
    }
    var blurb: String {
        switch self {
        case .none: "Solo respira, parpadea y reacciona a lo que pasa."
        case .low: "Un gesto de vez en cuando."
        case .normal: "Un gesto cada medio minuto, más o menos."
        case .high: "Siempre tiene algo entre patas."
        }
    }
    /// How long its pauses between gestures are, against the normal ones. Nil: no gestures at all.
    var pauseScale: Double? {
        switch self { case .none: nil; case .low: 1.9; case .normal: 1; case .high: 0.55 }
    }
}

/// The cat's coat: a colour, and for the tabbies the darker stripes on forehead, flanks and tail.
enum PetCoat: String, CaseIterable, Identifiable {
    case snow, cream, silver, tabby, ginger
    var id: String { rawValue }

    var title: String {
        switch self { case .snow: "Blanco"; case .cream: "Crema"; case .silver: "Gris"; case .tabby: "Atigrado"; case .ginger: "Naranja" }
    }
    /// The fill, in sRGB. All of them stay light enough to read on the island's black.
    var fill: (red: CGFloat, green: CGFloat, blue: CGFloat) {
        switch self {
        case .snow: (1, 1, 1)
        case .cream: (0.97, 0.90, 0.76)
        case .silver: (0.72, 0.77, 0.84)
        case .tabby: (0.82, 0.80, 0.76)
        case .ginger: (0.96, 0.69, 0.42)
        }
    }
    /// The stripes' colour, for the coats that have them.
    var stripe: (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        switch self {
        case .tabby: (0.36, 0.34, 0.33)
        case .ginger: (0.72, 0.40, 0.20)
        default: nil
        }
    }
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// Something small the cat wears. They hang from the neck or sit on the face, so they follow the head wherever it goes.
enum PetAccessory: String, CaseIterable, Identifiable {
    case none, collar, bow, glasses
    var id: String { rawValue }

    var title: String {
        switch self { case .none: "Ninguno"; case .collar: "Cascabel"; case .bow: "Pajarita"; case .glasses: "Gafas" }
    }
}

/// What the painter needs to dress the cat.
struct PetLook: Equatable {
    var coat = PetCoat.snow
    var accessory = PetAccessory.none
}

struct PetPreferences: Equatable {
    var personality = PetPersonality.curious
    var activity = PetActivity.normal
    var coat = PetCoat.snow
    var accessory = PetAccessory.none
    /// The hop of joy when Claude finishes a task. Off: the cat takes it in stride.
    var celebrates = true

    var look: PetLook { PetLook(coat: coat, accessory: accessory) }
    var isDefault: Bool { self == PetPreferences() }

    // MARK: Persistence

    enum Key {
        static let personality = "pet.personality"
        static let activity = "pet.activity"
        static let coat = "pet.coat"
        static let accessory = "pet.accessory"
        static let celebrates = "pet.celebrates"
    }

    /// What is stored. A key that is missing (a Mac that never changed it) or holds something that is not one of the choices
    /// (an old build, a hand-edited plist) is the default.
    static func load(from defaults: UserDefaults = .standard) -> PetPreferences {
        func choice<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            (defaults.string(forKey: key)).flatMap(T.init(rawValue:)) ?? fallback
        }
        var prefs = PetPreferences()
        prefs.personality = choice(Key.personality, prefs.personality)
        prefs.activity = choice(Key.activity, prefs.activity)
        prefs.coat = choice(Key.coat, prefs.coat)
        prefs.accessory = choice(Key.accessory, prefs.accessory)
        if let value = defaults.object(forKey: Key.celebrates) as? Bool { prefs.celebrates = value }
        return prefs
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(personality.rawValue, forKey: Key.personality)
        defaults.set(activity.rawValue, forKey: Key.activity)
        defaults.set(coat.rawValue, forKey: Key.coat)
        defaults.set(accessory.rawValue, forKey: Key.accessory)
        defaults.set(celebrates, forKey: Key.celebrates)
    }
}

// MARK: - The Mac's state, as the cat reads it

/// How much the Mac can spare. Low Power Mode and a warm machine ask for fewer and cheaper animations; a hot one for none.
enum PetPower: Int, Comparable {
    /// Everything.
    case normal
    /// Low Power Mode, or a machine that is getting warm: slower frames, and only the gestures that are cheap to draw.
    case saving
    /// A machine that is too hot: the cat holds a still pose and runs nothing.
    case minimal
    static func < (a: PetPower, b: PetPower) -> Bool { a.rawValue < b.rawValue }

    static func of(lowPower: Bool, thermal: ProcessInfo.ThermalState) -> PetPower {
        switch thermal {
        case .critical: return .minimal
        case .serious: return .saving
        default: return lowPower ? .saving : .normal
        }
    }
}

/// The part of the day, which tilts the cat's mood: sleepier at night, stretchier in the morning.
enum PetDayPart: Equatable {
    case morning, day, evening, night
    static func of(hour: Int) -> PetDayPart {
        switch hour { case 6..<10: .morning; case 10..<18: .day; case 18..<23: .evening; default: .night }
    }
}

/// Reads the system's power and thermal state once and keeps it, so the cat's views ask a stored value on each frame instead of the
/// system, and hear about a change from a notification.
///
/// It also keeps whether anyone can see a screen at all (`screensDark`): displays asleep, the screen locked, or the user's session
/// switched away. A window's occlusion does not say so in every case (a display that sleeps covers no window), and a cat that kept its
/// timer then would wake the Mac and repaint for nobody, for as long as the Mac stays awake with its screens off.
final class PetPowerMonitor {
    static let shared = PetPowerMonitor()
    /// Posted (on the main queue) when `state` or `screensDark` changes.
    static let didChange = Notification.Name("dev.nook.PetPowerDidChange")
    private(set) var state: PetPower
    /// Why no screen can be seen right now ("pantallas", "bloqueo", "sesión"); empty while one can.
    private(set) var darkReasons = Set<String>()
    /// No screen can be seen: the cats hold still and keep no timer until one can.
    var screensDark: Bool { !darkReasons.isEmpty }
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var listeners: [PetDistributedListener] = []

    private init() {
        state = Self.read()
        let center = NotificationCenter.default
        let update: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            let now = Self.read()
            guard now != self.state else { return }
            self.state = now
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
        observers.append((center, center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: update)))
        observers.append((center, center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: update)))
        // The same moments `AppModel.restReasons` follows, heard here so the cats need no model to know them.
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ reason: String, dark: Bool) {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.screens(reason, dark: dark) }))
        }
        on(NSWorkspace.screensDidSleepNotification, "pantallas", dark: true)
        on(NSWorkspace.screensDidWakeNotification, "pantallas", dark: false)
        on(NSWorkspace.sessionDidResignActiveNotification, "sesión", dark: true)
        on(NSWorkspace.sessionDidBecomeActiveNotification, "sesión", dark: false)
        listeners.append(PetDistributedListener("com.apple.screenIsLocked") { [weak self] in self?.screens("bloqueo", dark: true) })
        listeners.append(PetDistributedListener("com.apple.screenIsUnlocked") { [weak self] in self?.screens("bloqueo", dark: false) })
        // Locked when Nook starts (a relaunch at the login window, a test run on a locked Mac), or with its displays already asleep. Set
        // without a word: nothing has changed for anyone yet, and a post from inside `shared`'s first use would call back into it.
        let now = Self.darkness()
        if now.locked { darkReasons.insert("bloqueo") }
        if now.asleep { darkReasons.insert("pantallas") }
    }
    deinit { observers.forEach { $0.0.removeObserver($0.1) } }

    /// A reason for the screens being dark starts or ends; the cats hear about it when that changes whether any can be seen.
    func screens(_ reason: String, dark: Bool) {
        let was = screensDark
        if dark { darkReasons.insert(reason) } else { darkReasons.remove(reason) }
        if screensDark != was { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    /// Asks the system again whether the screen is locked and whether every display sleeps, in case a notification was missed. Cheap
    /// enough for the rare moments a cat's window may have come into sight (`PetSight.wakeups`), not for every frame.
    func recheck() {
        let now = Self.darkness()
        screens("bloqueo", dark: now.locked)
        screens("pantallas", dark: now.asleep)
    }

    /// What the system says right now: whether the screen is locked, and whether every display sleeps.
    private static func darkness() -> (locked: Bool, asleep: Bool) {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        var displays = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        let online = CGGetOnlineDisplayList(16, &displays, &count) == .success ? Array(displays.prefix(Int(count))) : []
        return ((session?["CGSSessionScreenIsLocked"] as? Bool) == true, !online.isEmpty && online.allSatisfy { CGDisplayIsAsleep($0) != 0 })
    }

    private static func read() -> PetPower {
        let info = ProcessInfo.processInfo
        return PetPower.of(lowPower: info.isLowPowerModeEnabled, thermal: info.thermalState)
    }
}

/// Hears a distributed notification even while Nook is not the active app. AppKit holds them back from an app that is not active
/// unless asked to deliver at once, and Nook is almost never the active app: a cat that heard of the lock while Nook had the keyboard
/// would not hear of the unlock until the user clicked into Nook again, and would sit frozen until then.
final class PetDistributedListener: NSObject {
    private let action: () -> Void
    init(_ name: String, _ action: @escaping () -> Void) {
        self.action = action
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(heard(_:)), name: Notification.Name(name), object: nil, suspensionBehavior: .deliverImmediately)
    }
    deinit { DistributedNotificationCenter.default().removeObserver(self) }
    @objc private func heard(_ notification: Notification) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }
}
