# Nook Remote: page ⇄ Nook contract

Nook can serve a small web app on the home network so a phone (iPhone first) can do what the island's conversation view does:
read the live conversation, send messages (optionally with a screenshot of the Mac), answer question cards, interrupt, press
keys, switch and open tabs, change model and mode, and see the screenshots that were sent. This file is the contract between the
server (Swift, `Sources/Nook/Remote*.swift`) and the page (`Resources/remote/index.html`). Both sides follow it; a change to a
shape here is made on both sides in the same change. Fields may be added; existing ones keep their meaning.

User-facing strings (page and errors) are Spanish. Everything else (keys, enums, code) is English.

## Lifecycle and access

- Hidden until unlocked: Settings → Isla → «Acerca de» shows the version; five taps on it unlock a **Remoto** settings tab
  (`nook.remote.unlocked`, persisted). The server itself is **always off when Nook starts**; the user turns it on in that tab.
- Each activation generates a new random **pairing key** (32 bytes, base64url). Turning it off closes every connection and
  forgets every paired device. Nothing about it is persisted.
- Port **8765**; if taken, the next free one up to 8775. The Remoto tab shows `http://<LAN IPv4>:<port>` and a QR of the
  pairing URL.
- Home network only:
  - accept a connection only from a private or link-local address (10/8, 172.16/12, 192.168/16, 169.254/16, fc00::/7,
    fe80::/10);
  - reject loopback and **every address of this Mac** (the page must not open on the Mac itself, by design);
  - reject any request whose `Host` is not `<one of this Mac's LAN addresses>:<port>` (DNS rebinding).
- Plain HTTP/1.1 (the user accepted no TLS on their home network).

### Pairing

`GET /pair?k=<pairing key>`:
- right key (constant-time compare) → a new per-device token (32 random bytes, base64url), answered with
  `Set-Cookie: nook_remote=<token>; HttpOnly; SameSite=Strict; Path=/` and `303 See Other` → `/`;
- wrong or missing key → `403` with a short Spanish HTML page («Escanea el código QR en Nook → Ajustes → Remoto.»).

Every `/api/*` request needs a valid `nook_remote` cookie, else `401` `{"error":"Empareja este dispositivo escaneando el QR en Nook."}`.
Every `POST` also needs the header `X-Nook-Remote: 1` and `Content-Type: application/json`; a present `Origin` must be
`http://<Host>`. Request bodies are capped at 64 KB (an image for `/api/upload`: 12 MB, see "Images from the phone").

`GET /` serves the page to anyone allowed on the network (it holds no data); the page calls `/api/state` and shows the
pairing hint on `401`.

## Errors

Any failing call answers a non-2xx status with `{"error": "<Spanish sentence for the user>"}`. Success is `200` with
`{"ok": true}` plus any fields listed for that call.

## Reading

### `GET /api/state` → `State`

```jsonc
{
  "v": 1,
  "mac": "MacBook de Daniel",            // Host.current().localizedName
  "screen": { "available": true,          // Ajustes → Pantalla is on (ScreenVision.enabled) and recording is allowed
              "attach": false },          // the composer's eye (ScreenVision.attachToMessages, while screen vision is on), shared with the Mac
  "selected": "<tab id>" ,                // AppModel.selectedID; null when there are no tabs
  "tabs": [Tab],
  "detail": TabDetail | null,             // the selected tab only
  "notice": "texto" | null                // AppModel.notice
}
```

`Tab`:
```jsonc
{
  "id": "terminal.app::/dev/ttys004@1759766567.123456",
  "title": "Claude Code 2",               // displayTitle
  "tint": "#7ad6b0",                      // the tab's colour as the island draws it (dark theme)
  "icon": "dot",                          // TabIcon raw value; the page has its own drawing per value
  "agent": "claude" | "codex" | null,     // the agent at the front of the tab
  "kind": "shell" | "claude" | "codex",   // SessionKind of the record
  "state": "idle" | "working" | "finished" | "attention",
  "unread": true,
  "question": true,                       // a question card (not a selector) is waiting
  "agents": { "running": 2, "done": 1, "failed": 0 }
}
```

