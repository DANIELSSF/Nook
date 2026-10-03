import AppKit
import Darwin

struct ClaudeSignal: Codable {
    let event: String
    let tty: String
    let sessionID: String
    let message: String
    let notificationType: String
    let tmuxSocket: String?
    let tmuxPane: String?

    static func fromHook(_ data: Data, tty: String, environment: [String: String]) -> ClaudeSignal? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["hook_event_name"] as? String,
              ["UserPromptSubmit", "Stop", "Notification", "StopFailure", "SessionEnd"].contains(event) else { return nil }
        return ClaudeSignal(event: event, tty: tty, sessionID: String((json["session_id"] as? String ?? "").prefix(100)), message: event == "Notification" ? String((json["message"] as? String ?? "Claude solicita tu atención.").prefix(180)) : "", notificationType: json["notification_type"] as? String ?? "", tmuxSocket: environment["TMUX"]?.split(separator: ",").first.map(String.init), tmuxPane: environment["TMUX_PANE"])
    }
}

enum LocalSignalSocket {
    static var path: String { "/tmp/nook-\(getuid())/events.sock" }
    static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in path.utf8.prefix(raw.count - 1).enumerated() { raw[index] = byte }
        }
        return address
    }
    static func send(_ signal: ClaudeSignal, path: String = path) {
        guard let data = try? JSONEncoder().encode(signal) else { return }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var address = address(path)
        data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, bytes.baseAddress, bytes.count, MSG_DONTWAIT, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
    }
}

final class ClaudeSignalReceiver {
    var onEvent: ((ClaudeSignal) -> Void)?
    private var source: DispatchSourceRead?
    private var socketPath: String
    init(path: String = LocalSignalSocket.path, deliveryQueue: DispatchQueue = .main) {
        socketPath = path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Remove only a previous socket owned by this user in the private directory.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path), attrs[.type] as? FileAttributeType == .typeSocket, (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() { unlink(path) }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        var address = LocalSignalSocket.address(path)
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard status == 0 else { Darwin.close(fd); return }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "dev.nook.claude-signals"))
        reader.setEventHandler { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(fd, &bytes, bytes.count, MSG_DONTWAIT)
                if count <= 0 { break }
                guard let event = try? JSONDecoder().decode(ClaudeSignal.self, from: Data(bytes.prefix(count))) else { continue }
                deliveryQueue.async { [weak self] in self?.onEvent?(event) }
            }
        }
        reader.setCancelHandler { Darwin.close(fd) }
        source = reader; reader.resume()
    }
    deinit { source?.cancel(); if source != nil { unlink(socketPath) } }
}

enum ClaudeHooks {
    static var helperURL: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Nook/nook-hook") }
    static var command: String { Shell.quote(helperURL.path) + " --claude-hook" }
    static let events = ["UserPromptSubmit", "Stop", "Notification", "StopFailure", "SessionEnd"]

    /// Claude's configuration folders, each with its own settings: `~/.claude` and variants such as
    /// `~/.claude-work` (one per `CLAUDE_CONFIG_DIR`). A session only runs the hooks of its own folder.
    static func folders(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let found = names.filter { $0 == ".claude" || $0.hasPrefix(".claude-") }.sorted().map { home.appendingPathComponent($0) }
            .filter { folder in ["settings.json", "projects"].contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) } }
        return found.isEmpty ? [home.appendingPathComponent(".claude")] : found
    }

    static func settingsURL(in folder: URL) -> URL { folder.appendingPathComponent("settings.json") }

    /// How the folders read in a message: "~/.claude/settings.json y ~/.claude-work/settings.json".
    static func describe(_ folders: [URL]) -> String {
        let paths = folders.map { "~/" + $0.lastPathComponent + "/settings.json" }
        return paths.count < 2 ? paths.joined() : paths.dropLast().joined(separator: ", ") + " y " + paths[paths.count - 1]
    }

    static func merging(_ settings: [String: Any], command: String, enabled: Bool) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            let entries = hooks[event] as? [[String: Any]] ?? []
            var updated: [[String: Any]] = []
            for var entry in entries {
                guard let actions = entry["hooks"] as? [[String: Any]] else { updated.append(entry); continue }
                let remaining = actions.filter { ($0["command"] as? String) != command }
                if !remaining.isEmpty { entry["hooks"] = remaining; updated.append(entry) }
            }
            if enabled {
                let matcher = event == "Notification" ? "permission_prompt|worker_permission_prompt|agent_needs_input|elicitation_dialog" : ""
                updated.append(["matcher": matcher, "hooks": [["type": "command", "command": command, "async": true, "timeout": 3]]])
            }
            if updated.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = updated }
        }
        settings["hooks"] = hooks
        return settings
    }

    static func isEnabled(in folder: URL, command: String = command) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL(in: folder)), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let hooks = json["hooks"] as? [String: Any] else { return false }
        return events.contains { event in (hooks[event] as? [[String: Any]] ?? []).contains { entry in (entry["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command } } }
    }

    /// On only when every folder has Nook's hooks: a session in a folder without them would never signal.
    static var enabled: Bool { folders().allSatisfy { isEnabled(in: $0) } }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled { try installHelper() }
        try write(enabled: enabled, to: folders())
    }

    /// Nook's hooks in or out of each folder's settings, keeping everything else and a backup of each
    /// file it changes. A folder whose settings can't be read is left as it was, and nothing is written.
    static func write(enabled: Bool, to folders: [URL], command: String = command) throws {
        let manager = FileManager.default
        var updates: [(URL, [String: Any], Data?)] = []
        for folder in folders {
            let url = settingsURL(in: folder)
            guard manager.fileExists(atPath: url.path) else { updates.append((url, [:], nil)); continue }
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TerminalBridgeError.failed("No se pudo leer \(describe([folder])). No se modificó nada.")
            }
            updates.append((url, json, data))
        }
        for (url, settings, original) in updates {
            if let original {
                let backup = url.deletingLastPathComponent().appendingPathComponent("settings.nook-backup-\(UUID().uuidString.prefix(8)).json")
                try original.write(to: backup, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
            let updated = merging(settings, command: command, enabled: enabled)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// The hook runs a private copy of Nook's executable, so moving or rebuilding the app never breaks it.
    static func installHelper() throws {
        let manager = FileManager.default
        guard let executable = Bundle.main.executableURL else { throw TerminalBridgeError.failed("No se encontró el componente de avisos de Nook.") }
        try manager.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = helperURL.deletingLastPathComponent().appendingPathComponent("nook-hook-" + UUID().uuidString)
        try manager.copyItem(at: executable, to: staging)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        if manager.fileExists(atPath: helperURL.path) { _ = try manager.replaceItemAt(helperURL, withItemAt: staging) }
        else { try manager.moveItem(at: staging, to: helperURL) }
    }

    static func forwardFromCLI() {
        guard let data = try? FileHandle.standardInput.readToEnd() else { return }
        let rawTTY = (try? Shell.run("/bin/ps", ["-o", "tty=", "-p", String(getpid())]).1.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let tty = rawTTY == "??" || rawTTY.isEmpty ? "" : rawTTY.hasPrefix("/dev/") ? rawTTY : "/dev/" + rawTTY
        if let signal = ClaudeSignal.fromHook(data, tty: tty, environment: ProcessInfo.processInfo.environment) { LocalSignalSocket.send(signal) }
        // No stdout, decisions, prompts, transcripts, network traffic or persisted events.
    }
}
