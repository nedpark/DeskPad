#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
binary=$(mktemp -t deskpad-storage-tests)
trap 'rm -f "$binary"' EXIT
swiftc -parse-as-library -warnings-as-errors DeskPad/Connections/ConnectionStore.swift Tests/Storage/main.swift -o "$binary"
"$binary"
