#!/usr/bin/env python3
"""Pin Music Assistant's published stream address into settings.json.

Runs as ExecStartPre for music-assistant.service, before MA reads its config.

WHY THIS EXISTS
---------------
MA's `publish_ip` (streams, :8097) and `base_url` (webserver, :8095) default to
`ip_addresses[0]` -- the *first enumerated* interface address, evaluated live.
rivendell has eth0 (10.0.1.9, LAN) and eth0.4 (10.0.12.2, IoT VLAN), and on a
cold boot MA can start before eth0 finishes DHCP, so the static VLAN address
sorts first. MA then advertises stream URLs on an interface no player can reach.

That breaks exactly the *pull-based* players (WiiM/DLNA/Chromecast fetch an
MA-advertised URL) and leaves *push-based* ones (AirPlay) working, with no error
in the UI or the log -- MA has no feedback channel for "device could not fetch".
Observed 2026-08-09: every WiiM hung silently in LinkPlay `status: "load"`.

WHY NOT JUST SAVE IT VIA THE API
--------------------------------
Because that silently does nothing. `Config.to_raw`
(music_assistant_models/config_entries.py:362) persists a value only

    if x.value != x.default_value

so saving the correct IP at a moment when the default *already* computed to the
correct IP stores nothing at all -- and the next boot is free to race the other
way. `Config.parse` on the other hand applies any stored value unconditionally,
so writing the key straight into settings.json is what actually pins it.

Rewriting on every start is deliberate: MA may strip the key again on its own
next save (same to_raw rule), which is harmless within a boot but means the file
cannot be treated as write-once.

Never fails the unit -- a broken pin must not stop music from starting.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile


def main() -> int:
    if len(sys.argv) != 4:
        print(f"usage: {sys.argv[0]} <settings.json> <publish_ip> <base_url>", file=sys.stderr)
        return 0

    path, publish_ip, base_url = sys.argv[1], sys.argv[2], sys.argv[3]

    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as fh:
                settings = json.load(fh)
        except (OSError, ValueError) as err:
            # Corrupt or unreadable: leave it entirely alone. MA owns this file
            # and recovers from settings.json.backup; clobbering it here would
            # turn a bad publish IP into a lost configuration.
            print(f"ma-publish-ip: cannot read {path} ({err}); leaving unchanged", file=sys.stderr)
            return 0
    else:
        # First boot / fresh state dir. A bare core block is valid input for
        # Config.parse; MA fills in everything else during onboarding.
        settings = {}

    if not isinstance(settings, dict):
        print("ma-publish-ip: settings.json is not an object; leaving unchanged", file=sys.stderr)
        return 0

    core = settings.setdefault("core", {})
    if not isinstance(core, dict):
        print("ma-publish-ip: core is not an object; leaving unchanged", file=sys.stderr)
        return 0

    # {"domain": <name>, "values": {...}} is the on-disk shape MA writes.
    wanted = {"streams": ("publish_ip", publish_ip), "webserver": ("base_url", base_url)}

    changed = False
    for domain, (key, value) in wanted.items():
        entry = core.setdefault(domain, {"domain": domain, "values": {}})
        if not isinstance(entry, dict):
            print(f"ma-publish-ip: core.{domain} is not an object; skipping", file=sys.stderr)
            continue
        entry.setdefault("domain", domain)
        values = entry.setdefault("values", {})
        if not isinstance(values, dict):
            print(f"ma-publish-ip: core.{domain}.values is not an object; skipping", file=sys.stderr)
            continue
        if values.get(key) != value:
            values[key] = value
            changed = True

    if not changed:
        print(f"ma-publish-ip: already pinned to {publish_ip}", file=sys.stderr)
        return 0

    # Atomic replace within the same directory, so a crash mid-write cannot
    # leave MA with a truncated settings.json.
    directory = os.path.dirname(path) or "."
    try:
        fd, tmp = tempfile.mkstemp(dir=directory, prefix=".settings.json.")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(settings, fh, indent=4)
                fh.flush()
                os.fsync(fh.fileno())
            if os.path.exists(path):
                os.chmod(tmp, os.stat(path).st_mode & 0o7777)
            os.replace(tmp, path)
        except BaseException:
            os.unlink(tmp)
            raise
    except OSError as err:
        print(f"ma-publish-ip: failed to write {path} ({err})", file=sys.stderr)
        return 0

    print(f"ma-publish-ip: pinned publish_ip={publish_ip} base_url={base_url}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
