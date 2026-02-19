#!/usr/bin/env python3
"""Sort Arc's unpinned (Today) tabs by base domain, alphabetically."""

import subprocess
import time
from urllib.parse import urlparse


def osascript(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return r.stdout.strip()


def notify(msg):
    osascript(f'display notification "{msg}" with title "Arc Tab Sort"')


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


def select_and_pin(tab_id):
    """Select a tab and toggle its pin state in one AppleScript call."""
    osascript(f'''
        tell application "Arc"
            tell front window
                select (first tab whose id is "{tab_id}")
            end tell
        end tell
        tell application "System Events"
            tell process "Arc"
                click (first menu item of menu "Tabs" of menu bar 1 whose name contains "Pin")
            end tell
        end tell
    ''')


def main():
    tabs = get_unpinned_tabs()
    if len(tabs) <= 1:
        notify("Nothing to sort")
        return

    sorted_tabs = sorted(tabs, key=lambda t: t[2])  # by domain
    notify(f"Sorting {len(sorted_tabs)} tabs...")

    # Step 1: Pin all unpinned tabs (moves them out of Today)
    for tab_id, url, domain in sorted_tabs:
        select_and_pin(tab_id)

    # Step 2: Unpin in reverse alphabetical order
    # Each unpin places the tab at the TOP of Today,
    # so the last one unpinned (A) ends up on top → A-Z order
    for tab_id, url, domain in reversed(sorted_tabs):
        select_and_pin(tab_id)

    notify("Done!")


if __name__ == "__main__":
    main()
