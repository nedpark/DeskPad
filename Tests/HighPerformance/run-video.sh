#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
binary=$(mktemp -t deskpad-hp-video)
trap 'rm -f "$binary"' EXIT
swiftc -parse-as-library -warnings-as-errors DeskPad/HighPerformance/AppleHPVideoDepacketizer.swift Tests/HighPerformance/VideoDepacketizerHarness.swift -o "$binary"
"$binary"
