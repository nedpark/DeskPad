#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BINARY=$(mktemp -t deskpad-hp-records)
trap 'rm -f "$BINARY"' EXIT
swiftc -O -parse-as-library "$ROOT/DeskPad/HighPerformance/AppleHPRecordCipher.swift" "$ROOT/Tests/Session/HPRecordHarness.swift" -o "$BINARY"
"$BINARY"
