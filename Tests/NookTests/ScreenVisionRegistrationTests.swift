import XCTest
@testable import Nook

/// Registering the tool with `claude mcp`: the exact commands, their arguments and environment for each configuration folder. No test
/// ever runs Claude: a recorder answers instead.
final class ScreenVisionRegistrationTests: XCTestCase {
    private final class Recorder: CommandRunning {
        struct Call: Equatable {
            var executable: String
            var arguments: [String]
            var environment: [String: String]
        }
        var calls: [Call] = []
        var answer: (Call) -> CommandResult = { _ in CommandResult(status: 0, output: "") }

        func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> CommandResult {
            let call = Call(executable: executable, arguments: arguments, environment: environment)
            calls.append(call)
            return answer(call)
        }
    }

    private let home = URL(fileURLWithPath: "/Users/prueba")
    private let helper = "/Users/prueba/Library/Application Support/Nook/nook-hook"
    private let cli = ClaudeCLI(executable: "/Users/prueba/.local/bin/claude", path: "/Users/prueba/.local/bin:/opt/homebrew/bin:/usr/bin:/bin")
    private var events: [String] = []

    private func registrar(_ recorder: Recorder, cli: ClaudeCLI?? = nil, helperFails: Bool = false) -> ClaudeMCPRegistrar {
        var registrar = ClaudeMCPRegistrar()
        registrar.helper = helper
        registrar.home = home
        registrar.folders = { [home] in [home.appendingPathComponent(".claude"), home.appendingPathComponent(".claude-work")] }
        registrar.runner = recorder
        let found = cli ?? self.cli
        registrar.locate = { found }
        registrar.installHelper = { [unowned self] in
            self.events.append("helper")
            if helperFails { throw TerminalBridgeError.failed("No se pudo instalar el componente de Nook que abre Claude (nook-hook).") }
        }
        // Nook started from a shell that had another account's folder set: it must not leak into ~/.claude's commands.
        registrar.environment = ["PATH": "/usr/bin:/bin", "HOME": "/Users/prueba", "CLAUDE_CONFIG_DIR": "/Users/prueba/.claude-otra", "LANG": "es_ES.UTF-8"]
        return registrar
    }

    /// What `claude mcp get` prints for a stdio server (the format of Claude Code 2.1).
    private func getOutput(command: String, args: String = "--mcp-screen") -> String {
        """
        nook-screen:
          Scope: User config (available in all your projects)
          Status: ✓ Connected
          Type: stdio
          Command: \(command)
          Args: \(args)
          Environment:

        To remove this server, run: claude mcp remove "nook-screen" -s user
        """
    }

    private let addArguments = ["mcp", "add", "--scope", "user", "--transport", "stdio", "nook-screen", "--",
                                "/Users/prueba/Library/Application Support/Nook/nook-hook", "--mcp-screen"]

    // MARK: Registering

    func testTheToolGoesIntoEveryFolderEachWithItsOwnConfigDir() throws {
        let recorder = Recorder()
        recorder.answer = { $0.arguments[1] == "get" ? CommandResult(status: 1, output: "No MCP server named \"nook-screen\".") : CommandResult(status: 0, output: "Added stdio MCP server nook-screen") }
        let result = try registrar(recorder).register()
        XCTAssertEqual(result, ScreenVisionRegistrationResult(folders: ["~/.claude", "~/.claude-work"], added: ["~/.claude", "~/.claude-work"]))
        XCTAssertEqual(events, ["helper"], "The helper is in place before Claude is told to run it.")
        XCTAssertEqual(recorder.calls.map(\.arguments), [["mcp", "get", "nook-screen"], addArguments, ["mcp", "get", "nook-screen"], addArguments])
        XCTAssertTrue(recorder.calls.allSatisfy { $0.executable == "/Users/prueba/.local/bin/claude" })
        // The helper's path, space and all, is one argument: no shell ever reads it.
        XCTAssertEqual(recorder.calls[1].arguments[8], "/Users/prueba/Library/Application Support/Nook/nook-hook")

        let main = recorder.calls[0].environment, work = recorder.calls[2].environment
        XCTAssertNil(main["CLAUDE_CONFIG_DIR"], "~/.claude is Claude's default: no CLAUDE_CONFIG_DIR, not even an inherited one.")
        XCTAssertEqual(work["CLAUDE_CONFIG_DIR"], "/Users/prueba/.claude-work", "Any other folder is the account CLAUDE_CONFIG_DIR names.")
        XCTAssertEqual(recorder.calls[1].environment, main); XCTAssertEqual(recorder.calls[3].environment, work)
        for environment in [main, work] {
            XCTAssertEqual(environment["PATH"], cli.path, "The PATH that found claude (an npm install needs node on it).")
            XCTAssertEqual(environment["HOME"], "/Users/prueba"); XCTAssertEqual(environment["LANG"], "es_ES.UTF-8")
        }
    }

