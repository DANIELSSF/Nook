import Foundation
import os

/// What Nook did about its memory, readable with `log show --predicate 'subsystem == "dev.nook.mac" && category == "memory"'`.
let memoryLog = Logger(subsystem: "dev.nook.mac", category: "memory")

enum MemoryFootprint {
    /// A process's physical footprint in bytes, the number Activity Monitor shows as its memory; nil when it can't be read
    /// (the process is gone). One system call, a few microseconds.
    static func of(_ pid: pid_t = getpid()) -> Int64? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? Int64(usage.ri_phys_footprint) : nil
    }

    static func megabytes(_ bytes: Int64) -> Int { Int(bytes >> 20) }

    /// Hands memory that was freed back to the system, so the footprint drops now and not whenever the allocator gets to it.
    static func relieve() { malloc_zone_pressure_relief(nil, 0) }
}

/// Nook's own footprint, checked every few minutes (one system call) and whenever macOS says memory is short. Past `limits.trim`,
/// or under pressure, `onTrim` lets go of what can be rebuilt (see `AppModel.trimMemory`); past `limits.alarm` something leaks,
/// and `onAlarm` says so once. Normal use stays far below both, so a future leak shows up in the log long before it costs
/// gigabytes, instead of growing silently for a day.
final class MemoryWatch {
    struct Limits: Equatable {
        /// Six Claude tabs with their records and agents settle near 60 MB, open or collapsed, and peak near 110 MB while their records
        /// are first read (`MemoryProbeTests`); this is several times that.
        var trim: Int64 = 300 << 20
        /// Nothing Nook does needs this much: something leaks.
        var alarm: Int64 = 800 << 20
    }

    enum Reason: Equatable {
        case footprint(Int64)
        case pressure
    }

    let limits: Limits
    let interval: TimeInterval
    /// Replaceable in tests.
    var footprint: () -> Int64? = { MemoryFootprint.of() }
    var onTrim: (Reason) -> Void = { _ in }
    var onAlarm: (Int64) -> Void = { _ in }
    private var timer: DispatchSourceTimer?
    private var pressure: DispatchSourceMemoryPressure?
    /// The footprint the last trim left; the next one waits until it grew again by a good margin, so a footprint that stays
    /// high (a leak trimming can't reach) is not trimmed and logged every few minutes.
    private var trimmedAt: Int64?
    private var alarmed = false

    init(limits: Limits = Limits(), interval: TimeInterval = 300) {
        self.limits = limits
        self.interval = interval
    }

    deinit { stop() }

    /// Checks on the main queue every `interval`, with a generous leeway so the system can batch the wake-up with others.
    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(Int(max(1, interval / 5))))
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            guard let self else { return }
            memoryLog.notice("memory pressure from macOS; trimming")
            self.onTrim(.pressure)
        }
        pressure.resume()
        self.pressure = pressure
    }

    func stop() {
        timer?.cancel(); timer = nil
        pressure?.cancel(); pressure = nil
    }

    /// One look at the footprint: trims past `limits.trim` (once per growth), and raises the alarm once past `limits.alarm`.
    @discardableResult func check() -> Reason? {
        guard let bytes = footprint() else { return nil }
        if bytes > limits.alarm, !alarmed {
            alarmed = true
            memoryLog.fault("footprint \(MemoryFootprint.megabytes(bytes), privacy: .public) MB passed the alarm limit")
            onAlarm(bytes)
        }
        guard bytes > limits.trim else { trimmedAt = nil; return nil }
        if let last = trimmedAt, bytes < last + last / 4 { return nil }
        memoryLog.error("footprint \(MemoryFootprint.megabytes(bytes), privacy: .public) MB passed \(MemoryFootprint.megabytes(self.limits.trim), privacy: .public) MB; trimming")
        onTrim(.footprint(bytes))
        let after = footprint() ?? bytes
        trimmedAt = after
        memoryLog.notice("footprint after trimming: \(MemoryFootprint.megabytes(after), privacy: .public) MB")
        return .footprint(bytes)
    }
}