`TabDetail`:
```jsonc
{
  "id": "<tab id>",
  "running": true, "sending": false, "answering": false,
  "status": { "glyph": "✶", "text": "Churning… (1m 2s · ↓ 3.4k tokens)", "working": true, "background": 2 | null } | null,   // background: how many background agents Claude is waiting for
  "model": { "current": "Opus 5.5", "choices": [ { "id": "opus", "label": "Opus 5.5", "detail": "…", "current": true } ],
             "blocked": "texto" | null } | null,          // null for tabs without Claude
  "mode": { "kind": "auto" | "acceptEdits" | "plan" | "bypassPermissions" | "default",
            "title": "Auto", "blocked": "texto" | null } | null,
  "prompt": Prompt | null,
  "field": { "signature": "…", "option": 3, "question": "…", "title": "Type something." } | null,
                                           // an inline option was chosen: the composer answers that field
  "panel": { "name": "Status", "rows": [PanelRow], "moreAbove": false, "moreBelow": true } | null,
  "subagents": [ { "id": "…", "name": "…", "kind": "…", "model": "Sonnet", "state": "running" | "done" | "failed",
                   "activity": "Read(Sources/Nook/Pet.swift)", "duration": "1m 3s", "tokens": "12.3k" } ],
  "viewedAgent": "<subagent id>" | null,
  "pending": [ { "text": "…", "state": "sending" | "waiting" | "queued" } ],
  "suggestion": "texto" | null,           // Claude's grey suggestion in its input box
  "shots": [ { "url": "/api/shot/pantalla-20261105-083645.png", "at": "2026-11-05T08:36:45Z", "text": "lo que se escribió" } ],
  "conversationEpoch": 7                  // see below
}
```

`Prompt` (an `AgentPrompt` read from the screen):
```jsonc
{
  "signature": "…",                        // echoed back on every answer; a stale signature is refused
  "kind": "approval" | "question" | "selector",
  "header": "Database" | null, "question": "…", "note": "…" | null, "context": "…" | null,
  "tabs": [ { "title": "Cache", "answered": true, "isSubmit": false } ],
  "options": [ { "index": 0, "number": 1, "title": "Yes", "detail": "…" | null, "input": "none" | "inline" | "followUp",
                 "checked": true | null, "current": false } ],
  "highlighted": 0, "multiSelect": false,
  "review": [ { "question": "…", "answer": "…" | null } ], "reviewTitle": "…" | null, "warning": "…" | null,
  "takesNotes": false
}
```

`PanelRow` mirrors `ClaudePanel.Row`: `{ "kind": "blank" | "rule" | "tabs" | "heading" | "text" | "caption" | "cursor" | "bar" | "hint", … }`
with the case's values as fields (`tabs`: `names`, `active`; `text`: `indent`, `label`, `body`; `bar`: `lead`, `fraction`, `trailing`; others: `text`).

### `GET /api/events` → Server-Sent Events

`Content-Type: text/event-stream`. Events:
- `state` — a full `State` (without conversation lines), sent on connect and whenever it changes (coalesced, at most ~5/s);
- `conversation` — a `ConversationUpdate` for the selected tab (on connect, on tab change, whenever its text changes);
- `ping` — every 15 s, to keep the connection alive.

The page reconnects on error (EventSource does this by itself) and treats every `state` as the whole truth.

### Conversation lines

The conversation is not a list of messages in Nook: it is the text the island shows (`TerminalSession.displayText`, Claude's
record rendered as terminal-like lines), styled line by line by `TranscriptClassifier`. The server sends the lines **already
classified**, so the page draws them as the island does without re-implementing that logic.

`ConversationUpdate`:
```jsonc
{
  "tab": "<tab id>",
  "epoch": 7,                 // changes when the text was replaced rather than extended (another tab, a redraw, an agent view)
  "reset": true,              // true: drop what you have and take `lines` as the whole window
  "from": 1830,               // index of the first line in `lines`; on an append, replace your lines from this index on
  "hasEarlier": true,         // lines before the window exist: GET /api/conversation?before=<index>
  "transcript": true,         // false: plain terminal text (Codex, shells): draw lines as `plain`, monospaced
  "lines": [Line]
}
```

