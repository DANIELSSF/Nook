<div align="center">

<img src="docs/assets/nook-banner.svg" alt="Nook — your terminal, a gesture away" width="100%">

**A little cat. A compact island. Your terminal, within reach.**

![macOS](https://img.shields.io/badge/macOS-27%2B-151719?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)
![Status](https://img.shields.io/badge/status-in_development-8EC9B4)

[Get started](#get-started) · [Build](#build) · [Usage guide (ES)](docs/USAGE.md) · [Development (ES)](docs/DEVELOPMENT.md)

</div>

Nook is a native macOS app that brings your terminal sessions to the notch. Follow your AI's work, send messages, and catch requests for your attention without switching away from what you're doing. Move the pointer toward the cat to expand the island from the top edge of your screen.

<div align="center">

<img src="docs/assets/nook-preview.png" alt="Expanded Nook panel with a Claude Code session showing a sample website task" width="572">

<sub>App-rendered preview with a sample conversation. The app's current interface is in Spanish.</sub>

</div>

## Your session stays yours

- **Connect individual tabs.** Drag the cat to macOS Terminal or choose the session you want to follow.
- **Write comfortably.** Send multiline messages, keep a draft for each tab, browse message history, and complete `/` commands for Claude Code and Codex.
- **Return to the original terminal.** Bring its window forward with one button. Closing a Nook tab keeps the original terminal session open.
- **Make it your own.** Rename tabs, choose soft accent colors, and adjust the panel and text size.
- **Follow Claude's work.** Read conversations, answer questions and permission requests, and check summaries and subagent activity.
- **Read code clearly.** Claude responses support formatted text and highlighted code. Inline edits show numbered lines with red and green backgrounds for removed and added code.
- **Explore subagent conversations.** Open an agent from its tab badge or the composer capsule to see its name, model, status, and conversation. The composer continues to send messages to the main Claude session.
- **Use Claude's interactive panels.** View panels such as `/usage`, `/status`, `/config`, and `/mcp`, navigate with familiar keys, and return to the conversation with your draft preserved.
- **See activity at a glance.** The notch badge shows working subagents; hover for details or click to open their tab and list.
- **Add context.** Dictate a draft, paste images, or drag files into your message.
- **Enjoy a cat with personality.** Curious glances, grooming, naps, play, and celebrations, with support for Reduce Motion.

You can also create shared terminal sessions through the bundled tmux backend. The island and conversation use a dark surface that blends with the notch.

## Get started

1. Open Nook and choose **Conectar una terminal…** (Connect a terminal), or drag the cat to a Terminal window.
2. Allow Nook to control Terminal when macOS asks.
3. Move the pointer toward the cat to expand the island, then click to start typing.

In **Ajustes → Permisos** (Settings → Permissions), you can review Automation, Accessibility, microphone, speech recognition, and Claude notifications. Dictation prepares a draft; you choose when to send it.

## Build

The current packaged app requires **macOS 27 or later** and targets **Apple Silicon**. You'll need Swift 6 / Xcode, the command line tools, and Homebrew.

```sh
git clone https://github.com/DANIELSSF/Nook.git
cd Nook
brew install libevent
bash Scripts/build-app.sh release
open dist/Nook.app
```

The first build downloads SwiftTerm and the tmux source. The resulting app is signed locally with an ad hoc signature and is not yet notarized. Install and authenticate the Claude Code and Codex CLIs separately.

## Current scope

Direct connections currently support **macOS Terminal**. iTerm2, Ghostty, Warp, and editor terminals do not yet have direct integration. External sessions use a text mirror; Nook's own tmux sessions use the integrated terminal emulator.

Conversation transcripts, summaries, subagent views, and interactive Claude panels are specific to Claude Code. Arrow keys, Tab, Escape, and direct image paste in external tabs require Accessibility permission. See the [usage guide (Spanish)](docs/USAGE.md) for details on each mode.

## Built for macOS

**SwiftUI · AppKit · SwiftTerm · tmux · Speech**

[Architecture and tests (ES)](docs/DEVELOPMENT.md) · [Contributing (ES)](CONTRIBUTING.md) · [Third-party notices (ES)](THIRD_PARTY_NOTICES.md)

Nook is in active development. A redistribution license has not yet been chosen for the project's own code; dependencies retain their original licenses.
