#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_DIR=$(mktemp -d /tmp/deskpad-input-queue.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library "$ROOT/DeskPad/VNC/RFBInputQueue.swift" \
  "$ROOT/Tests/Session/InputQueueHarness.swift" -o "$TEST_DIR/input-queue-tests"
"$TEST_DIR/input-queue-tests"
