#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -target "$(uname -m)-apple-macos14.0" DeskPad/HighPerformance/HighPerformancePlayback.swift DeskPad/HighPerformancePCMAudio.swift DeskPad/HighPerformanceNativeVideoDecoder.swift Tests/HighPerformanceNativeVideo/Harness.swift -o "$test_dir/tests"
"$test_dir/tests" Tests/HighPerformancePlayback/black.h264

"$test_dir/tests" Tests/HighPerformancePlayback/red.hevc
"$test_dir/tests" Tests/HighPerformancePlayback/red444.hevc
