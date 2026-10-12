import AppKit
import Combine

/// A request to exclude one of this process's windows from capture. Success means the
/// WindowServer accepted the request, not that a particular recorder honors it.
protocol CaptureExclusionBackend: AnyObject {
    var isAvailable: Bool { get }
    func setExclusion(on window: NSWindow, region: CGRect?) throws
}

/// Experimental capture privacy for Nook's own windows. All access is on the main thread,
/// like the NSWindows it manages. It does not enumerate or change other apps' windows.
final class CapturePrivacy: ObservableObject {
    static let defaultsKey = "nook.capturePrivacy.enabled"

    @Published var enabled: Bool {
        didSet {
            precondition(Thread.isMainThread)
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.defaultsKey)
            reconcileAll(retry: true)
        }
    }

    /// Failures remain visible until the affected request succeeds or the window closes.
    /// A nil issue is deliberately not a claim that screen capture protection was verified.
    @Published private(set) var issue: String?
    var isAvailable: Bool { backend.isAvailable }

    private let defaults: UserDefaults
    private let backend: CaptureExclusionBackend
    private var windows: [ObjectIdentifier: WindowRecord] = [:]
    private var closedWindows: [ObjectIdentifier: WeakWindow] = [:]
    private var closeObserver: NSObjectProtocol?
    private var applicationObservers: [NSObjectProtocol] = []
    private var reconciling = false

    init(defaults: UserDefaults = .standard,
         backend: CaptureExclusionBackend = SystemCaptureExclusionBackend()) {
        precondition(Thread.isMainThread)
        self.defaults = defaults
        self.backend = backend
        enabled = defaults.bool(forKey: Self.defaultsKey)
        issue = enabled && !backend.isAvailable ? Self.unavailableMessage : nil
        // Observing NSApp is opt-in: constructing a model in a test must not affect
        // unrelated windows owned by that test process.
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        applicationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Call before showing or resizing a Nook window. A proposed size covers the future
    /// frame; the region always starts at (0, 0), in window-local coordinates.
    /// Explicitly preparing a previously closed window also supports reopening it.
    func prepare(_ window: NSWindow, size: CGSize? = nil) {
        precondition(Thread.isMainThread)
        closedWindows.removeValue(forKey: ObjectIdentifier(window))
        register(window, size: size)
    }

    /// Best-effort coverage for AppKit-owned transient windows, such as menus. Discovery
    /// at app update/resize time cannot promise that their first frame was excluded.
    func startObservingApplication() {
        precondition(Thread.isMainThread)
        guard applicationObservers.isEmpty else { return }
        installCloseObserver()
        let center = NotificationCenter.default
        applicationObservers.append(center.addObserver(
            forName: NSApplication.willUpdateNotification, object: NSApp, queue: .main
        ) { [weak self] _ in self?.discoverApplicationWindows() })
        applicationObservers.append(center.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow,
                  self.closedWindows[ObjectIdentifier(window)] == nil else { return }
            self.register(window, size: nil)
        })
        discoverApplicationWindows()
    }

    func stopObservingApplication() {
        precondition(Thread.isMainThread)
        applicationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        applicationObservers.removeAll()
    }

    private func discoverApplicationWindows() {
        guard !reconciling else { return }
        prune()
        for window in NSApp.windows where closedWindows[ObjectIdentifier(window)] == nil {
            register(window, size: nil)
        }
    }

    private func register(_ window: NSWindow, size: CGSize?) {
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }
        installCloseObserver()
        prune()
        let id = ObjectIdentifier(window)
        let record = windows[id] ?? WindowRecord(window)
        record.isClosed = false
        windows[id] = record
        reconcile(record, size: size ?? window.frame.size)
        updateIssue()
    }

    private func reconcileAll(retry: Bool) {
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }
        prune()
        for record in windows.values {
            guard let window = record.window else { continue }
            if retry { record.lastAttempt = nil }
            reconcile(record, size: window.frame.size, excluding: enabled && !record.isClosed)
        }
        updateIssue()
    }

    private func reconcile(_ record: WindowRecord, size: CGSize, excluding: Bool? = nil) {
        let exclude = excluding ?? enabled
        guard let window = record.window, window.windowNumber > 0 else { return }
        // Disabled by default means no native mutation, including no unnecessary clear.
        guard exclude || record.mayNeedClearing else {
            record.failure = nil
            return
        }
        guard backend.isAvailable else {
            record.failure = exclude ? Self.unavailableMessage
                : "No se pudo retirar la exclusión de captura porque la función ya no está disponible. Reinicia Nook para restablecer sus ventanas."
            return
        }
        let region: CGRect?
        if exclude {
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
            region = CGRect(origin: .zero, size: size)
        } else {
            region = nil
        }
        let attempt = Attempt(windowNumber: window.windowNumber, region: region)
        guard attempt != record.lastAttempt else { return }
        record.lastAttempt = attempt
        // Even an unsuccessful native call may have changed state. Always try to remove
        // that request on disable, and retain a removal failure instead of claiming success.
        if exclude { record.mayNeedClearing = true }
        do {
            try backend.setExclusion(on: window, region: region)
            record.failure = nil
            if !exclude { record.mayNeedClearing = false }
        } catch {
            let operation = exclude ? "aplicar" : "retirar"
            record.failure = "No se pudo \(operation) la exclusión de captura: \(error.localizedDescription)"
        }
    }

    private func installCloseObserver() {
        guard closeObserver == nil else { return }
        // A single object:nil observer avoids retaining windows through observer filters.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow else { return }
            let id = ObjectIdentifier(window)
            guard let record = self.windows[id] else { return }
            // willClose precedes AppKit's close animation. Remove the window from the
            // display before clearing, so cleanup cannot reveal its final visible frame.
            if self.enabled && record.mayNeedClearing && window.isVisible { window.orderOut(nil) }
            // An NSWindow retained by its controller can reuse its surface after close.
            // Clear now, so reopening after the preference was disabled cannot keep a
            // stale exclusion. Retain a failed clear for a later retry or explicit reopen.
            record.isClosed = true
            record.lastAttempt = nil
            self.reconcile(record, size: window.frame.size, excluding: false)
            if !record.mayNeedClearing { self.windows.removeValue(forKey: id) }
            self.closedWindows[id] = WeakWindow(window)
            self.updateIssue()
        }
    }

    private func prune() {
        windows = windows.filter { $0.value.window != nil }
        closedWindows = closedWindows.filter { $0.value.window != nil }
    }

    private func updateIssue() {
        let next = windows.values.compactMap(\.failure).first
            ?? (enabled && !backend.isAvailable ? Self.unavailableMessage : nil)
        if issue != next { issue = next }
    }

    private static let unavailableMessage = "La exclusión de captura no está disponible en este macOS. Nook puede aparecer al compartir pantalla."

    private class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    private final class WindowRecord: WeakWindow {
        var isClosed = false
        var lastAttempt: Attempt?
        var mayNeedClearing = false
        var failure: String?
    }

    private struct Attempt: Equatable {
        let windowNumber: Int
        let region: CGRect?
    }
}

/// Public AppKit sharing type. `.none` asks WindowServer to leave the window out of
/// captures entirely, so a share shows whatever lies beneath it, as if Nook were closed.
/// It replaces the private CGSSetWindowCaptureExcludeShape, which redacts instead of
/// omitting: on macOS 27 the excluded shape is painted solid gray (128, 128, 128) in
/// screenshots and shares, and Nook's mostly transparent notch window became a large
/// gray block in Google Meet. The region only says whether to exclude; the whole
/// window is always covered.
final class SystemCaptureExclusionBackend: CaptureExclusionBackend {
    var isAvailable: Bool { true }

    func setExclusion(on window: NSWindow, region: CGRect?) throws {
        precondition(Thread.isMainThread)
        guard window.windowNumber > 0 else { throw Failure.unallocatedWindow }
        window.sharingType = region == nil ? .readOnly : .none
    }

    enum Failure: LocalizedError {
        case unallocatedWindow

        var errorDescription: String? {
            switch self {
            case .unallocatedWindow: return "La ventana aún no tiene una superficie asignada."
            }
        }
    }
}
