#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
inbox_test_dir=$(mktemp -d)
trap 'rm -rf "$inbox_test_dir"' EXIT
swiftc -swift-version 6 DeskPad/AppleHPDatagramInbox.swift Tests/HPDatagramInbox/Harness.swift -o "$inbox_test_dir/tests"
"$inbox_test_dir/tests"
