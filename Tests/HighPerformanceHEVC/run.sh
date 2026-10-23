#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -target "$(uname -m)-apple-macos14.0" DeskPad/HighPerformance/HighPerformanceMedia.swift DeskPad/HighPerformance/HighPerformancePlayback.swift DeskPad/HighPerformancePCMAudio.swift DeskPad/HighPerformanceNativeVideoDecoder.swift DeskPad/HighPerformance/AppleHPVideoDepacketizer.swift DeskPad/AppleHPHEVCDepacketizer.swift DeskPad/HighPerformance/HighPerformanceMediaPipeline.swift DeskPad/AppleHPHEVCReferenceGuard.swift Tests/HighPerformanceHEVC/Harness.swift -o "$test_dir/tests"
"$test_dir/tests" Tests/HighPerformancePlayback/red.hevc
"$test_dir/tests" Tests/HighPerformancePlayback/red444.hevc
