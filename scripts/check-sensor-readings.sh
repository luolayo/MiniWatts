#!/bin/bash
# Portable synthetic sensor checks; no device, signing or external network.
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/miniwatts-sensors.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
  MiniWatts/Core/Model/PowerSnapshot.swift \
  MiniWatts/Core/Model/EnergyAccumulator.swift \
  MiniWatts/Core/Model/PathResistance.swift \
  MiniWatts/Core/Model/Formatting.swift \
  MiniWatts/Core/Sensors/HIDSensors.swift \
  MiniWatts/Core/Sensors/SensorCatalog.swift \
  MiniWatts/Shared/ChargeReading.swift \
  tests/SensorReadingChecks.swift \
  -o "$check_dir/sensor-checks"
"$check_dir/sensor-checks"
