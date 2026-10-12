# Capture privacy (experimental)

Nook can ask macOS to exclude its windows from screen capture while keeping them visible on your own display. The setting is **off by default** and can be switched on or off under **Ajustes → Privacidad → Excluir Nook de las capturas**.

This is an experimental capture preference, not a guarantee that Nook is invisible to a recording or screen-sharing application. Compatibility depends on the macOS version and the capture path used by the receiving application.

## Scope

The feature targets Nook-owned visuals: the compact cat, expanded island, settings card, alert peeks, dragging cat, agent tooltip, and Nook's separate terminal mirror windows. Protection is applied before explicit windows are shown and refreshed as their geometry changes. Turning the setting off asks macOS to remove the exclusions.

Native menus, SwiftUI popovers, ordinary help tooltips, file pickers, and other transient or system-hosted panels have **best-effort coverage**. They may be created outside Nook's controlled presentation path; a first frame can appear before discovery. A successful exclusion request for the island does not establish protection for these other surfaces.

The setting does not hide:

- The original Terminal window, its tabs, or windows belonging to other applications.
- Nook or its child processes from Activity Monitor, `ps`, or other process inspection tools.
- macOS permission prompts, system UI, or the contents of an external terminal that you explicitly bring forward.

The menu-bar icon is hidden while the setting is enabled and restored when it is disabled. Settings remain accessible from the cat. Neither this nor Nook's normal background-app behavior hides its process.

## What has been verified

| Check | Result |
| --- | --- |
| Earlier private-API version, Google Meet in Microsoft Edge on macOS 27.0.1 | Nook's whole window, mostly transparent, was shared as a solid gray (128, 128, 128) block. Replaced on 2026-10-06. |
| Current sharing-type version, Google Meet in Microsoft Edge | **Not verified.** |
| Discord screen sharing, viewed by a remote participant | **Not verified.** |
| Microsoft Teams screen sharing, viewed by a remote participant | **Not verified.** |
| Every transient surface and every frame during animations or resizing | **Not guaranteed.** |

Unit tests confirm that Nook sets and clears the sharing type on its windows. They do not prove that a particular capture client honors it.

Before relying on this setting, use a second device or participant to inspect the received video. Check the collapsed and expanded island, resizing, cat dragging, alerts, settings, menus, popovers, and tooltips. Repeat after macOS or sharing-app updates. Testing the receiver's image matters more than what remains visible on your own screen.

## Implementation and distribution

Nook sets the public `NSWindow.sharingType` of each of its windows to `.none` while the setting is on, and back to `.readOnly` when it is off. This requests that capture clients omit the window; it does not establish that a particular recorder or screen-sharing app will honor the request.

An earlier version used the private WindowServer entry point `CGSSetWindowCaptureExcludeShape`. That call redacts rather than omits: macOS paints the excluded shape solid gray in screenshots and shares, so Nook's large transparent notch window showed up as a gray block. Nook no longer calls it.

Capture clients do not all honor the sharing type the same way. Some recorders (QuickTime among them, per [Apple Developer Forums thread 808016](https://developer.apple.com/forums/thread/808016)) have been reported to capture them anyway. Check the receiver's view in each app you use.

[Back to the README](../README.md)
