import AppKit

if CommandLine.arguments.contains("--claude-hook") {
    ClaudeHooks.forwardFromCLI()
    exit(0)
}
if CommandLine.arguments.contains("--terminal-script") {
    TerminalAppBridge.serveFromCLI()
    exit(0)
}
// A helper that exits must surface as a write error, not end Nook with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
