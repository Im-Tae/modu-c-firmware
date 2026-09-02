#!/usr/bin/env bash
#
# Copyright (c) 2026 EKS Inc.
# Created by Ryu.
# SPDX-License-Identifier: LicenseRef-EKS-NonCommercial-1.0
#
# Builds modu_left.uf2 and modu_right.uf2 on macOS or Linux using Docker, so
# no local Zephyr SDK is needed. The ZMK workspace is set up on the first run
# and reused afterwards.
#
#   ./build.sh              build both halves
#   ./build.sh modu_left    build one half
#   ./build.sh --clean      discard the ZMK workspace and start over

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${MODU_ZMK_WORKSPACE:-$REPO_ROOT/.zmk-workspace}"
OUTPUT_DIR="${MODU_OUTPUT_DIR:-$REPO_ROOT/outputs}"
IMAGE="${MODU_ZMK_IMAGE:-zmkfirmware/zmk-build-arm:stable}"
BOARD="ms88sf3/nrf52840"

# The ZMK revision this firmware is known to build against.
#
# Pinned on purpose. led_breath.c reaches into ZMK internals that are not part
# of any public API - `active_transport`, and the `__weak` fallbacks for
# zmk_ble_active_profile_index() and friends. If upstream renames one of those,
# the weak stub links instead and the build still succeeds; the only symptom is
# the status LED showing the wrong thing. Tracking a moving `main` would let
# that happen silently between two builds of unchanged source.
#
# To try a newer ZMK without disturbing the workspace that currently works:
#
#   MODU_ZMK_WORKSPACE=.zmk-test MODU_ZMK_REV=main ./build.sh
#
# If both halves build and the LED still behaves, bump the default below to
# that revision in its own commit.
ZMK_REV="${MODU_ZMK_REV:-641514a97db345f499dd50b0360e594270f008fe}"

if [ "${1:-}" = "--clean" ]; then
    echo "Removing $WORKSPACE"
    rm -rf "$WORKSPACE"
    exit 0
fi

shields=("$@")
if [ ${#shields[@]} -eq 0 ]; then
    shields=(modu_left modu_right)
fi

if ! docker info >/dev/null 2>&1; then
    echo "Docker is not running. Start Docker Desktop and try again." >&2
    exit 1
fi

run_in_container() {
    docker run --rm \
        -v "$WORKSPACE:/ws" \
        -v "$REPO_ROOT:/modu" \
        -w "$1" \
        "$IMAGE" \
        bash -lc "$2"
}

# First run: fetch ZMK and everything Zephyr needs. Takes a while and pulls
# down a few GB; everything lands in $WORKSPACE so later runs skip this.
if [ ! -d "$WORKSPACE/zmk/zephyr" ]; then
    echo "==> Setting up the ZMK workspace in $WORKSPACE (first run only)"
    mkdir -p "$WORKSPACE"
    if [ ! -d "$WORKSPACE/zmk" ]; then
        # Fetch just the pinned revision. GitHub serves an arbitrary SHA to a
        # depth-1 fetch, so this stays as cheap as the shallow clone it replaces.
        echo "==> Fetching ZMK at $ZMK_REV"
        git init --quiet "$WORKSPACE/zmk"
        git -C "$WORKSPACE/zmk" remote add origin https://github.com/zmkfirmware/zmk.git
        git -C "$WORKSPACE/zmk" fetch --depth 1 origin "$ZMK_REV"
        git -C "$WORKSPACE/zmk" checkout --quiet FETCH_HEAD
    fi
    run_in_container /ws 'west init -l zmk/app'
    run_in_container /ws/zmk 'west update --narrow -o=--depth=1 && west zephyr-export'
fi

mkdir -p "$OUTPUT_DIR"

for shield in "${shields[@]}"; do
    echo "==> Building $shield"

    # ZMK Studio talks over a USB CDC-ACM endpoint that only this snippet
    # creates, and only the central answers it (ZMK gates the RPC on
    # ZMK_SPLIT_ROLE_CENTRAL). Building the peripheral with it would add the
    # USB stack to a half that never uses it.
    snippet_name=""
    if [ "$shield" = "modu_left" ]; then
        snippet_name="studio-rpc-usb-uart"
    fi

    snippet_arg=""
    if [ -n "$snippet_name" ]; then
        snippet_arg="-S $snippet_name"
    fi

    # Changing the snippet set on an existing build dir is only a *warning* in
    # Zephyr - it keeps the cached value, ignores the new one and builds
    # anyway. Here that produced a Studio build with no USB endpoint at all
    # (it fell back to the BLE transport) and still exited 0. Compare against
    # the cache ourselves and force a pristine build when they differ.
    prune="auto"
    cache="$WORKSPACE/build/$shield/CMakeCache.txt"
    if [ -f "$cache" ] &&
       [ "$(sed -n 's/^CACHED_SNIPPET:STRING=//p' "$cache")" != "$snippet_name" ]; then
        echo "    snippet changed since last build -> pristine"
        prune="always"
    fi

    run_in_container /ws/zmk/app "
        set -eo pipefail
        west build -d /ws/build/$shield -b $BOARD -p $prune $snippet_arg -- \
            -DZMK_EXTRA_MODULES='/modu/modu-module;/modu/zmk-pmw3610-driver' \
            -DSHIELD=$shield
        python3 /modu/tools/uf2/uf2conv.py -f 0xADA52840 -c \
            -o /modu/outputs/$shield.uf2 /ws/build/$shield/zephyr/zmk.hex
    "

    # A successful build proves less here than usual: led_breath.c's __weak
    # stubs link silently in place of ZMK symbols that get renamed upstream,
    # and the firmware still comes out. The linker map is where that shows,
    # so read it on every build rather than only when something looks wrong.
    if [ -f "$WORKSPACE/build/$shield/zephyr/zmk.map" ]; then
        python3 "$REPO_ROOT/tools/check-weak-stubs.py" \
            "$WORKSPACE/build/$shield/zephyr/zmk.map"
    fi
done

echo
echo "==> Done. Firmware is in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR"
