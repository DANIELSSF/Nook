import Foundation

/// Claude Code's list of models as it caches it on disk, in a home of a test's own (`<home>/.claude-work/cache/model-catalog/account-cc.json`): Sample's
/// twelve (Claude Code 2.1.290, his picker of 2026-10-06; the models behind "Default" are eleven), so nothing of the real Mac's reaches a test or a picture.
enum ModelCatalogFixture {
    /// `selected` is the choice Claude Code has saved; `stale` makes the list past the time Claude would fetch it again; without a list the home is empty.
    static func home(selected: String = "claude-opus-5-5", stale: Bool = false, withList: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-catalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard withList else { return url }
        let folder = url.appendingPathComponent(".claude-work/cache/model-catalog")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let models: [[String: Any]] = [
            ["id": "claude-opus-5-5", "name": "Opus 5.5", "description": "For complex work and everyday tasks"],
            ["id": "claude-fable-5-1", "name": "Fable 5.1", "description": "For your toughest challenges"],
            ["id": "claude-sonnet-5-5", "name": "Sonnet 5.5", "description": "Most efficient for simpler tasks"],
            ["id": "claude-haiku-4-5-20251001", "name": "Haiku 4.5", "description": "Fastest for quick answers"],
            ["id": "claude-sonnet-5", "name": "Sonnet 5"], ["id": "claude-opus-5", "name": "Opus 5"], ["id": "claude-fable-5", "name": "Fable 5"], ["id": "claude-opus-4-8", "name": "Opus 4.8"],
            ["id": "claude-opus-4-7", "name": "Opus 4.7"], ["id": "claude-opus-4-6", "name": "Opus 4.6"], ["id": "claude-sonnet-4-6", "name": "Sonnet 4.6"],
        ]
        let file: [String: Any] = ["version": 2, "fetchedAt": 1_791_316_587_773.0, "staleAt": stale ? 1_791_316_587_774.0 : 4_102_444_800_000.0,
                                   "catalog": ["surface": "cc", "config": ["id": "x", "models": models], "state": ["id": "x", "model": selected]]]
        try JSONSerialization.data(withJSONObject: file).write(to: folder.appendingPathComponent("account-cc.json"))
        return url
    }
}
