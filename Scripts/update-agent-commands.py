#!/usr/bin/env python3
"""Regenerates the built-in command lists Nook offers when "/" is typed, from each agent's
official reference:

  Resources/claude-commands.json  <- https://code.claude.com/docs/en/commands
  Resources/codex-commands.json   <- https://developers.openai.com/codex/cli/slash-commands

Usage: Scripts/update-agent-commands.py [claude|codex|all] [path-to-page.md]
Without a path it downloads the page's markdown version.
"""
import datetime
import json
import os
import re
import subprocess
import sys

SOURCES = {
    "claude": "https://code.claude.com/docs/en/commands",
    "codex": "https://developers.openai.com/codex/cli/slash-commands",
}
VERSION_COMMANDS = {"claude": ["claude", "--version"], "codex": ["codex", "--version"]}
NAME = r"[A-Za-z0-9][A-Za-z0-9:_.-]*"


def plain(text):
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    return text.replace("`", "").replace("\\|", "|").strip()


def first_sentence(text):
    sentence = re.split(r"(?<=[.!?])\s+(?=[A-Z/])", text, maxsplit=1)[0].strip()
    return sentence[:-1] if sentence.endswith(".") else sentence


def cells(line):
    return [cell.strip() for cell in re.split(r"(?<!\\)\|", line.strip())[1:-1]]


def parse_claude(markdown):
    """Rows like "| `/add-dir <path>` | Add a working directory… Alias: `/x` |"."""
    commands = []
    for line in markdown.splitlines():
        row = cells(line) if line.startswith("| `/") else []
        if len(row) < 2:
            continue
        match = re.match(r"/(%s)\s*(.*)$" % NAME, plain(row[0]))
        if not match:
            continue
        description = plain(row[1])
        # Commands the reference keeps only to say they were removed are left out.
        if description.lower().startswith("removed"):
            continue
        kind = "command"
        for label in ("Skill", "Workflow"):
            prefix = "**%s.**" % label
            if description.startswith(prefix):
                kind, description = label.lower(), description[len(prefix):].strip()
        aliases = []
        for found in re.findall(r"[Aa]lias(?:es)?:\s*((?:/[A-Za-z0-9:_-]+(?:,\s*|\s+(?:and|or)\s+)?)+)", description):
            aliases += re.findall(r"/([A-Za-z0-9:_-]+)", found)
        commands.append({"name": match.group(1), "hint": match.group(2).strip() or None,
                         "detail": first_sentence(description.replace("**", "")), "aliases": aliases, "kind": kind})
    return commands


def parse_codex(markdown):
    """Rows like "| [`/side`, `/btw`](#anchor) | Start an ephemeral side chat. | When to use it |"."""
    section = markdown.split("## Built-in slash commands", 1)[-1]
    commands = []
    for line in section.splitlines():
        row = cells(line) if line.startswith("| [`/") else []
        if len(row) < 2:
            continue
        names = re.findall(r"`/(%s)`" % NAME, row[0])
        description = plain(row[1])
        # Nook runs on macOS only.
        if not names or "windows only" in description.lower():
            continue
        commands.append({"name": names[0], "hint": None, "detail": first_sentence(description),
                         "aliases": names[1:], "kind": "command"})
    return commands


PARSERS = {"claude": parse_claude, "codex": parse_codex}


def update(agent, path=None):
    if path:
        markdown = open(path, encoding="utf-8").read()
    else:
        # curl uses the system's certificates, which some Python installs lack.
        markdown = subprocess.run(["curl", "-fsSL", SOURCES[agent] + ".md"], capture_output=True, text=True, check=True).stdout
    try:
        printed = subprocess.run(VERSION_COMMANDS[agent], capture_output=True, text=True, timeout=20).stdout
        version = re.search(r"\d+\.\d+\.\d+", printed).group(0)
    except Exception:
        version = None
    commands = PARSERS[agent](markdown)
    if len(commands) < 20:
        sys.exit("%s: only %d commands found; the page format may have changed." % (agent, len(commands)))
    target = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "%s-commands.json" % agent)
    with open(target, "w", encoding="utf-8") as output:
        json.dump({"source": SOURCES[agent], "retrieved": datetime.date.today().isoformat(), "version": version,
                   "commands": commands}, output, ensure_ascii=False, indent=1)
        output.write("\n")
    print("%s: %d commands written to %s" % (agent, len(commands), os.path.normpath(target)))


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    path = sys.argv[2] if len(sys.argv) > 2 else None
    for agent in (SOURCES if which == "all" else [which]):
        update(agent, path)


if __name__ == "__main__":
    main()
