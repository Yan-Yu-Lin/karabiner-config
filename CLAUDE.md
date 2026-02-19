# Karabiner Config

## Overview

Karabiner-Elements keyboard customization with Goku EDN config and a custom Swift daemon for fast action execution.

**Core idea:** Caps Lock is the master key. Hold Caps → tap a key to enter a mode or trigger an action. Modes can be one-shot (fire and exit) or hold-based (persist while key held).

## Files & Locations

| What | Where |
|------|-------|
| EDN config (source of truth) | `~/karabiner-config/karabiner.edn` |
| Symlink Goku watches | `~/.config/karabiner.edn` → above |
| Compiled JSON (never edit) | `~/.config/karabiner/karabiner.json` |
| Daemon source | `~/Library/Scripts/karabiner-scripts/daemon.swift` |
| Daemon app bundle | `~/Library/Scripts/karabiner-scripts/KarabinerScripts.app` |
| Actions config | `~/Library/Scripts/karabiner-scripts/actions.json` |
| LaunchAgent | `~/Library/LaunchAgents/com.user.karabiner-scripts.plist` |
| Daemon log | `/tmp/karabiner-scripts.log` |
| FIFO (IPC pipe) | `/tmp/karabiner-scripts.fifo` |
| Legacy helper (unused) | `~/Applications/KarabinerHelper.app` (can delete) |
| Legacy trigger (unused) | `~/Library/Scripts/karabiner-scripts/kbtrigger` (can delete) |

## The Daemon: KarabinerScripts

A persistent Swift daemon that executes actions triggered by Karabiner via a named pipe (FIFO). It stays running, so there's zero startup overhead per keypress.

### Why it exists

AppleScript via `osascript` is slow (~300-500ms) because every keypress spawns a new process, compiles the script, and connects to System Events. The daemon pre-compiles scripts and keeps connections warm.

### Three action types

1. **`menu`** — Uses Accessibility API (AX) to click menu items directly. ~20-30ms. No AppleScript involved.
2. **`applescript`** — Pre-compiled NSAppleScript executed in-process. ~130ms warm.
3. **`shell`** — Runs a shell command (for URL schemes, CLI tools, scripts). Fire-and-forget.

### actions.json format

```json
{
  "arc-next-space":  {"app": "Arc", "menu": ["Spaces", "Next Space"]},
  "arc-prev-space":  {"app": "Arc", "menu": ["Spaces", "Previous Space"]},
  "some-applescript": {"applescript": "tell application \"Finder\" to activate"},
  "some-command":    {"shell": "open 'cleanshot://capture-area'"},
  "legacy-compat":   "open 'some://url'"
}
```

- `menu`: Fast path. Walks the app's menu bar via AX API. Needs the exact menu item names.
- `applescript`: Pre-compiled at daemon startup. First execution is slow (~2s, cold), subsequent ~130ms.
- `shell`: Spawns `/bin/sh -c "command"`. Good for URL schemes and CLI tools.
- Plain string: Treated as shell command (backwards compat).

### How Karabiner triggers actions

The EDN template `:kb` writes an action name to the FIFO:
```clojure
:kb "echo '%s' > /tmp/karabiner-scripts.fifo &"
```
The `&` prevents blocking if the daemon is down.

### Managing the daemon

```bash
# Check log
tail -f /tmp/karabiner-scripts.log

# Reload actions.json without restart (after editing actions)
kill -HUP $(pgrep -f KarabinerScripts)

# Restart daemon
launchctl kickstart -k gui/$(id -u)/com.user.karabiner-scripts

# Stop
launchctl bootout gui/$(id -u)/com.user.karabiner-scripts

# Start
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.karabiner-scripts.plist
```

### Permissions (IMPORTANT)

The daemon needs TWO macOS permissions (System Settings → Privacy & Security):

1. **Accessibility** — for AX menu clicks. Add `KarabinerScripts.app` to the Accessibility list.
2. **Automation** — for AppleScript (NSAppleScript → System Events). A popup appears on first AppleScript execution; click Allow.

**DO NOT recompile the daemon unless absolutely necessary.** Recompiling + re-signing invalidates both permissions and the user must re-add the app to Accessibility manually. To add new actions, just edit `actions.json` and send SIGHUP.

If you must recompile:
```bash
cd ~/Library/Scripts/karabiner-scripts
swiftc -O -o KarabinerScripts.app/Contents/MacOS/KarabinerScripts daemon.swift
codesign --force --sign - KarabinerScripts.app
# Then user must re-add to Accessibility in System Settings
# Then restart daemon — first AppleScript call will re-trigger Automation popup
```

