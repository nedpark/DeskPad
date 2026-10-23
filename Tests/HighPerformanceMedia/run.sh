#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
media_test_dir=$(mktemp -d)
trap 'rm -rf "$media_test_dir"' EXIT
swiftc DeskPad/HighPerformance/HighPerformanceMedia.swift Tests/HighPerformanceMedia/main.swift -o "$media_test_dir/tests"
"$media_test_dir/tests"
