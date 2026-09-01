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
        git clone --depth 1 https://github.com/zmkfirmware/zmk.git "$WORKSPACE/zmk"
    fi
    run_in_container /ws 'west init -l zmk/app'
    run_in_container /ws/zmk 'west update --narrow -o=--depth=1 && west zephyr-export'
fi

mkdir -p "$OUTPUT_DIR"

for shield in "${shields[@]}"; do
    echo "==> Building $shield"
    run_in_container /ws/zmk/app "
        set -eo pipefail
        west build -d /ws/build/$shield -b $BOARD -p auto -- \
            -DZMK_EXTRA_MODULES='/modu/modu-module;/modu/zmk-pmw3610-driver' \
            -DSHIELD=$shield
        python3 /modu/tools/uf2/uf2conv.py -f 0xADA52840 -c \
            -o /modu/outputs/$shield.uf2 /ws/build/$shield/zephyr/zmk.hex
    "
done

echo
echo "==> Done. Firmware is in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR"
