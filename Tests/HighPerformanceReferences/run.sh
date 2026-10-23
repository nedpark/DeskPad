#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc DeskPad/AppleHPHEVCReferenceGuard.swift Tests/HighPerformanceReferences/Harness.swift -o "$test_dir/tests"
"$test_dir/tests" Tests/HighPerformancePlayback/chain120.hevc
