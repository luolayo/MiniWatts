#!/bin/bash
# Portable macOS checks; no iOS SDK, simulator, signing, or third-party packages.
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/miniwatts-network.XXXXXX")
check_binary="$check_dir/network-checks"
trap 'rm -f "$check_binary"; rmdir "$check_dir"' EXIT
swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
  MiniWatts/Shared/NetworkReading.swift \
  MiniWatts/Shared/ChargeActivityState.swift \
  MiniWatts/Shared/ChargeReading.swift \
  MiniWatts/Core/Model/NetworkRateAccumulator.swift \
  MiniWatts/Core/Model/PowerSnapshot.swift \
  MiniWatts/Core/Model/Formatting.swift \
  MiniWatts/Core/Sensors/NetworkMonitor.swift \
  MiniWatts/Core/Sensors/HIDSensors.swift \
  MiniWatts/Core/Sensors/IOKitBattery.swift \
  MiniWatts/Core/Sensors/SensorCatalog.swift \
  tests/NetworkMonitoringChecks.swift \
  -o "$check_binary"
"$check_binary"
