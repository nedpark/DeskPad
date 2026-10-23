#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -target "$(uname -m)-apple-macos14.0" DeskPad/HighPerformance/HighPerformanceMedia.swift DeskPad/HighPerformance/HighPerformancePlayback.swift DeskPad/HighPerformanceNativeVideoDecoder.swift DeskPad/HighPerformancePCMAudio.swift Tests/HighPerformancePCMAudio/Harness.swift -o "$test_dir/tests"
"$test_dir/tests" Tests/HighPerformancePlayback/tone-sequence.aac-au