    func testAToolAlreadyThereIsLeftAlone() throws {
        let recorder = Recorder()
        recorder.answer = { [helper] _ in CommandResult(status: 0, output: self.getOutput(command: helper)) }
        let result = try registrar(recorder).register()
        XCTAssertEqual(result, ScreenVisionRegistrationResult(folders: ["~/.claude", "~/.claude-work"], added: []), "Nothing new: no restart needed.")
        XCTAssertEqual(recorder.calls.map { $0.arguments[1] }, ["get", "get"])
    }

    func testAToolWithAnotherCommandIsReplaced() throws {
        let recorder = Recorder()
        recorder.answer = { call in
            call.arguments[1] == "get" ? CommandResult(status: 0, output: self.getOutput(command: "/Applications/Nook.app/Contents/MacOS/Nook")) : CommandResult(status: 0, output: "")
        }
        var one = registrar(recorder)
        one.folders = { [home] in [home.appendingPathComponent(".claude")] }
        let result = try one.register()
        XCTAssertEqual(recorder.calls.map(\.arguments), [["mcp", "get", "nook-screen"], ["mcp", "remove", "--scope", "user", "nook-screen"], addArguments])
        XCTAssertEqual(result.added, ["~/.claude"])
        // The same command with other arguments is not this tool either.
        recorder.calls = []
        recorder.answer = { [helper] call in call.arguments[1] == "get" ? CommandResult(status: 0, output: self.getOutput(command: helper, args: "--claude-hook")) : CommandResult(status: 0, output: "") }
        _ = try one.register()
        XCTAssertEqual(recorder.calls.map { $0.arguments[1] }, ["get", "remove", "add"])
    }

    func testAFailedAddSaysWhereAndWhy() {
        let recorder = Recorder()
        recorder.answer = { call in
            switch (call.arguments[1], call.environment["CLAUDE_CONFIG_DIR"]) {
            case ("get", _): CommandResult(status: 1, output: "")
            case ("add", nil): CommandResult(status: 0, output: "")
            default: CommandResult(status: 1, output: "Error: no se pudo escribir /Users/prueba/.claude-work/.claude.json\n")
            }
        }
        XCTAssertThrowsError(try registrar(recorder).register()) { error in
            XCTAssertEqual(error as? ScreenVisionRegistrationError, .failed(folder: "~/.claude-work", action: "añadir", output: "Error: no se pudo escribir /Users/prueba/.claude-work/.claude.json"))
            XCTAssertEqual(error.localizedDescription, "No se pudo añadir la herramienta en ~/.claude-work: Error: no se pudo escribir /Users/prueba/.claude-work/.claude.json")
        }
    }

