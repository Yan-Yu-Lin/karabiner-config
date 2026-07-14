#!/bin/bash
# Restore the Karabiner device settings that keep Arthur's mouse working and silence a
# phantom-keyboard event flood. These live ONLY in ~/.config/karabiner/karabiner.json
# (Karabiner's GUI "Devices" tab — they cannot be expressed in karabiner.edn/goku), so a
# Karabiner reset or a fresh karabiner.json wipes them. Symptoms if lost:
#   - mouse buttons do nothing in apps that rely on Karabiner (e.g. MCBridge)
#   - /var/log/karabiner/core_service.log floods with
#     "drop unmatched momentary switch key_up ..." (tens of lines/sec)
# Cause: the Logitech USB receiver's product_id can differ per receiver; Karabiner only
# modifies pointing devices it is told to, and the receiver's phantom keyboard interface
# spews junk key-up events unless ignored.
#
# This script is idempotent: it merges the required entries into the selected profile's
# "devices" array without disturbing anything else. Re-run any time the mouse breaks.
set -euo pipefail
CONFIG="$HOME/.config/karabiner/karabiner.json"

python3 - "$CONFIG" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
prof = next(p for p in cfg["profiles"] if p.get("selected"))
devs = prof.setdefault("devices", [])

def ident(d):
    i = d["identifiers"]
    return (i.get("vendor_id"), i.get("product_id"), i.get("is_keyboard", False), i.get("is_pointing_device", False))

# vendor 1133 = Logitech. Both receiver product_ids seen on this Mac (50495, 50503):
#   pointing interface -> modified (ignore=False), keyboard interface -> ignored (flood).
# vendor 1452/pid 34304 = Apple TouchBar keyboard -> ignored.
required = [
    {"identifiers": {"vendor_id": 1133, "product_id": 50495, "is_pointing_device": True}, "ignore": False},
    {"identifiers": {"vendor_id": 1133, "product_id": 50495, "is_keyboard": True}, "ignore": True},
    {"identifiers": {"vendor_id": 1133, "product_id": 50503, "is_pointing_device": True}, "ignore": False},
    {"identifiers": {"vendor_id": 1133, "product_id": 50503, "is_keyboard": True}, "ignore": True},
    {"identifiers": {"vendor_id": 1452, "product_id": 34304, "is_keyboard": True}, "ignore": True},
]
existing = {ident(d) for d in devs}
added = 0
for r in required:
    if ident(r) not in existing:
        devs.append(r); added += 1
    else:
        for d in devs:
            if ident(d) == ident(r):
                d["ignore"] = r["ignore"]
json.dump(cfg, open(path, "w"), indent=4)
print(f"restored device entries ({added} added, {len(required)} enforced)")
PY
echo "Karabiner will pick up the change within a second (it watches the file)."