`Line`:
```jsonc
{
  "i": 1830,
  "text": "⏺ Read(Sources/Nook/Pet.swift)",
  "role": "user" | "assistant" | "tool" | "toolOutput" | "plain",
  "head": true,                         // first line of its block
  "marker": [0, 1] | null,              // UTF-16 range of the ⏺ / > / ⎿ marker within `text`
  "name": [2, 6] | null,                // the tool name's range
  "detail": { "kind": "none" }
          | { "kind": "summary", "path": "…", "added": 3, "removed": 1 }
          | { "kind": "row", "row": "removed" | "added" | "context" | "gap", "number": 41, "code": [12, 40] }
          | { "kind": "fence" }
          | { "kind": "code", "language": "swift" }
          | { "kind": "verbatim" },
  "spans": [ { "from": 12, "to": 18, "style": "keyword" | "string" | "comment" | "number" | "type" | "call" | "attribute" | "plain" } ],
  "md": [ { "from": 3, "to": 9, "style": "bold" | "italic" | "code" | "link" | "strike", "url": "https://…" | null } ]
}
```
Ranges are UTF-16 offsets into `text` (JavaScript string indices). The first update after connecting or switching tabs is a
reset holding the last ~600 lines; later updates append. Pending messages (`detail.pending`) are drawn by the page after the
lines, like the island's `MirrorMessages`.

`GET /api/conversation?tab=<id>&before=<index>&limit=400` → `{ "lines": [Line], "hasEarlier": true, "epoch": 7 }`
(`409` with `{"error": …, "epoch": 8}` when the epoch moved on).

### `GET /api/shot/<file>`

The image of a screenshot that was sent with a message (`detail.shots`). Only files Nook took for a message, by exact name
(`pantalla-*.png|jpg` in `/tmp/nook-<uid>/images`), with the cookie. `Cache-Control: private, max-age=86400`.
Also the images the phone sent with a message (`imagen-movil-*.jpg|png|gif|webp`), and, to the device that uploaded it, one still
waiting to be sent (its preview). The type is the file's (`image/png`, `image/jpeg`, `image/gif`, `image/webp`).

## Acting

All `POST`, JSON body, `{"ok": true}` on success. Every call that targets a tab carries `"tab": "<id>"`; a tab that no longer
exists answers `404`.

