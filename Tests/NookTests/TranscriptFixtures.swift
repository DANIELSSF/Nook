import Foundation
@testable import Nook

/// Records the way Claude Code writes them, rendered by `TranscriptRenderer`, for the tests of the mirror's look.
enum TranscriptFixtures {
    static let cwd = "/Users/me/app"

    static func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    /// The renderer's text for these record lines.
    static func render(_ lines: [String]) -> String {
        var renderer = TranscriptRenderer()
        lines.forEach { renderer.consume($0) }
        return renderer.text
    }

    static func prompt(_ text: String) -> String {
        json(["type": "user", "cwd": cwd, "message": ["role": "user", "content": text]])
    }

    static func reply(_ text: String) -> String {
        json(["type": "assistant", "cwd": cwd, "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    static func call(_ id: String, _ name: String, _ input: [String: Any]) -> String {
        json(["type": "assistant", "cwd": cwd, "message": ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
    }

    static func result(_ id: String, _ text: String, details: [String: Any]? = nil) -> String {
        var entry: [String: Any] = ["type": "user", "cwd": cwd, "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": text]]]]
        if let details { entry["toolUseResult"] = details }
        return json(entry)
    }

    /// An Edit with two hunks in a Swift file: the first starts at line 96, the second at line 120.
    static func swiftEdit(id: String = "edit-1", path: String = "Sources/Notch.swift") -> [String] {
        let patch: [[String: Any]] = [
            ["oldStart": 96, "oldLines": 7, "newStart": 96, "newLines": 9, "lines": [
                " struct NotchGeometry {",
                "-    static let expandedWidth: CGFloat = 572",
                "+    static let expandedWidth: CGFloat = 600",
                "+    static let maxHeight = 480.5  // never taller than this",
                " ",
                "     static func expandedHeight(topInset: CGFloat) -> CGFloat {",
                "-        ((210 + max(topInset, 28)) * 1.1).rounded()",
                "+        let base = 210 + max(topInset, 28)",
                "+        return (base * 1.1).rounded()",
                "     }",
            ]],
            ["oldStart": 118, "oldLines": 5, "newStart": 120, "newLines": 6, "lines": [
                "     /// The open island's frame, centred on the notch.",
                "-    static func expandedFrame(screen: CGRect) -> CGRect {",
                "+    @MainActor static func expandedFrame(screen: CGRect, settings: DisplaySettings = DisplaySettings()) -> CGRect {",
                "         let size = expandedSize(screen: screen.size)",
                "-        return CGRect(origin: .zero, size: size)",
                "+        guard size.width > 0 else { return .zero }",
                "+        return CGRect(origin: .zero, size: size)  // \"top\" edge",
                "     }",
            ]],
        ]
        return [call(id, "Edit", ["file_path": cwd + "/" + path, "old_string": "x", "new_string": "y"]),
                result(id, "The file \(path) has been updated.", details: ["filePath": cwd + "/" + path, "structuredPatch": patch])]
    }

    /// A Write that creates a 15-line README.
    static func newFile(id: String = "write-1", path: String = "README.md", lines: Int = 15) -> [String] {
        let body = ["# Nook", "", "Una isla para tus terminales de IA.", "", "## Probar", "", "- Abre **Terminal**, Claude Code o Codex.", "- Escribe el mensaje abajo y pulsa `Enter`.",
                    "", "> Todo corre en tu Mac.", "", "## Compilar", "", "    swift build", "    swift test", "", "Licencia MIT."]
        let content = body.prefix(lines).joined(separator: "\n") + "\n"
        return [call(id, "Write", ["file_path": cwd + "/" + path, "content": content]),
                result(id, "File created successfully at: \(cwd)/\(path)", details: ["type": "create", "filePath": cwd + "/" + path, "content": content])]
    }

    /// A reply with a fenced Swift block between two paragraphs.
    static let fencedReply = "Así queda la función:\n\n```swift\nfunc greet(name: String) -> String {\n    // Say hello\n    let text = \"Hola, \\(name)\"\n    return text.uppercased()\n}\n```\n\nY se llama así: `greet(name: \"Sample\")`."
}
