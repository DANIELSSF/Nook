import AppKit
import AVFoundation
import Speech

/// The macOS permissions Nook uses: what each one is for, whether it is on, and how to turn it on
/// (asking macOS where it can still ask, else opening the exact pane of System Settings).
enum NookPermission: String, CaseIterable, Identifiable {
    case automation, accessibility, microphone, speech, screenRecording
    var id: String { rawValue }

    enum State: Equatable {
        case granted
        /// Never asked yet: Nook can show macOS's own prompt.
        case notAsked
        /// Refused or switched off: only System Settings can turn it on.
        case denied
        /// Can't tell right now (Terminal is not open, so its permission can't be read).
        case unknown
    }

    var title: String {
        switch self {
        case .automation: "Controlar Terminal"
        case .accessibility: "Accesibilidad"
        case .microphone: "Micrófono"
        case .speech: "Reconocimiento de voz"
        case .screenRecording: "Grabación de pantalla"
        }
    }

    var symbol: String {
        switch self {
        case .automation: "terminal"
        case .accessibility: "keyboard"
        case .microphone: "mic"
        case .speech: "waveform"
        case .screenRecording: "rectangle.dashed.badge.record"
        }
    }

    var purpose: String {
        switch self {
        case .automation: "Leer tus pestañas de Terminal y escribir en ellas tus mensajes. Sin él, Nook no puede seguir pestañas de Terminal."
        case .accessibility: "Pulsar flechas, Tab y Esc en menús, selectores (modelos) y paneles (/usage), ⇧⇥ para el modo y ⌘T para abrir pestañas (sin él, en una ventana). Mensajes, Enter, elegir opciones en la tarjeta de preguntas y pegar imágenes funcionan sin él."
        case .microphone: "Escuchar tu voz para dictar el borrador."
        case .speech: "Convertir lo que dictas en texto. Usa el reconocimiento del Mac cuando está disponible."
        case .screenRecording: "Que Claude vea tu pantalla (visión de pantalla): capturas sin las ventanas de Nook al enviar un mensaje o cuando Claude las pide. Solo se usa si activas la visión de pantalla."
        }
    }

    /// Needed for Nook's main job; the others add features.
    var essential: Bool { self == .automation }

    /// The pane of System Settings where it is switched on.
    var settingsURL: URL {
        let pane = switch self {
        case .automation: "Privacy_Automation"
        case .accessibility: "Privacy_Accessibility"
        case .microphone: "Privacy_Microphone"
        case .speech: "Privacy_SpeechRecognition"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane)!
    }

    /// The guide, step by step, for doing it by hand.
    var steps: [String] {
        let open = "Abre Ajustes del Sistema → Privacidad y seguridad → \(settingsName)."
        switch self {
        case .automation:
            return [open, "Busca Nook y activa «Terminal» debajo de él.",
                    "Si Nook no aparece, pulsa «Pedir permiso» aquí: macOS muestra su aviso la primera vez que Nook habla con Terminal (Terminal tiene que estar abierta)."]
        case .accessibility:
            return [open, "Activa Nook. Si no está en la lista, pulsa «+» y elige Nook.app (en la carpeta dist del proyecto o donde lo tengas).",
                    "Si Ajustes lo muestra activado pero Nook dice que no lo está, pulsa «Abrir Ajustes» aquí: Nook se registra de nuevo y solo tienes que activarlo una vez."]
        case .microphone, .speech:
            return [open, "Activa Nook.", "Si no aparece, pulsa «Pedir permiso» aquí o usa el micrófono de Nook: macOS pregunta la primera vez."]
        case .screenRecording:
            return [open, "Activa Nook. Si no está en la lista, pulsa «Pedir permiso» aquí: macOS lo añade la primera vez.",
                    "Si macOS te ofrece «Salir y volver a abrir», acéptalo: el permiso cuenta desde que Nook vuelve a abrirse."]
        }
    }

    private var settingsName: String {
        switch self {
        case .automation: "Automatización"
        case .accessibility: "Accesibilidad"
        case .microphone: "Micrófono"
        case .speech: "Reconocimiento de voz"
        case .screenRecording: Self.screenRecordingPane
        }
    }

    /// Screen Recording's pane, by the name macOS gives it.
    static let screenRecordingPane = "Grabación de pantalla y audio del sistema"

    /// The state now, without prompting. Reading Terminal's permission talks to the system, so call
    /// this off the main thread.
    func state() -> State {
        switch self {
        case .accessibility: return AXIsProcessTrusted() ? .granted : .notAsked
        case .automation: return Self.automationState(Self.automationStatus(ask: false))
        case .microphone: return Self.captureState(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speech: return Self.speechState(SFSpeechRecognizer.authorizationStatus())
        case .screenRecording: return ScreenRecordingAccess.state()
        }
    }

    /// Turns it on the only way possible from here: macOS's prompt while it can still ask, System
    /// Settings otherwise. `completion` gets the state afterwards, on the main thread.
    func request(completion: @escaping (State) -> Void = { _ in }) {
        let finish = { (state: State) in DispatchQueue.main.async { completion(state) } }
        let current = state()
        guard current != .granted else { return finish(.granted) }
        guard current == .notAsked else { NSWorkspace.shared.open(settingsURL); return finish(current) }
        switch self {
        case .accessibility:
            // macOS has no answer to wait for: it opens its prompt and the user goes to Settings.
            DirectKeys.request(); finish(state())
        case .automation:
            DispatchQueue.global(qos: .userInitiated).async { finish(Self.automationState(Self.automationStatus(ask: true))) }
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in finish(self.state()) }
        case .speech:
            SFSpeechRecognizer.requestAuthorization { _ in finish(self.state()) }
        case .screenRecording:
            // macOS shows its prompt once and answers at once; the switch itself is in System Settings.
            ScreenRecordingAccess.request(); finish(state())
        }
    }

    func openSettings() {
        // Accessibility's pane goes through its request, which first clears a record macOS no longer honours.
        if self == .accessibility && !DirectKeys.allowed { DirectKeys.request() } else { NSWorkspace.shared.open(settingsURL) }
    }

    static func automationStatus(ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal")
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
    }

    static func automationState(_ status: OSStatus) -> State {
        switch status {
        case noErr: .granted
        case OSStatus(errAEEventNotPermitted): .denied
        case OSStatus(errAEEventWouldRequireUserConsent): .notAsked
        default: .unknown   // procNotFound: Terminal is not open
        }
    }

    static func captureState(_ status: AVAuthorizationStatus) -> State {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notAsked
        case .denied, .restricted: .denied
        @unknown default: .unknown
        }
    }

    static func speechState(_ status: SFSpeechRecognizerAuthorizationStatus) -> State {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notAsked
        case .denied, .restricted: .denied
        @unknown default: .unknown
        }
    }

    /// macOS only says whether Screen Recording is granted. Once Nook has asked, its prompt never shows again, so "not granted"
    /// means refused or switched off.
    static func screenRecordingState(granted: Bool, asked: Bool) -> State {
        granted ? .granted : asked ? .denied : .notAsked
    }

    /// Every permission's state, read off the main thread and delivered on it.
    static func states(completion: @escaping ([NookPermission: State]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let states = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.state()) })
            DispatchQueue.main.async { completion(states) }
        }
    }
}
