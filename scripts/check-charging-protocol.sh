#!/bin/bash
# Portable checks for protocol evidence; no device, signing or network required.
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/miniwatts-protocol.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
  MiniWatts/Core/Model/PowerSnapshot.swift \
  MiniWatts/Core/Model/Formatting.swift \
  MiniWatts/Core/Sensors/HIDSensors.swift \
  MiniWatts/Core/Sensors/SensorCatalog.swift \
  tests/ChargingProtocolChecks.swift \
  -o "$check_dir/protocol-checks"
"$check_dir/protocol-checks"
