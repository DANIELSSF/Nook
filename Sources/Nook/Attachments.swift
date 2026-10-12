import AppKit
import ImageIO
import SwiftUI

// The images attached to the message being written.
//
// An image pasted into a Terminal tab is saved as a file and travels in the message as its path, which the agent opens when the
// message arrives. The composer shows it as a thumbnail instead of the path: the path is not part of what the user writes, so it
// stays out of the field and joins the message when it is sent (`SessionPane.send`).

/// What is attached to each tab's message until it is sent. A pane is rebuilt when the user comes back to a tab, and an attachment
/// that vanished with it would leave a file nobody can reach; so what each tab holds is kept here, by the tab's id.
@MainActor
final class MessageAttachments {
    static let shared = MessageAttachments()

    private var byTab: [String: [String]] = [:]

    func paths(for tab: String) -> [String] { byTab[tab] ?? [] }

    /// Every image attached to some tab's message right now.
    var attachedPaths: Set<String> { Set(byTab.values.joined()) }

    /// The name every clipboard image Nook saves starts with (`AppModel.saveImage`).
    nonisolated static let clipboardPrefix = "imagen-"

    /// Removes the clipboard images in `folder` older than `keep`, a day like screen vision's pictures (`ScreenShotFile.prune`, which
    /// leaves these to this). One in `keeping` stays however old: it is still attached to a message, which would otherwise carry a
    /// path to nothing. Nothing else in the folder is touched.
    nonisolated static func prune(_ folder: URL, now: Date, keep: TimeInterval = ScreenShotFile.keep, keeping: Set<String>) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
        let kept = Set(keeping.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        for name in names where name.hasPrefix(clipboardPrefix) {
            let url = folder.appendingPathComponent(name)
            guard !kept.contains(url.resolvingSymlinksInPath().path),
                  let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, now.timeIntervalSince(modified) > keep else { continue }
            try? manager.removeItem(at: url)
        }
    }

    /// Where Nook keeps the images it attaches (a clipboard image, `AppModel.saveImage`; a picture of the screen, `ScreenVision.folder`).
    nonisolated static var folder: String { "/tmp/nook-\(getuid())/images/" }

    /// The message ends with images Nook attached (in `folder`). Claude must get it pasted to attach them (`ClaudeImagePaste`), however
    /// short it is: typed, the paths would stay words. A path the user typed or dropped stays text, as it always did.
    nonisolated static func endsWithAttachments(_ message: String) -> Bool {
        guard message.contains(folder) else { return false }
        return parts(of: message).files.contains { $0.hasPrefix(folder) }
    }

    /// The message that goes out: the words, then the attached images' paths (the agent opens a file it is given by path), apart by a space.
    /// Claude gets it pasted, which attaches the images and shows "[Image #N]" in their place (`ClaudeImagePaste`).
    nonisolated static func message(text: String, files: [String]) -> String {
        ([text] + files).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A message as `message(text:files:)` put it together, apart again: the words, and the images' paths after them (absolute
    /// paths to image files, each after a space). For a message on its way or from the history, shown with its pictures again
    /// instead of their paths. A message without images comes back whole as its words.
    nonisolated static func parts(of message: String) -> (text: String, files: [String]) {
        var rest = message, files: [String] = []
        while !rest.isEmpty {
            let cut = rest.range(of: " /", options: .backwards)
            let piece = cut.map { String(rest[rest.index(after: $0.lowerBound)...]) } ?? rest
            guard piece.hasPrefix("/"), !piece.contains(where: \.isWhitespace), ClaudeImagePaste.imagePath(piece) == piece else { break }
            files.insert(piece, at: 0)
            rest = cut.map { String(rest[..<$0.lowerBound]) } ?? ""
        }
        return (rest, files)
    }

    func set(_ paths: [String], for tab: String) {
        if paths.isEmpty { byTab.removeValue(forKey: tab) } else { byTab[tab] = paths }
    }
}

/// A small picture of an attached file, drawn from the file itself at the size it is shown. A large screenshot is read once, as the
/// few kilobytes of its thumbnail, and kept.
@MainActor
enum AttachmentThumbnail {
    private static var cache: [String: NSImage] = [:]

    /// `points` wide and high, sharp on a 2× screen; nil when the file is gone or is not an image.
    static func image(at path: String, points: CGFloat) -> NSImage? {
        let key = "\(Int(points))|" + path
        if let known = cache[key] { return known }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: Int(points * 2)]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width / 2, height: thumbnail.height / 2))
        if cache.count > 40 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// One attached image: its thumbnail, and a small button that takes it off the message.
struct AttachmentChip: View {
    var path: String
    var onRemove: () -> Void

    static let side: CGFloat = 44

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Group {
            if let image = AttachmentThumbnail.image(at: path, points: Self.side) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                // The file is gone (the system clears /tmp now and then): the message would still carry a path to nothing.
                Image(systemName: "photo").font(.system(size: 15)).foregroundStyle(Color.nookSecondary)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .background(Color.nookWash(0.07))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.nookWash(0.18), lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(Color.white)
                    .frame(width: 16, height: 16)
                    .background(Color.black.opacity(0.78), in: Circle())
                    .overlay(Circle().stroke(Color.nookWash(0.3), lineWidth: 0.5))
                    .frame(width: 24, height: 24).contentShape(Circle())
            }.nookPress(.spin).offset(x: 8, y: -8)
                .help("Quitar la imagen del mensaje").accessibilityLabel("Quitar la imagen")
        }
        .help((path as NSString).lastPathComponent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Imagen adjunta")
    }
}

/// The attached images, side by side above the message field.
struct AttachmentRow: View {
    var paths: [String]
    var onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(paths, id: \.self) { path in
                    AttachmentChip(path: path) { onRemove(path) }
                }
            }
            // Room for the remove buttons, which stand half outside the thumbnails.
            .padding(.top, 8).padding(.trailing, 8).padding(.bottom, 2)
        }.frame(height: AttachmentChip.side + 10)
    }
}
