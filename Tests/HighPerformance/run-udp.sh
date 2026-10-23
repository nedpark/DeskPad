#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
binary=$(mktemp -t deskpad-hp-udp)
trap 'rm -f "$binary"' EXIT
swiftc -parse-as-library -warnings-as-errors DeskPad/HighPerformance/AppleHPUDPSocket.swift Tests/HighPerformance/UDPSocketHarness.swift -o "$binary"
"$binary"
