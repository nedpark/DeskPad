#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
binary=$(mktemp -t deskpad-hp-auth)
trap 'rm -f "$binary"' EXIT
swiftc -parse-as-library -warnings-as-errors DeskPad/HighPerformance/AppleHPAuthentication.swift Tests/HighPerformance/AuthenticationHarness.swift -o "$binary"
"$binary"
