# Handover: IME Switching for Karabiner Config

## Branch: `feat/arc-ime-switching`

## What Was Done

### 1. Arc Address Bar IME Switching (partially working)
When pressing Cmd+T or Cmd+L in Arc browser, the system saves the current IME, switches to English (ABC), and passes the key through. On exit (Enter, Esc, Cmd+T/L again, or Caps Lock tap), it restores the previous IME.

**What's in the code:**
- Templates: `:ime-save`, `:ime-load`, `:ime-load-hud` in karabiner.edn
- Rule section: "Arc - IME switching for address bar"
- Caps Lock split into two rules (arc-bar-mode variant + default) to avoid Karabiner's "only last shell_command runs" conflict between `to_if_alone` and `to_after_key_up`
- Flag file `/tmp/karabiner-ime-active` guards against stale restores

**Known issue:** The restore uses macime's `--cjk-refresh` via the macimed daemon socket. This has a race condition — sometimes Zhuyin comes back but typing produces English or full-width English. This is the same fundamental CJK bug described below.

### 2. Cmd+Space Toggle (NOT working correctly yet)
Karabiner intercepts Cmd+Space and runs the `ime-switch` Swift helper to toggle between ABC and Zhuyin. A Karabiner variable `ime-english` tracks which IME is active.

**What's in the code:**
- Template: `:ime-switch` in karabiner.edn
- Rule section: "Cmd+Space → toggle IME" with two rules that flip `ime-english`
- Helper: `scripts/ime-switch.swift` (compiled to `scripts/ime-switch`)

**Current state:** The helper compiles and runs but the CJK initialization doesn't work without stealing window focus (see below).

## The Core Problem: macOS CJK Bug

`TISSelectInputSource()` — the API that ALL macOS IME switching tools use — has a bug with CJK input methods. It changes the indicator (menu bar shows 注音) but doesn't reliably initialize the internal typing mode (you type English).

This is a **known macOS bug** documented by Karabiner-Elements, macism, macime, and others. Every tool that uses this API has the same problem.

### The Window Trick (and why it needs focus)

The workaround: create a hidden text field, make it the first responder. This forces macOS to deliver the input source change to a real text context, initializing the CJK mode.

**The catch:** macOS only delivers input source events to the **active app's key window**. The helper must call `app.activate(ignoringOtherApps: true)` which steals focus from the user's current app. Without activation, the text field trick does nothing.

**What was tried:**
- `NSPanel` with `.nonactivatingPanel` — doesn't work (macOS doesn't deliver events)
- macime `--cjk-refresh` via daemon socket — race condition (TISSelectInputSource runs on background thread, CJK.refresh dispatches to main thread asynchronously, no synchronization)
- Two-step switch with delay — made things worse (first call locks in wrong CJK sub-mode)
- Setting system shortcuts programmatically — macOS cfprefsd blocks it

### The Two Viable Solutions

#### Option A: System Shortcut (recommended, fundamental fix)
Have the user manually enable "Select Previous Input Source" in **System Settings → Keyboard → Keyboard Shortcuts → Input Sources**. Then Karabiner sends that key combo. The native macOS switching pipeline properly initializes CJK modes — no race conditions, no focus steal.

Implementation: Karabiner rule sends F18 (or whatever key), system shortcut triggers native switch. One line in EDN, zero shell commands.

The blocker: couldn't set the system shortcut programmatically (cfprefsd overrides plist changes). **The user needs to enable it manually in System Settings.** They can set it to any key (F18 is ideal — no physical key, no app conflicts). Then Karabiner just sends F18.

The Karabiner rule would be:
```clojure
[:!Cspacebar [:f18 ["ime-english" 0]] ["ime-english" 1]]
[:!Cspacebar [:f18 ["ime-english" 1]] ["ime-english" 0]]
```

#### Option B: Focus steal with immediate restore
Use the `ime-switch` helper with `app.activate` (the version that works) but re-activate the previous app immediately after. The focus steal is ~150ms and the window is invisible (1x1 pixel, alpha 0.01). In `ime-switch.swift`, revert `switchWithCJKFix` to use `NSWindow` + `app.activate` + restore `frontApp` (the code is in git history).

## User's Broader Vision (not implemented yet)

The user wants Cmd+Space to behave like Raycast/Alfred's IME handling:

1. **Skip if already English** — if current IME is ABC, do nothing (no save, no state change)
2. **Save & restore for non-English** — save current CJK IME, switch to English, restore on exit
3. **Respect manual overrides** — if user presses Cmd+Space while in a "bar mode" (like Arc address bar), don't restore the saved IME on exit. The user took manual control.

For tracking "did the user manually change IME during bar mode": if ALL IME switching goes through Karabiner (Cmd+Space), a Karabiner variable (`ime-english`) stays in sync. The Arc bar exit rules can check this variable instead of blindly restoring.

## Files Changed

| File | What |
|------|------|
| `karabiner.edn` | Templates, Caps Lock split, Cmd+Space toggle, Arc bar mode rules |
| `scripts/ime-switch.swift` | Swift helper for IME toggle with CJK window trick |
| `scripts/ime-switch` | Compiled binary of above |

## Key Technical Details

- **macime CLI `load --session-id` bug**: Args.swift:136 validation requires `--save` flag. Workaround: route through macimed daemon socket (`echo 'ime load --session-id X --cjk-refresh' | nc -U /tmp/riodelphino.macimed.sock`) which bypasses validation.
- **Karabiner shell_command limitation**: Since v13.7.0, only the LAST `shell_command` in a `to` array runs. This applies across `to_if_alone` + `to_after_key_up` at key-up time. That's why Caps Lock is split into two rules.
- **macime session files**: Stored at `/tmp/riodelphino.macime/<session-id>`. Session ID `arc-bar` is used for Arc, isolated from nvim's `nvim-{pid}` sessions.
- **The `ime-english` variable**: Starts at 1 (assuming English). Flipped by Cmd+Space toggle. Can be used as condition in other rules.

## Research Sources

- macime source: `/tmp/macime/` (cloned from github.com/riodelphino/macime)
- macism source: was cloned to `/tmp/macism-repo/` during research
- InputSource Pro source: was cloned to `/tmp/InputSourcePro/` during research
- Key finding: InputSource Pro's CJKV fix simulates the system "Select Previous Input Source" shortcut — this is the most reliable approach found across all tools examined