| Call | Body | Does (Nook function) |
|---|---|---|
| `/api/select` | `{tab}` | `AppModel.select` (Nook's selected tab follows the phone) |
| `/api/send` | `{tab, text}` | the island's own send path, screenshot included when `screen.attach` and the text is not `/…` or `!…`; on failure answers the error and the page keeps the text (with `screen.attach` on in an agent's tab, `text` may be empty: the screenshot alone; see "Calls") |
| `/api/screen` | `{attach: bool}` | sets `ScreenVision.attachToMessages` (the same eye as the Mac's composer) |
| `/api/prompt/choose` | `{tab, signature, option, notes?}` | `AppModel.answer(_:option:on:)` (or with `notes:`); an `inline` option answers `{"ok":true,"field":true}` and the composer becomes that field |
| `/api/prompt/field` | `{tab, signature, option, text}` | `AppModel.sendToField` |
| `/api/prompt/cancel` | `{tab}` | `AppModel.cancelPrompt` |
| `/api/key` | `{tab, key}` | `AppModel.press`; `key` ∈ `up down left right tab backtab escape enter`; a key that needs Accessibility and lacks it answers `403` with that explanation (no dialog on the Mac) |
| `/api/interrupt` | `{tab}` | `AppModel.interrupt` |
| `/api/model` | `{tab, id}` | `AppModel.setModel` with the matching `ClaudeModelChoice` |
| `/api/mode/cycle` | `{tab}` | `AppModel.cycleMode` (⇧⇥: Claude only cycles) |
| `/api/agent/open` | `{tab, id}` / `{tab, id: null}` | `AppModel.openAgent` / leave the agent's conversation |
| `/api/tabs/new` | `{kind: "claude" \| "codex" \| "shell"}` | `AppModel.create` (opens a tab in Terminal on the Mac) |

Not offered on purpose: usage card, effort, voice dictation, settings.

## Server notes (additions; every shape above keeps its meaning)

What the server (`Sources/Nook/Remote*.swift`) sends beyond the shapes above, and how it behaves where the shapes leave room.
A page may ignore any of it.

### Ranges and nulls

- Every range (`marker`, `name`, `code`, `pathRange`…) is `[from, to]` in UTF-16 units of the line's own `text`, `to` excluded
  (`text.slice(from, to)` in JavaScript). Spans and `md` entries use `from`/`to` the same way.
- A field shown as `x | null` is always present, written as `null` when it has no value.

### Added fields

- `Tab`: nothing added.
- `TabDetail.mode.kind`: also `"other"`, a mode Nook does not know by name; its `title` is Claude's own words.
- `TabDetail.subagents[]`: `background` (bool, launched in the background) and `detail` (Nook's Spanish counters,
  "23 herramientas · 41.2k tokens · 3m 12s", or a state word).
- `TabDetail.pending`: also for a Codex or shell tab (`sending` / `waiting`); the island writes those into its plain text, the server
  sends them here instead, so the conversation's text never carries them.
- `Prompt`: `notes` (the notes the question holds, or null), `notesOpen` (its notes field has the terminal's keyboard), `preview` (the
  highlighted option's preview, or null), `moreAbove` / `moreBelow` (options out of sight, counts).
- `Prompt.options[]`: `shortcut` ("esc" in "No, and tell Claude … (esc)", or null) and `filled` (a text field Nook already wrote
  into that stays on screen: choosing it toggles its box, so its `input` is `"none"`).
- `PanelRow`: `indent` (columns) on `heading`, `text`, `caption`, `cursor` and `bar`; `title` (or null) on `tabs`.
- `Line.detail`: `summary` adds `pathRange`, `addedRange`, `removedRange` (null when absent; `added`/`removed` are null for a
  created file); `row` adds `mark` (the UTF-16 range `[from, to]` of the "-", "+" or the context row's space within `text`; null for a gap, whose `number` is null too); `code` adds
  `start` (where the code begins after the reply's indent).
- `Line.spans[].style`: also `variable`, `inserted` and `deleted` (the highlighter's own; `call` is a function call). `plain` is
  never sent: text without a span is plain.
- `Line.md[].style`: one entry per look (a bold link is two entries over the same range); also `hidden` (a mark the island hides:
  `**`, backticks, `[`, `](address)`, a heading's `#`), `heading` and `bullet` (a list item's dash, drawn as a bullet). `strike` is
  never sent today. `url` is set on `link` entries only.

### Conversation

- Lines are counted the way the classifier counts them: a final line break starts no line of its own.
- An append replaces the page's lines from `from` on; lines before `from` are exactly as the page has them. `from` is never before
  the window this stream was last given: a change that starts there is sent as a reset instead.
- `epoch` changes when the text is another one (another tab, an agent's conversation, Claude's transcript versus plain text) or when
  more than 1,000 lines changed at once. A reset sent only to refresh one stream's window keeps the epoch. Line numbers mean the
  same within an epoch, so paging stays valid across appends.
- `hasEarlier` on an append says whether lines exist before the window this stream was given; the page's own paging state wins.
- `GET /api/conversation` takes an optional `epoch=<n>`: a different one answers `409` with the current `epoch`. Without it the
  lines are the current epoch's (the answer says which). The answer also has `from` (the first line's index). `limit` is 1…1000.

### Calls

- Status codes: `400` a body or query the call can't use; `401` not paired; `403` wrong Host, Origin, missing `X-Nook-Remote`, a
  cross-site request, or a key that needs Accessibility (`/api/key`, `/api/interrupt`, `/api/mode/cycle`, `/api/prompt/cancel`,
  `/api/prompt/choose`); `404` no such tab, agent, model, file or call; `409` the tab can't do it now (the error says why: a
  question changed, Claude is working, a message is still on its way…); `413` body over 64 KB; `415` not JSON; `500` the screenshot
  could not be taken (`/api/send`); `502` the terminal did not take the message (`/api/send`); `503` Nook Remote is off; `504` Nook
  did not answer within 45 s.
- `/api/send`: when the dialog on screen has a text field that would take what is written (the one chosen on the card, or the
  highlighted one), the text answers it, as the island's composer does, and the answer is `{"ok": true, "field": true}`. With a
  question open whose highlighted option takes no text, the island asks for a second Enter before sending; the page should confirm
  the same way before calling. An empty text (spaces and line breaks only) with no `files` is refused with `400`, except when the
  screen goes with it: `state.screen.attach` is `true` and the tab's `Tab.agent` is `"claude"` or `"codex"` (not `null`). Then the
  message is the screenshot alone (`text` empty or left out, no `files`), the same send as any other: the page can offer sending
  with nothing written exactly under that rule. An open dialog's text field (`detail.field` not null) still refuses an empty send with
  `400` «Escribe tu respuesta antes de enviarla.» (nothing is written into it, and nothing goes to the agent's box instead).
  With `screen.attach` on, a message that would carry the screen while macOS doesn't let Nook record it (`screen.available` false)
  is refused with `409` before anything happens: no capture, and no permission dialog on the Mac. The page keeps the text.
  The screenshot is the area chosen on the Mac when its "Enviar solo un área de la pantalla" is on (`ScreenVision.messageArea`):
  only that rect is captured (ScreenCaptureKit's `sourceRect`), never the whole display. If the area's display is not connected
  nothing goes and the answer is `500` with the notice; there is no fallback to the whole screen. The phone neither sees nor sets
  the area. While the island is collapsed (`AppModel.expanded` false) the capture is quiet (`ScreenVisionCapture.quiet`): no cue
  under the notch and no flash of the composer's eye on the Mac.
- `/api/prompt/choose`: `notes` counts only when it has text; it then needs a question with a preview (`takesNotes`).
- `/api/screen`: `{attach: true}` answers `409` while `screen.available` is false: screen vision is off on the Mac, or macOS doesn't
  let Nook record the screen (read with the system's preflight, which never asks). `{attach: false}` always works.
- `/api/model`: `409` with the model button's own reason while it can't switch (`model.blocked`).
- `/api/mode/cycle`: `409` with the chip's own reason while it can't cycle (`mode.blocked`).
- `/api/tabs/new` answers as soon as Terminal was asked; the new tab arrives with a later `state`. The island on the Mac is not
  opened for it, but Terminal necessarily comes to the front on the Mac to open the tab (⌘T, or a new window).

### Pairing, devices and the network

- A pairing key pairs **one** device. The successful `/pair` uses it up and a new key takes its place at once (the QR in Ajustes →
  Remoto shows it live); the old link, scanned again or opened from the history, answers the `403` pairing page.
- At most 8 devices are paired at once. A ninth gets a `403` page: «Ya hay 8 dispositivos emparejados. Quita uno en Nook → Ajustes →
  Remoto.» Nothing is evicted; the user removes a device in Ajustes, which closes its open connections and its event stream at
  once (its cookie then answers `401`).
- The cookie is scoped to the host, not the port (cookies have no port), and travels without TLS: any page served by this Mac's
  address on another port would get it too. Nook serves nothing else there.
- Nook Remote stays on only on the home network it was turned on in: the same Wi-Fi or Ethernet interface, address and router. If
  the Mac moves to another network (or loses it for good), it turns off and the Remoto tab says so; it has to be turned on again,
  with a new key.
- Connections are taken over Wi-Fi or wired Ethernet only (never a VPN's tunnel, the cellular radio or AWDL), and a request's Host
  must be an address of that interface.

### Images from the phone: `POST /api/upload`

The phone attaches images to a message as the island's composer attaches an image pasted with ⌘V: each one is uploaded first, and
`/api/send` names them.

- Same cookie, `X-Nook-Remote: 1` and Origin rules as every POST, but the body is the image's raw bytes with
  `Content-Type: image/jpeg | image/png | image/gif | image/webp` (convert HEIC to JPEG first). At most 12 MB (`413`); the whole
  request may take 60 s. A body over 64 KB is read only once its head passed every check (cookie, headers, type, the device's limits):
  otherwise the answer comes at once and the body is never read. Two large uploads at a time server-wide (`503` beyond).
- The bytes must start as the declared type does (JPEG `FF D8 FF`, PNG's signature, `GIF87a`/`GIF89a`, `RIFF…WEBP`) and decode with
  ImageIO, at most 20,000 px a side and 120 megapixels; anything else is `415`.
- Answer: `{"ok": true, "id": "imagen-movil-20261105-093012-k3f9a2.jpg", "url": "/api/shot/imagen-movil-…jpg", "width": 1170,
  "height": 2532}`. The name is Nook's, never the page's. `url` serves the image to this device as a preview until it is sent.
- Each device may upload 30 images in 10 minutes (`429`) and have 20 waiting at once (`409`). One not sent within an hour is no
  longer offered; the file goes after a day, with the island's pasted images.
- `/api/send` takes `files: ["<id>", …]` (at most 5), ids this device uploaded and hasn't sent: they go as the message's attached
  files, before screen vision's screenshot when that is on. `text` may then be empty. An unknown, expired, already sent or other
  device's id answers `400` «La imagen ya no está disponible; adjúntala otra vez.». A question's text field takes no images (`409`).
  When the message goes, its images are used up and listed in `detail.shots` with the message's text (served by `/api/shot/<id>`
  to any paired device); when it doesn't, they wait for another try.
- Nothing changes for the island's own ⌘V images.

### The page's log: `POST /api/log`

The page's own errors, written on the Mac (Safari's Web Inspector needs a cable to reach the iPhone): call it from
`window.onerror`, `unhandledrejection` and when an API call fails. Same cookie and headers as every other POST.

```jsonc
{ "level": "error" | "warn" | "info", "message": "…", "detail": "…" | null, "url": "…" | null, "line": 12 | null, "ua": "…" }
```

- Body at most 8 KB (`413` beyond); a `level` other than those three, or no `message`, is `400`.
- `{"ok": true}`. Each device may write 20 entries a minute; the rest are dropped and answered `{"ok": true, "dropped": true}`
  (nothing for the page to do about it).
- Nook appends one line per entry to `~/Library/Logs/Nook/remote.log` (the user's alone, 0600; past ~64 KB only its newest half is
  kept): the time, the device's label, the level and the fields, every line break and control character escaped (`\n`, `\u{1b}`).
  Only while Nook Remote is on (off, no cookie opens it).

### Serving

- `GET /` is `index.html`; any other file of `Resources/remote/` is served by its plain name (`/app.js`), by type (html, js, css,
  json, webmanifest, svg, png, jpg, ico, woff2). No sub-folders.
- The page goes out with `Content-Security-Policy: default-src 'self'; script-src 'self' 'sha256-…'; style-src 'self'
  'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none';
  form-action 'self'`: everything it uses must come from this server or be inline (no CDN, no other host). The server hashes each
  inline `<script>` block of `index.html` as it serves it (the exact text between the tags), so only the page's own blocks run:
  **no inline event-handler attributes (`onclick="…"`), no `javascript:` URLs, no `eval`/`new Function`**; attach handlers from the
  script. Inline styles stay allowed.
- Every answer has `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer` and `X-Frame-Options: DENY`; API answers
  `Cache-Control: no-store`.
- A request from the Mac itself (loopback or any of its addresses) gets a short Spanish HTML page saying Nook Remote is for the
  phone, and nothing else. A connection from outside the home network is closed unread.
- Limits: 32 connections; 12 at once from an address a paired device used in the last 10 minutes and 4 from any other; new
  connections per address at most 60 (paired) or 12 (other) per 10 s; 6 event streams (one more closes the oldest); request head
  16 KB; a request must arrive whole within 10 s; an idle kept-alive connection closes after 30 s. The stream starts with
  `retry: 2000`.
