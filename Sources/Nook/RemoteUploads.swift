import Foundation
import ImageIO

// Images the phone attaches to a message (`POST /api/upload`, docs/REMOTE_API.md), as the island's composer attaches an image pasted
// with ⌘V: a file in Nook's private images folder whose path goes with the message, and Claude opens it when the message arrives.
//
// The bytes are checked to be the image they say they are (their first bytes and ImageIO decoding them) before anything is written,
// and the file gets a name Nook chooses ("imagen-movil-20261105-093012-k3f9a2.jpg"), the user's alone (0600), never written through
// a link; the folder's own pruning takes it after a day, as it does the island's pasted images. Until it is sent it belongs to the
// device that sent it (`RemoteUploads`): only that device can attach it, at most `maxPending` wait at once, and one not sent within
// `keep` is no longer offered. Once sent it is remembered like a screenshot that went with a message (`AppModel.sentShots`).

/// A kind of image the phone may send.
enum RemoteImageKind: String, CaseIterable {
    case jpeg, png, gif, webp

    /// From a Content-Type ("image/jpeg; charset=…" too); nil for anything else.
    init?(contentType: String?) {
        guard let type = contentType?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) else { return nil }
        switch type {
        case "image/jpeg": self = .jpeg
        case "image/png": self = .png
        case "image/gif": self = .gif
        case "image/webp": self = .webp
        default: return nil
        }
    }

    /// From a file name's extension.
    init?(fileName: String) {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": self = .jpeg
        case "png": self = .png
        case "gif": self = .gif
        case "webp": self = .webp
        default: return nil
        }
    }

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var contentType: String { "image/" + rawValue }

    /// Whether `data` starts the way a file of this kind does (its signature): a declared type never stands in for the bytes.
    func matches(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + signature.count && Array(bytes[offset..<(offset + signature.count)]) == signature
        }
        switch self {
        case .jpeg: return starts([0xFF, 0xD8, 0xFF])
        case .png: return starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case .gif: return starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8))
        case .webp: return starts(Array("RIFF".utf8)) && starts(Array("WEBP".utf8), at: 8)
        }
    }
}

/// An image the phone sent, as Nook keeps it.
struct RemoteUpload: Equatable {
    /// The file's name: its id for the page, never anything the page chose.
    var name: String
    var path: String
    var device: String
    var issued: Date
    var width: Int
    var height: Int
}

enum RemoteImages {
    /// The largest image the phone may send.
    static let maxBytes = 12 * 1024 * 1024
    /// How long the whole request may take (a phone on a slow Wi-Fi).
    static let uploadTimeout: TimeInterval = 60
    /// Pixels at most, and on a side: ImageIO is not asked to open a picture made to fill the memory.
    static let maxPixels = 120_000_000, maxSide = 20_000
    static let prefix = "imagen-movil-"

    /// What `data` is when it is a picture ImageIO decodes, of a sensible size: its width and height. Nil otherwise.
    static func inspect(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= maxSide, height <= maxSide, width * height <= maxPixels else { return nil }
        // A small picture of it, made from the file: what is broken past its header shows up here.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64, kCGImageSourceShouldCache: false]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil else { return nil }
        return (width, height)
    }

    /// "imagen-movil-20261105-093012-k3f9a2": a fixed format whatever the locale, and six random letters and digits so two images in
    /// the same second never meet.
    static func name(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let random = String((0..<6).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
        return prefix + formatter.string(from: date) + "-" + random
    }

    /// Writes `data` as a new file in `folder` (private, 0600, never over an existing file nor through a link) and hands back its URL.
    static func save(_ data: Data, kind: RemoteImageKind, in folder: URL, at date: Date = Date()) throws -> URL {
        try ScreenShotFile.prepare(folder)
        return try ScreenShotFile.write(data, named: name(at: date), ext: kind.fileExtension, in: folder)
    }
}

/// The images each device sent and has not attached to a message yet, from any thread.
final class RemoteUploads: @unchecked Sendable {
    /// Images waiting at once, per device.
    static let maxPending = 20
    /// How long one waits to be sent before it is no longer offered.
    static let keep: TimeInterval = 60 * 60
    /// Images one message may carry.
    static let maxPerMessage = 5

    private let lock = NSLock()
    private var pending: [String: RemoteUpload] = [:]
    /// The ones a message is carrying right now: neither offered again nor lost until it is known how it went.
    private var reserved: Set<String> = []

    private func expire(now: Date) {
        pending = pending.filter { now.timeIntervalSince($0.value.issued) < Self.keep }
    }

    func count(for device: String, now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        return pending.values.filter { $0.device == device }.count
    }

    /// Keeps `upload` for its device; false, with nothing kept, when the device has `maxPending` waiting.
    func issue(_ upload: RemoteUpload, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        guard pending.values.filter({ $0.device == upload.device }).count < Self.maxPending else { return false }
        pending[upload.name] = upload
        return true
    }

    /// The images `names` names, when every one is this device's, waiting, and not on its way in another message; they are then on
    /// their way (`finish`). Nil, with nothing reserved, otherwise.
    func reserve(_ names: [String], for device: String, now: Date = Date()) -> [RemoteUpload]? {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        guard Set(names).count == names.count else { return nil }
        let found = names.compactMap { name in pending[name].flatMap { $0.device == device && !reserved.contains(name) ? $0 : nil } }
        guard found.count == names.count else { return nil }
        reserved.formUnion(names)
        return found
    }

    /// The message carrying `names` went (they are forgotten here: the sent ones are remembered by the model) or didn't (they wait
    /// again, for another try).
    func finish(_ names: [String], sent: Bool) {
        lock.lock(); defer { lock.unlock() }
        reserved.subtract(names)
        if sent { names.forEach { pending[$0] = nil } }
    }

    /// The image `name`, waiting for `device` (its own preview): nil for any other.
    func waiting(_ name: String, for device: String, now: Date = Date()) -> RemoteUpload? {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        return pending[name].flatMap { $0.device == device ? $0 : nil }
    }

    /// Every path waiting (the folder's pruning keeps them).
    var paths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(pending.values.map(\.path))
    }

    /// The device was removed or Nook Remote went off: nothing it sent is offered any more.
    func forget(device: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let device { pending = pending.filter { $0.value.device != device } } else { pending = [:]; reserved = [] }
    }
}

/// How many uploads each device made lately, and how many are being read at once, from any thread.
final class RemoteUploadGauge: @unchecked Sendable {
    /// Uploads per device in `window`.
    static let perWindow = 30
    static let window: TimeInterval = 10 * 60
    /// Large bodies being read at once, server-wide: 12 MB each.
    static let inFlight = 2

    private let lock = NSLock()
    private var recent: [String: [Date]] = [:]
    private var reading = 0

    /// Whether `device` may upload one more now; `count` counts it.
    func allows(_ device: String, count: Bool, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var times = (recent[device] ?? []).filter { now.timeIntervalSince($0) < Self.window }
        guard times.count < Self.perWindow else { recent[device] = times; return false }
        if count { times.append(now) }
        recent[device] = times
        return true
    }

    /// One more large body may be read now (it is counted until `release`).
    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard reading < Self.inFlight else { return false }
        reading += 1
        return true
    }

    func release() {
        lock.lock(); reading = max(0, reading - 1); lock.unlock()
    }

    func reset() {
        lock.lock(); recent = [:]; lock.unlock()
    }
}
