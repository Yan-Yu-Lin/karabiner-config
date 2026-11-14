-- Toggle native macOS menu bar <-> SketchyBar (clean swap, no window shift).
-- Runs inside the KarabinerScripts daemon: the System Events call needs the
-- daemon's Automation grant (defaults write does not apply live).
-- AeroSpace's outer.top gap is measured from the BOTTOM of the menu bar, so
-- when the native bar (30px) appears the gap must shrink 40 -> 10 or every
-- tiled window gets pushed down by the bar height.
-- NOTE: aerospace.toml path must be the REAL repo file — BSD sed -i refuses
-- to edit through the ~/.config/aerospace symlink.
--
-- Ordering matters (anti-jitter): the moment auto-hide flips, AeroSpace
-- re-layouts with its OLD in-memory gap — windows sit ~30px wrong until our
-- reload-config lands. So: pre-stage the toml BEFORE the flip, reload-config
-- IMMEDIATELY after, and do the cosmetic SketchyBar swap last.

-- Lock: a run takes ~500ms; overlapping runs race the sed/sketchybar calls
-- and scramble state, so extra triggers are skipped. Stale locks (>5s, e.g.
-- from a crashed run) are cleared first.
do shell script "find /tmp/.menubar-toggle.lock -maxdepth 0 -mtime +5s -exec rmdir {} \\; 2>/dev/null; true"
set gotLock to do shell script "mkdir /tmp/.menubar-toggle.lock 2>/dev/null && echo ok || echo busy"
if gotLock is "busy" then return "skipped (busy)"

try
	tell application "System Events" to set wasHidden to autohide menu bar of dock preferences
	if wasHidden then
		-- going to: native bar VISIBLE
		do shell script "/usr/bin/sed -i '' 's/}, 40]/}, 10]/' $HOME/karabiner-config/aerospace.toml"
		tell application "System Events" to set autohide menu bar of dock preferences to false
		do shell script "/opt/homebrew/bin/aerospace reload-config; /opt/homebrew/opt/sketchybar/bin/sketchybar --bar hidden=on; /opt/homebrew/bin/sketchybar_row2 --bar hidden=on"
	else
		-- going to: native bar HIDDEN, SketchyBar back
		do shell script "/usr/bin/sed -i '' 's/}, 10]/}, 40]/' $HOME/karabiner-config/aerospace.toml"
		tell application "System Events" to set autohide menu bar of dock preferences to true
		do shell script "/opt/homebrew/bin/aerospace reload-config; /opt/homebrew/opt/sketchybar/bin/sketchybar --bar hidden=off; /opt/homebrew/bin/sketchybar_row2 --bar hidden=off"
	end if
	do shell script "rmdir /tmp/.menubar-toggle.lock 2>/dev/null; true"
on error errMsg
	do shell script "rmdir /tmp/.menubar-toggle.lock 2>/dev/null; true"
	error errMsg
end try