    func testWithoutClaudeOrTheHelperNothingRuns() {
        let recorder = Recorder()
        XCTAssertThrowsError(try registrar(recorder, cli: .some(nil)).register()) { error in
            XCTAssertEqual(error.localizedDescription,
                           "No se encontró Claude Code (el comando claude). Instálalo, o añade la herramienta a mano con: claude mcp add --scope user --transport stdio nook-screen -- '/Users/prueba/Library/Application Support/Nook/nook-hook' --mcp-screen",
                           "The manual command is quoted for reading; it is never run through a shell.")
        }
        XCTAssertThrowsError(try registrar(recorder, cli: .some(nil)).unregister()) { error in
            XCTAssertTrue(error.localizedDescription.hasSuffix("claude mcp remove --scope user nook-screen"), error.localizedDescription)
        }
        XCTAssertThrowsError(try registrar(recorder, helperFails: true).register()) { error in
            XCTAssertEqual(error.localizedDescription, "No se pudo instalar el componente de Nook que abre Claude (nook-hook).")
        }
        XCTAssertEqual(recorder.calls, [])
    }

    // MARK: Removing

    func testRemovingTakesItOutOnlyWhereItIs() throws {
        let recorder = Recorder()
        recorder.answer = { [helper] call in
            if call.arguments[1] == "get" { return call.environment["CLAUDE_CONFIG_DIR"] == nil ? CommandResult(status: 0, output: self.getOutput(command: helper)) : CommandResult(status: 1, output: "") }
            return CommandResult(status: 0, output: "Removed MCP server nook-screen from user config")
        }
        let result = try registrar(recorder).unregister()
        XCTAssertEqual(result.folders, ["~/.claude"])
        XCTAssertEqual(recorder.calls.map(\.arguments), [["mcp", "get", "nook-screen"], ["mcp", "remove", "--scope", "user", "nook-screen"], ["mcp", "get", "nook-screen"]])
        XCTAssertNil(recorder.calls[1].environment["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(events, [], "Removing needs no helper.")
    }

    func testAFailedRemovalSaysWhere() {
        let recorder = Recorder()
        recorder.answer = { call in call.arguments[1] == "get" ? CommandResult(status: 0, output: "") : CommandResult(status: 1, output: "Error: permiso denegado") }
        XCTAssertThrowsError(try registrar(recorder).unregister()) { error in
            XCTAssertEqual(error.localizedDescription, "No se pudo quitar la herramienta en ~/.claude: Error: permiso denegado")
        }
    }

    func testTheRegisteredCommandIsReadFromClaudesOwnOutput() {
        let found = ClaudeMCPRegistrar.registered(in: getOutput(command: helper))
        XCTAssertEqual(found?.command, helper)
        XCTAssertEqual(found?.args, "--mcp-screen")
        XCTAssertNil(ClaudeMCPRegistrar.registered(in: "nook-screen:\n  Type: http\n  URL: https://example.com/mcp"))
        XCTAssertEqual(ClaudeMCPRegistrar.excerpt(String(repeating: "x", count: 500)).count, 241, "A long error is cut to its end.")
    }

    // MARK: Finding claude

    func testClaudeIsFoundThroughTheLoginShellFirst() throws {
        let recorder = Recorder()
        recorder.answer = { _ in CommandResult(status: 0, output: "Bienvenido\n/Users/prueba/.npm-global/bin/claude\nPATH=/Users/prueba/.npm-global/bin:/opt/homebrew/bin:/usr/bin\n") }
        let found = ClaudeCLI.locate(runner: recorder, environment: ["SHELL": "/bin/bash", "PATH": "/usr/bin"], home: "/Users/prueba",
                                     isExecutable: { ["/bin/bash", "/Users/prueba/.npm-global/bin/claude"].contains($0) }, shells: ["/bin/bash", "/bin/zsh"])
        XCTAssertEqual(found, ClaudeCLI(executable: "/Users/prueba/.npm-global/bin/claude", path: "/Users/prueba/.npm-global/bin:/opt/homebrew/bin:/usr/bin"))
        let call = try XCTUnwrap(recorder.calls.first)
        XCTAssertEqual(call.executable, "/bin/bash", "The user's own shell, as a login shell.")
        XCTAssertEqual(call.arguments, ["-lc", "command -v claude; printf 'PATH=%s\\n' \"$PATH\""], "A fixed script, with nothing of the user's in it.")
    }

    func testAShellTheSystemDoesNotListIsNeverRun() {
        let executable: (String) -> Bool = { _ in true }
        XCTAssertEqual(ClaudeCLI.loginShell("/Users/prueba/bin/zsh", isExecutable: executable, listed: ["/bin/zsh", "/bin/bash"]), "/bin/zsh",
                       "Named like zsh but not a login shell of this Mac.")
        XCTAssertEqual(ClaudeCLI.loginShell("/opt/homebrew/bin/bash", isExecutable: executable, listed: ["/bin/zsh", "/opt/homebrew/bin/bash"]), "/opt/homebrew/bin/bash")
        XCTAssertTrue(ClaudeCLI.systemShells().contains("/bin/zsh"), "macOS lists its own shells.")
    }

    func testWithoutAnAnswerTheKnownPlacesAreTried() {
        let recorder = Recorder()
        recorder.answer = { _ in CommandResult(status: 1, output: "") }
        let found = ClaudeCLI.locate(runner: recorder, environment: ["SHELL": "/usr/local/bin/fish", "PATH": "/usr/bin"], home: "/Users/prueba",
                                     isExecutable: { ["/bin/zsh", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].contains($0) })
        XCTAssertEqual(recorder.calls.first?.executable, "/bin/zsh", "A shell that does not speak sh is not asked.")
        XCTAssertEqual(found, ClaudeCLI(executable: "/opt/homebrew/bin/claude", path: "/Users/prueba/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin"))
        XCTAssertNil(ClaudeCLI.locate(runner: recorder, environment: [:], home: "/Users/prueba", isExecutable: { _ in false }))
        // An alias or anything that is not an absolute path is not an executable.
        XCTAssertNil(ClaudeCLI.parse(loginOutput: "claude: aliased to npx claude\nPATH=/usr/bin").executable)
        XCTAssertEqual(ClaudeCLI.parse(loginOutput: "claude: aliased to npx claude\nPATH=/usr/bin").path, "/usr/bin")
    }

    // MARK: Running commands

    func testCommandsRunWithExactlyTheirArgumentsAndEnvironmentAndATimeLimit() throws {
        let runner = ProcessRunner()
        let echoed = try runner.run("/bin/echo", ["uno dos", "$HOME", "'tres'"], environment: [:], timeout: 5)
        XCTAssertEqual(echoed, CommandResult(status: 0, output: "uno dos $HOME 'tres'\n"), "No shell expands or splits anything.")
        let environment = try runner.run("/usr/bin/env", [], environment: ["NOOK_PRUEBA": "sí"], timeout: 5)
        XCTAssertTrue(environment.output.split(separator: "\n").contains("NOOK_PRUEBA=sí"), environment.output)
        XCTAssertFalse(environment.output.contains("HOME="), "Only the environment it is given.")
        let started = Date()
        XCTAssertThrowsError(try runner.run("/bin/sleep", ["5"], environment: [:], timeout: 0.3)) { error in
            XCTAssertEqual(error as? ScreenVisionRegistrationError, .timedOut("sleep"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testTheHelperIsCopiedForTheToolEvenWithTheHooksOff() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nsv-helper-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("Nook")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        let helper = folder.appendingPathComponent("Support/nook-hook")
        try ClaudeHooks.ensureHelper(from: executable, to: helper)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: executable.path, andPath: helper.path))
        XCTAssertEqual(ScreenVisionFixture.posixPermissions(helper.path), 0o700)
        let before = try FileManager.default.attributesOfItem(atPath: helper.path)[.systemFileNumber] as? Int
        try ClaudeHooks.ensureHelper(from: executable, to: helper)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: helper.path)[.systemFileNumber] as? Int, before, "A current copy is not copied again.")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: executable)
        try ClaudeHooks.ensureHelper(from: executable, to: helper)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: executable.path, andPath: helper.path), "A newer Nook replaces it.")
        XCTAssertThrowsError(try ClaudeHooks.ensureHelper(from: nil, to: folder.appendingPathComponent("missing/nook-hook")))
    }
}
