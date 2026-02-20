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
| AppleScript files | `~/karabiner-config/scripts/*.applescript` |
| HUD source | `~/Library/Scripts/karabiner-hud/hud.swift` |
| HUD app bundle | `~/Library/Scripts/karabiner-hud/KarabinerHUD.app` |
| HUD modes config | `~/Library/Scripts/karabiner-hud/modes.json` |
| HUD LaunchAgent | `~/Library/LaunchAgents/com.user.karabiner-hud.plist` |
| HUD log | `/tmp/karabiner-hud.log` |
| HUD FIFO | `/tmp/karabiner-hud.fifo` |

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
  "arc-next-space":   {"app": "Arc", "menu": ["Spaces", "Next Space"]},
  "arc-prev-space":   {"app": "Arc", "menu": ["Spaces", "Previous Space"]},
  "inline-script":    {"applescript": "tell application \"Finder\" to activate"},
  "file-script":      {"applescript_file": "my-script.applescript"},
  "some-command":     {"shell": "open 'cleanshot://capture-area'"},
  "legacy-compat":    "open 'some://url'"
}
```

- `menu`: Fast path (~20ms). Walks the app's menu bar via AX API. Needs the exact menu item names.
- `applescript`: Inline string. Pre-compiled at daemon startup. First execution ~2s (cold), subsequent ~130ms.
- `applescript_file`: Loads from `~/karabiner-config/scripts/<filename>`. Same speed as inline, but you write real multi-line AppleScript in a proper file. Relative paths resolve to the scripts dir; absolute paths work too.
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

### Hyper Key (Right Command)

Right Command is remapped to Cmd+Ctrl+Opt (hyper). This is a global mapping — all apps see these three modifiers when Right Command is held.

```clojure
[:##right_command :!TOleft_command]
```

Hyper shortcuts are configured **in the target app** (e.g., Raycast extension hotkeys), not as Karabiner shell commands. This gives native-speed hotkey response (~instant) vs deep link URL schemes (~300ms).

To restrict a hyper shortcut to specific apps, use the **app-gating pattern**: swallow the key everywhere except the target app, so the target app's native hotkey listener catches it.

```clojure
;; Block Hyper+A everywhere EXCEPT Arc and Raycast
;; :!arc = frontmost_application_unless (negated condition)
[:!CTOa :vk_none [:!arc :!raycast]]
```

When adding a new app-gated hyper shortcut:
1. Configure the hotkey in the target app (e.g., Raycast → Extensions → set Cmd+Ctrl+Opt+KEY)
2. Add a blocking rule in "Hyper gates" section for all other apps
3. Include both the target app AND any app that might be frontmost during interaction (e.g., Raycast floats over Arc)

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

### Arc (per-app, via daemon)
Only active when Arc is frontmost. Uses `:kb` template → daemon FIFO.

- **Caps + J/K** — Switch spaces. AX menu clicks (~20ms).
- **Caps + S** — Sort unpinned (Today) tabs alphabetically by base domain. Runs `scripts/sort-arc-tabs.py` via daemon shell action.
- **Hyper + A** — Raycast Arc search. App-gated: configured as Raycast extension hotkey (Cmd+Ctrl+Opt+A), blocked by Karabiner when not in Arc/Raycast.

#### How tab sorting works
Arc has no reorder/move API for tabs. The trick: pin all unpinned tabs (moves them out of Today), then unpin them in reverse alphabetical order (each lands at top of Today → A-Z result). Uses batched AppleScript — one `osascript` call per pass, not per tab. ~3s for ~17 tabs.

**AX API won't work here.** Tested and failed — the Accessibility framework can't handle rapid-fire menu clicks (works for ~3 clicks then silently fails). System Events via AppleScript is slower per-click but reliable for batch operations.

## The HUD: KarabinerHUD

A floating overlay that shows the current mode and available keys. Separate from the daemon — zero permissions needed, safe to recompile anytime.

### What it does

- Shows a translucent panel at bottom-center of screen when a mode activates
- Lists available keys for the current mode
- App-aware: shows extra keys based on frontmost app (e.g., Arc-specific keys in Caps mode)
- Opens URLs via `NSWorkspace` without stealing focus (`activates = false`)
- Auto-hides after 8 seconds (safety net for stuck variables)

### FIFO commands

```bash
echo 'show caps' > /tmp/karabiner-hud.fifo       # Show mode HUD
echo 'hide' > /tmp/karabiner-hud.fifo             # Always hide
echo 'hide caps' > /tmp/karabiner-hud.fifo        # Hide only if showing "caps"
echo 'url cleanshot://capture-area' > /tmp/karabiner-hud.fifo  # Open URL without focus steal
```

Conditional hide (`hide <mode>`) prevents sub-modes from being dismissed when Caps Lock is released. Caps afterup sends `hide caps` — ignored if HUD is showing a sub-mode like "window".

### modes.json

External config for HUD content. Edit and `kill -HUP $(pgrep -f KarabinerHUD)` to reload without recompile. Supports per-app extra keys via bundle IDs.

### Managing the HUD

```bash
# Reload modes.json
kill -HUP $(pgrep -f KarabinerHUD)

# Recompile (safe — no permissions to lose)
cd ~/Library/Scripts/karabiner-hud
swiftc -O -o KarabinerHUD.app/Contents/MacOS/KarabinerHUD hud.swift
codesign --force --sign - KarabinerHUD.app
launchctl kickstart -k gui/$(id -u)/com.user.karabiner-hud
```

### Key Karabiner gotcha: only last shell_command executes

Since Karabiner-Elements v13.7.0, if a rule's `to` array has multiple `shell_command` items, only the LAST one runs. Combine commands into a single string:

```clojure
;; WRONG — CleanShot URL silently dropped, only HUD hide runs
[:c [[:cleanshot "capture-area"] ["cleanshot-mode" 0] [:hud "hide"]] conditions]

;; CORRECT — bake hide into the :cleanshot template itself
:cleanshot "open -g 'cleanshot://%s' ; echo 'hide' > /tmp/karabiner-hud.fifo"
```

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
| App-gated hotkey (Raycast native) | ~instant | App shortcuts via hyper key |
| AX API (daemon `menu`) | ~20ms | Menu clicks, button presses |
| HUD FIFO → NSWorkspace.open | ~20ms | URL schemes without focus steal |
| NSAppleScript (daemon `applescript`) | ~130ms warm | App scripting, complex automation |
| Shell command (daemon `shell`) | ~50ms + cmd | URL schemes, CLI tools |
| `open -g` via shell_command | ~300ms | URL schemes (shell spawn overhead) |
| Deep link URL schemes (Raycast) | ~300ms+ | Avoid — use native hotkeys instead |
| Raw osascript (no daemon) | ~145ms | Fallback |
| Old chain (helper→jq→osascript) | ~400ms | Don't use this |
