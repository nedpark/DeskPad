#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc DeskPad/HighPerformance/HighPerformanceMedia.swift DeskPad/HighPerformance/HighPerformanceSRTP.swift DeskPad/AppleHPReceptionReport.swift Tests/HighPerformanceReception/Harness.swift -o "$test_dir/tests"
"$test_dir/tests"
