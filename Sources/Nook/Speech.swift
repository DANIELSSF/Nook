import AVFoundation
import Speech
import Combine

final class SpeechController: ObservableObject {
    @Published var recording = false
    @Published var transcript = ""
    @Published var error: String?
    /// Both are made the first time dictation starts. A pane makes its controller every time the island is drawn again, and each
    /// recognizer made up front stayed alive for good (its dictation connection, queue and observers): one more per reading of
    /// Terminal, for as long as Nook ran.
    private var engine: AVAudioEngine?
    private lazy var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-CO"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false

    /// `error` seeds the message a preview or test shows. Cheap: nothing is made until dictation starts, so a view may build one on
    /// every redraw (inside `StateObject(wrappedValue:)`'s autoclosure only one is kept).
    init(error: String? = nil) { self.error = error }

    func toggle() {
        if recording { stop(); return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized else { self?.error = "Activa Reconocimiento de voz para Nook en Ajustes del Sistema → Privacidad y seguridad."; return }
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    DispatchQueue.main.async {
                        guard allowed else { self?.error = "Activa el micrófono para Nook en Ajustes del Sistema → Privacidad y seguridad."; return }
                        self?.start()
                    }
                }
            }
        }
    }
    private func start() {
        guard let recognizer, recognizer.isAvailable else { error = "El dictado no está disponible en este momento."; return }
        stop()
        transcript = ""; error = nil
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request
        let engine = self.engine ?? AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { error = "No hay un micrófono disponible."; return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapInstalled = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, failure in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if failure != nil || result?.isFinal == true { self.stop() }
            }
        }
        do { engine.prepare(); try engine.start(); recording = true }
        catch { self.error = error.localizedDescription; stop() }
    }
    func stop() {
        if let engine {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        }
        request?.endAudio(); task?.cancel()
        request = nil; task = nil; recording = false
    }
}
