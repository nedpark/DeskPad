#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
binary=$(mktemp -t deskpad-hp-display)
trap 'rm -f "$binary"' EXIT
swiftc -parse-as-library -warnings-as-errors DeskPad/HighPerformance/AppleHPDisplayConfiguration.swift Tests/HighPerformance/DisplayConfigurationHarness.swift -o "$binary"
"$binary"
