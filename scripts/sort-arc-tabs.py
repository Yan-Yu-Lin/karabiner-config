#!/usr/bin/env python3
"""Sort Arc's unpinned (Today) tabs by base domain, alphabetically."""

import subprocess
from urllib.parse import urlparse


def osascript(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return r.stdout.strip()


def get_unpinned_tabs():
    """Return list of (id, url, domain) for unpinned tabs in the active space."""
    raw = osascript('''
        tell application "Arc"
            tell active space of front window
                set allIds to id of every tab
                set allURLs to URL of every tab
                set allLocs to location of every tab
                set AppleScript's text item delimiters to linefeed
                return (allIds as text) & "\\n===\\n" & (allURLs as text) & "\\n===\\n" & (allLocs as text)
            end tell
        end tell
    ''')
    sections = raw.split("\n===\n")
    ids = sections[0].split("\n")
    urls = sections[1].split("\n")
    locs = sections[2].split("\n")

    tabs = []
    for tab_id, url, loc in zip(ids, urls, locs):
        if loc.strip() == "unpinned":
            domain = urlparse(url.strip()).netloc.lower().removeprefix("www.")
            tabs.append((tab_id.strip(), url.strip(), domain))
    return tabs


def build_sort_script(sorted_ids):
    """Generate one AppleScript that does all select+pin operations."""
    blocks = []
    for tab_id in sorted_ids:
        blocks.append(f'''
        tell application "Arc"
            tell front window
                select (first tab whose id is "{tab_id}")
            end tell
        end tell
        tell application "System Events"
            tell process "Arc"
                click (first menu item of menu "Tabs" of menu bar 1 whose name contains "Pin")
            end tell
        end tell''')
    return "\n".join(blocks)


def main():
    tabs = get_unpinned_tabs()
    if len(tabs) <= 1:
        osascript('display notification "Nothing to sort" with title "Arc Tab Sort"')
        return

    sorted_tabs = sorted(tabs, key=lambda t: t[2])  # by domain
    osascript(f'display notification "Sorting {len(sorted_tabs)} tabs..." with title "Arc Tab Sort"')

    # Pin all, then unpin in reverse order — all in two osascript calls
    pin_ids = [t[0] for t in sorted_tabs]
    unpin_ids = [t[0] for t in reversed(sorted_tabs)]

    osascript(build_sort_script(pin_ids))      # pin all
    osascript(build_sort_script(unpin_ids))     # unpin in reverse

    osascript('display notification "Done!" with title "Arc Tab Sort"')


if __name__ == "__main__":
    main()