### How we got here (the permission saga)

1. **First attempt**: Karabiner → shell → osascript. Worked but slow (~400ms per action).
2. **Daemon with NSAppleScript**: Fast but couldn't get Automation permission popup to appear. `LSBackgroundOnly` in Info.plist suppressed all UI including consent dialogs.
3. **Changed to `LSUIElement`**, code-signed, reset TCC — popup still didn't appear.
4. **Daemon with osascript subprocess**: "osascript is not allowed assistive access" — different permission (Accessibility), and the daemon process didn't inherit terminal permissions.
5. **Shell script trigger (kbtrigger)**: Worked (Karabiner's shell context has permissions) but slow — spawns bash + jq + osascript.
6. **AX API approach**: Direct Accessibility framework calls for menu clicking. Only needs Accessibility permission (no Automation). 20ms per action. THIS WORKED.
7. **Combined daemon**: AX for menus + NSAppleScript for complex scripts. After getting Accessibility permission stable, the Automation popup finally appeared on the next AppleScript call. Both permissions granted.

**Key lesson**: macOS TCC is per-code-signature. Ad-hoc signing (`codesign --sign -`) generates a new identity each time. Every recompile = new identity = permissions reset. Keep the binary stable.

## EDN Config Structure

### Goku EDN gotcha: double-wrap multiple `to` items

```clojure
;; WRONG — variable set silently dropped
[:c [:cleanshot "capture-area" ["cleanshot-mode" 0]] conditions]

;; CORRECT — two separate to items
[:c [[:cleanshot "capture-area"] ["cleanshot-mode" 0]] conditions]
```

### Manual layer pattern (not Goku :layers)

We use manual variable manipulation instead of Goku's `:layers` auto-generation. This lets Caps Lock reset ALL sub-mode variables on press (universal escape hatch).

When adding a new sub-layer:
1. Add variable reset in Caps Lock master rule: `["new-mode" 0]`
2. Add entry rule in "Caps mode - sub-layer entries"
3. Add action rules in a new section
4. Choose: one-shot (reset mode in each action) or hold-based (`{:afterup ["mode" 0]}` on entry key)

### Per-app rules

```clojure
;; Define app in :applications
:applications {:arc ["^company\\.thebrowser\\.Browser$"]}

;; Use as condition — rule only fires in that app
[:j [:kb "arc-next-space"] ["caps-mode" 1] :arc]
```

### Emergency fix for stuck variables

```bash
/opt/homebrew/bin/karabiner_cli --set-variables '{"cleanshot-mode": 0, "window-mode": 0, "resize-mode": 0, "caps-mode": 0}'
```

## Modifier Shorthand

```
!  = mandatory   #  = optional
C  = left_command    Q  = right_command
T  = left_control    W  = right_control
O  = left_option     E  = right_option
S  = left_shift      R  = right_shift
F  = fn              P  = caps_lock
!! = hyper (cmd+ctrl+opt+shift)
## = optional any
```

## Current Layers

### CleanShot (Caps + C → one-shot)
URL scheme via `:cleanshot` template. Keys: C=area, A=annotate, V=pin, P=previous, F=fullscreen, W=window, S=scroll, T=OCR, R=record, H=history.

### Window/AeroSpace (Caps + hold W → hold-based)
CLI via `:aero` template. H/J/K/L=focus, Shift+HJKL=move, F=fullscreen, B=balance, 1-9=workspace, Shift+1-9=move-to-workspace. R=resize sub-mode.

### Arc (Caps + J/K — per-app, via daemon)
AX menu clicks via `:kb` template → daemon FIFO. J=Next Space, K=Previous Space. Only active when Arc is frontmost.

## App Automation Discovery

```bash
# AppleScript dictionary (commands an app exposes)
sdef /Applications/AppName.app
sdef /Applications/AppName.app | grep '<command '

# URL schemes
plutil -p "/Applications/AppName.app/Contents/Info.plist" | grep -A3 "URLSchemes"

# Menu items (via System Events)
osascript -e 'tell application "System Events" to get name of every menu item of menu "MenuName" of menu bar 1 of process "AppName"'
```

## Speed Reference

| Method | Latency | Use case |
|--------|---------|----------|
| AX API (daemon `menu`) | ~20ms | Menu clicks, button presses |
| NSAppleScript (daemon `applescript`) | ~130ms warm | App scripting, complex automation |
| Shell command (daemon `shell`) | ~50ms + cmd | URL schemes, CLI tools |
| Raw osascript (no daemon) | ~145ms | Fallback |
| Old chain (helper→jq→osascript) | ~400ms | Don't use this |
