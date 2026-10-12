import Foundation

// Screen vision's tool in Claude Code's configuration. Claude Code learns about an MCP server from its own command
// (`claude mcp add`), which writes it into the account's `.claude.json`; Nook only ever runs that command and never edits the file.
// Each configuration folder is its own account: `~/.claude` is Claude's default, and any other (`~/.claude-work`) is the one a
// session started with `CLAUDE_CONFIG_DIR` pointing at it uses. The tool goes into every one, at user scope (every project).

/// What registering did: the folders that have the tool now, and those it was just added to (their open sessions need a restart).
struct ScreenVisionRegistrationResult: Equatable {
    var folders: [String]
    var added: [String] = []
}

/// Puts the tool in Claude Code, and takes it out. The real one runs `claude mcp`; tests pass a fake.
protocol ScreenVisionRegistering {
    func register() throws -> ScreenVisionRegistrationResult
    /// The folders it was taken out of.
    func unregister() throws -> ScreenVisionRegistrationResult
}

/// A command's exit status and what it printed (output and errors together).
struct CommandResult: Equatable {
    var status: Int32
    var output: String
}

/// Runs a program with exactly these arguments (no shell in between) and environment. Tests record instead.
protocol CommandRunning {
    func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> CommandResult
}

struct ProcessRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        // Nothing to answer: a command that asks something gets end of input instead of waiting forever.
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let expired = OnceFlag()
        let deadline = DispatchWorkItem { if process.isRunning, expired.claim() { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        if !expired.claim() { throw ScreenVisionRegistrationError.timedOut((executable as NSString).lastPathComponent) }
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

enum ScreenVisionRegistrationError: LocalizedError, Equatable {
    case claudeNotFound(manual: String)
    case failed(folder: String, action: String, output: String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .claudeNotFound(let manual):
            "No se encontró Claude Code (el comando claude). Instálalo, o añade la herramienta a mano con: \(manual)"
        case .failed(let folder, let action, let output):
            "No se pudo \(action) la herramienta en \(folder)" + (output.isEmpty ? "." : ": \(output)")
        case .timedOut(let command): "\(command) no respondió a tiempo."
        }
    }
}

/// Where the `claude` command is, and the PATH it runs with (an npm install needs `node` on it).
struct ClaudeCLI: Equatable {
    var executable: String
    var path: String

    /// The login shell's answer first (where the user's own PATH finds it), then the places installers put it.
    static func locate(runner: CommandRunning = ProcessRunner(), environment: [String: String] = ProcessInfo.processInfo.environment,
                       home: String = NSHomeDirectory(), isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                       shells: Set<String> = systemShells()) -> ClaudeCLI? {
        let fallbackPath = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        let shell = loginShell(environment["SHELL"], isExecutable: isExecutable, listed: shells)
        // A fixed script: no path or name of the user's is ever put into it.
        let answer = (try? runner.run(shell, ["-lc", "command -v claude; printf 'PATH=%s\\n' \"$PATH\""], environment: environment, timeout: 15))
            .map { parse(loginOutput: $0.output) }
        let path = answer?.path ?? fallbackPath
        if let found = answer?.executable, isExecutable(found) { return ClaudeCLI(executable: found, path: path) }
        for candidate in [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] where isExecutable(candidate) {
            return ClaudeCLI(executable: candidate, path: path)
        }
        return nil
    }

    /// The user's shell when it speaks `command -v` and `printf` as sh does and the system lists it as a login shell
    /// (`/etc/shells`); zsh otherwise, so a stray SHELL pointing anywhere else never picks what runs.
    static func loginShell(_ shell: String?, isExecutable: (String) -> Bool, listed: Set<String> = systemShells()) -> String {
        guard let shell, ["zsh", "bash", "sh"].contains((shell as NSString).lastPathComponent), listed.contains(shell), isExecutable(shell) else { return "/bin/zsh" }
        return shell
    }

    /// The absolute paths `/etc/shells` lists, comments left out.
    static func systemShells(_ file: String = "/etc/shells") -> Set<String> {
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        return Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") })
    }

    /// The login shell's output: a line with claude's absolute path, and "PATH=…". Anything a profile printed around them is ignored.
    static func parse(loginOutput: String) -> (executable: String?, path: String?) {
        let lines = loginOutput.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let executable = lines.first { $0.hasPrefix("/") && ($0 as NSString).lastPathComponent == "claude" }
        let path = lines.last { $0.hasPrefix("PATH=") }.map { String($0.dropFirst(5)) }.flatMap { $0.isEmpty ? nil : $0 }
        return (executable, path)
    }
}

/// Registers `nook-screen` with `claude mcp`, folder by folder, as `<helper> --mcp-screen`: the stable copy of Nook's executable that
/// Claude's hooks also run, so rebuilding or moving Nook never breaks the tool.
struct ClaudeMCPRegistrar: ScreenVisionRegistering {
    static let serverName = "nook-screen"
    static let flag = "--mcp-screen"
    /// `claude mcp get` also checks that the server answers, which takes a moment.
    static let timeout: TimeInterval = 60

    var helper = ClaudeHooks.helperURL.path
    var home = URL(fileURLWithPath: NSHomeDirectory())
    var folders: () -> [URL] = { ClaudeHooks.folders() }
    var runner: CommandRunning = ProcessRunner()
    var locate: () -> ClaudeCLI? = { ClaudeCLI.locate() }
    /// Puts the helper in place before Claude is told to run it, even with Claude's hooks off.
    var installHelper: () throws -> Void = { try ClaudeHooks.ensureHelper() }
    var environment = ProcessInfo.processInfo.environment

    static func addArguments(helper: String) -> [String] { ["mcp", "add", "--scope", "user", "--transport", "stdio", serverName, "--", helper, flag] }
    static let getArguments = ["mcp", "get", serverName]
    static let removeArguments = ["mcp", "remove", "--scope", "user", serverName]

    /// The command to give the user when Nook cannot run Claude's: shell-quoted, only for reading.
    var manualCommand: String { "claude " + Self.addArguments(helper: helper).map { $0.contains(" ") ? Shell.quote($0) : $0 }.joined(separator: " ") }

    /// How a folder reads in messages: "~/.claude-work".
    static func name(of folder: URL) -> String { "~/" + folder.lastPathComponent }

    /// Claude's environment for a folder: Nook's own, with the PATH that finds `claude`, and `CLAUDE_CONFIG_DIR` naming the folder,
    /// except for `~/.claude`, which is Claude's default and must not have it (an inherited one is taken out).
    func environment(for folder: URL, cli: ClaudeCLI) -> [String: String] {
        var environment = environment
        environment["PATH"] = cli.path
        environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        if folder.standardizedFileURL.path != home.appendingPathComponent(".claude").standardizedFileURL.path {
            environment["CLAUDE_CONFIG_DIR"] = folder.standardizedFileURL.path
        }
        return environment
    }

    /// The command and arguments `claude mcp get` shows for the server ("  Command: …", "  Args: …"); nil when it shows none.
    static func registered(in output: String) -> (command: String, args: String)? {
        var command: String?, args = ""
        for line in output.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Command:") { command = line.dropFirst("Command:".count).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("Args:") { args = line.dropFirst("Args:".count).trimmingCharacters(in: .whitespaces) }
        }
        return command.map { ($0, args) }
    }

    func register() throws -> ScreenVisionRegistrationResult {
        try installHelper()
        guard let cli = locate() else { throw ScreenVisionRegistrationError.claudeNotFound(manual: manualCommand) }
        var result = ScreenVisionRegistrationResult(folders: [])
        for folder in folders() {
            let name = Self.name(of: folder), environment = environment(for: folder, cli: cli)
            let found = try runner.run(cli.executable, Self.getArguments, environment: environment, timeout: Self.timeout)
            if found.status == 0 {
                // Already there as this helper: nothing to do.
                if let current = Self.registered(in: found.output), current.command == helper, current.args == Self.flag { result.folders.append(name); continue }
                // Under the same name with another command (an older place of the helper): replaced. Should it not go, adding says why.
                _ = try runner.run(cli.executable, Self.removeArguments, environment: environment, timeout: Self.timeout)
            }
            let added = try runner.run(cli.executable, Self.addArguments(helper: helper), environment: environment, timeout: Self.timeout)
            guard added.status == 0 else { throw ScreenVisionRegistrationError.failed(folder: name, action: "añadir", output: Self.excerpt(added.output)) }
            result.folders.append(name)
            result.added.append(name)
        }
        return result
    }

    func unregister() throws -> ScreenVisionRegistrationResult {
        guard let cli = locate() else {
            throw ScreenVisionRegistrationError.claudeNotFound(manual: "claude " + Self.removeArguments.joined(separator: " "))
        }
        var removed: [String] = []
        for folder in folders() {
            let name = Self.name(of: folder), environment = environment(for: folder, cli: cli)
            let found = try runner.run(cli.executable, Self.getArguments, environment: environment, timeout: Self.timeout)
            guard found.status == 0 else { continue }
            let gone = try runner.run(cli.executable, Self.removeArguments, environment: environment, timeout: Self.timeout)
            guard gone.status == 0 else { throw ScreenVisionRegistrationError.failed(folder: name, action: "quitar", output: Self.excerpt(gone.output)) }
            removed.append(name)
        }
        return ScreenVisionRegistrationResult(folders: removed)
    }

    /// The end of what Claude printed, enough to say what went wrong.
    static func excerpt(_ output: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 240 ? "…" + String(text.suffix(240)) : text
    }
}
