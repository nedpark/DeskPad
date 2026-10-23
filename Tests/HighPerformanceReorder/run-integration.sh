#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc DeskPad/HighPerformance/HighPerformanceMedia.swift DeskPad/HighPerformance/HighPerformanceSRTP.swift DeskPad/HighPerformanceRTPReorderBuffer.swift Tests/HighPerformanceReorder/Integration.swift -o "$test_dir/tests"
"$test_dir/tests"
