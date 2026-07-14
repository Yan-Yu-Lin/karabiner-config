# KarabinerHUD — source backup

The live files run from `~/Library/Scripts/karabiner-hud/` (outside this repo).
This directory is a **version-controlled backup** of the editable source, so the
HUD can be rebuilt if the live copy is lost.

- `hud.swift` — the overlay app source
- `modes.json` — mode/key definitions + per-app overrides (supports `path:` regex
  matching for bundle-id-less apps like Minecraft's Java process, and `replace`
  key lists in addition to `extra`)

## Restore / rebuild
```bash
cp hud.swift modes.json ~/Library/Scripts/karabiner-hud/
cd ~/Library/Scripts/karabiner-hud
swiftc -O -o KarabinerHUD.app/Contents/MacOS/KarabinerHUD hud.swift
codesign --force --sign - KarabinerHUD.app
launchctl bootout gui/$(id -u)/com.user.karabiner-hud 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.karabiner-hud.plist
```
Safe to recompile — the HUD needs no TCC permissions (unlike KarabinerScripts).
