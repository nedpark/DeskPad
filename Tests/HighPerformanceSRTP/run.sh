#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
srtp_test_dir=$(mktemp -d)
trap 'rm -rf "$srtp_test_dir"' EXIT
swiftc DeskPad/HighPerformance/HighPerformanceMedia.swift DeskPad/HighPerformance/HighPerformanceSRTP.swift Tests/HighPerformanceSRTP/main.swift -o "$srtp_test_dir/tests"
"$srtp_test_dir/tests" Tests/HighPerformanceSRTP/vectors.json
