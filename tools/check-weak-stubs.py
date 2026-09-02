#!/usr/bin/env python3
#
# Copyright (c) 2026 EKS Inc.
# Created by Ryu.
# SPDX-License-Identifier: LicenseRef-EKS-NonCommercial-1.0
#
"""Fail if led_breath.c's __weak fallbacks ended up in the firmware.

led_breath.c declares __weak stubs for a handful of ZMK functions so that a
half which does not provide them still links. The catch is that a rename
upstream produces exactly the same situation: the real symbol disappears, the
stub links in its place, the build succeeds, and the only sign is the status
LED reporting the wrong thing. There is no error and no warning.

The linker map does record it, though. A stub that lost the race is listed
under "Discarded input sections"; one that was actually used appears in the
real layout further down with an address. So the invariant is simply:

    led_breath.c.obj must never provide any of these symbols in the final image.

Usage:
    tools/check-weak-stubs.py <zmk.map> [<zmk.map> ...]
"""

import re
import sys

# The __weak declarations at the top of led_breath.c.
WEAK_SYMBOLS = (
    "zmk_ble_active_profile_index",
    "zmk_ble_active_profile_is_open",
    "zmk_split_bt_peripheral_is_connected",
    "zmk_split_bt_peripheral_is_bonded",
)

STUB_OBJECT = "led_breath.c.obj"
DISCARDED_HEADING = "Discarded input sections"
LAYOUT_HEADING = "Linker script and memory map"


def check(path):
    """Return (ok, lines) for one map file."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().split("\n")
    except OSError as err:
        return False, [f"  cannot read: {err}"]

    layout_at = None
    for i, line in enumerate(lines):
        if line.startswith(LAYOUT_HEADING):
            layout_at = i
            break

    if layout_at is None:
        # Without the heading we cannot tell discarded from linked, and
        # answering "fine" from a file we failed to parse is the one outcome
        # worth avoiding.
        return False, [f'  no "{LAYOUT_HEADING}" heading - not a linker map?']

    if not any(line.startswith(DISCARDED_HEADING) for line in lines[:layout_at]):
        return False, [f'  no "{DISCARDED_HEADING}" section - was the map built with --gc-sections?']

    report, ok = [], True
    for symbol in WEAK_SYMBOLS:
        section = re.compile(r"^\s*\.text\.%s$" % re.escape(symbol))
        stub_linked = False
        provider = None

        for i, line in enumerate(lines):
            if not section.match(line):
                continue
            # The provider is named on this line or the one after it, depending
            # on how far the section name pushed the columns.
            body = line + " " + (lines[i + 1] if i + 1 < len(lines) else "")
            from_stub = STUB_OBJECT in body
            if i > layout_at:
                if from_stub:
                    stub_linked = True
                elif provider is None:
                    match = re.search(r"(\S+\.obj\)?)", body)
                    provider = match.group(1) if match else "?"

        if stub_linked:
            ok = False
            report.append(f"  FAIL {symbol}: the __weak stub is in the image")
        elif provider:
            report.append(f"  ok   {symbol} <- {provider}")
        else:
            # Neither half uses every symbol: the central compiles out the
            # peripheral branch and vice versa, so the stub is discarded and no
            # real definition is pulled in. That is the healthy case too.
            report.append(f"  ok   {symbol} (unused on this half)")

    return ok, report


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().split("Usage:")[1].strip(), file=sys.stderr)
        return 2

    failed = False
    for path in argv[1:]:
        ok, report = check(path)
        print(f"{path}:")
        print("\n".join(report))
        failed |= not ok

    if failed:
        print(
            "\nA __weak stub from led_breath.c was linked into the firmware.\n"
            "ZMK most likely renamed or removed the real symbol. The build will\n"
            "still run and the keymap will be fine; the status LED will not be.",
            file=sys.stderr,
        )
        return 1

    print("\nAll __weak stubs discarded.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
