import Foundation

/// Files, folders or images dropped on Nook become their exact paths in the message, the way
/// Terminal writes a dropped file's path. Nothing is sent: the user keeps writing around them.
enum DroppedPaths {
    /// Characters a shell takes literally; any other one gets the path quoted.
    private static let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%,:=")

    /// The paths as they go in the message. An agent reads them as text, so only a path with spaces
    /// or quotes is wrapped in double quotes; a shell gets them quoted so a command can use them as is.
    static func text(for urls: [URL], shell: Bool) -> String {
        urls.filter(\.isFileURL).map { url in
            let path = url.path
            if shell { return path.unicodeScalars.allSatisfy(plain.contains) ? path : Shell.quote(path) }
            guard path.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) else { return path }
            return "\"" + path.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: " ")
    }

    /// The draft with `inserted` at `location` (UTF-16 offset; the end when nil), with a space on each
    /// side where the neighbouring text needs one, and where the cursor goes next.
    static func insert(_ inserted: String, into draft: String, at location: Int? = nil) -> (text: String, cursor: Int) {
        guard !inserted.isEmpty else { return (draft, location ?? (draft as NSString).length) }
        let text = draft as NSString
        let at = min(max(location ?? text.length, 0), text.length)
        let before = text.substring(to: at), after = text.substring(from: at)
        let lead = before.isEmpty || before.last?.isWhitespace == true ? "" : " "
        let trail = after.first?.isWhitespace == true ? "" : " "
        let piece = lead + inserted + trail
        return (before + piece + after, at + (piece as NSString).length)
    }
}
