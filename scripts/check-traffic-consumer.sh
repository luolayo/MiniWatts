#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/miniwatts-traffic.XXXXXX")
check_binary="$check_dir/traffic-checks"
trap 'rm -f "$check_binary"; rmdir "$check_dir"' EXIT
swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
  MiniWatts/Core/Model/TrafficDownload.swift \
  MiniWatts/Core/Model/TrafficBackgroundExecution.swift \
  MiniWatts/Core/TrafficDownloadEngine.swift \
  tests/TrafficDownloadChecks.swift -o "$check_binary"
"$check_binary"
