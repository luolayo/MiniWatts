#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/miniwatts-settings.XXXXXX")
check_binary="$check_dir/settings-checks"
trap 'rm -f "$check_binary"; rmdir "$check_dir"' EXIT
swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
  MiniWatts/Core/Model/TrafficBackgroundExecution.swift \
  MiniWatts/Core/Model/TrafficDownload.swift \
  MiniWatts/Core/Model/TrafficConfiguration.swift \
  MiniWatts/Core/TrafficDownloadEngine.swift \
  MiniWatts/Core/TrafficBackgroundCoordinator.swift \
  MiniWatts/Core/TrafficConsumer.swift \
  MiniWatts/Core/BackgroundMonitoringSession.swift \
  MiniWatts/Shared/NetworkReading.swift \
  MiniWatts/Shared/ChargeActivityState.swift \
  MiniWatts/Shared/ChargeReading.swift \
  MiniWatts/Core/Model/PowerSnapshot.swift \
  MiniWatts/Core/Model/Formatting.swift \
  MiniWatts/Core/Sensors/HIDSensors.swift \
  MiniWatts/Core/Sensors/IOKitBattery.swift \
  MiniWatts/Core/Sensors/SensorCatalog.swift \
  tests/TrafficSettingsChecks.swift -o "$check_binary"
"$check_binary"
