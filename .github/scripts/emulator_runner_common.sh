#!/usr/bin/env bash
# Shared helpers for android-emulator-runner post-boot script (single shell file).
set -euo pipefail

adb_has_booted_device() {
  timeout 10 adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{found=1} END{exit !found}'
}

collect_emulator_diagnostics() {
  mkdir -p ci-emulator-diagnostics
  timeout 10 adb devices -l >ci-emulator-diagnostics/adb-devices.txt 2>&1 || true
  if ! adb_has_booted_device; then
    echo "flightvis-ci: no device; skip in-emulator diagnostics"
    return 0
  fi
  timeout 25 adb exec-out screencap -p >ci-emulator-diagnostics/screen.png 2>/dev/null || true
  timeout 25 adb logcat -d >ci-emulator-diagnostics/logcat.txt 2>/dev/null || true
  timeout 25 adb shell dumpsys meminfo cl.heavenly.flightvis >ci-emulator-diagnostics/meminfo.txt 2>/dev/null || true
  timeout 60 adb pull /sdcard/Download/flightvis-emulator/. ci-emulator-diagnostics/flutter-screenshots/ 2>/dev/null || true
}

wait_for_android_ready() {
  timeout 180 adb wait-for-device
  local boot_deadline=$((SECONDS + 120))
  while true; do
    booted="$(timeout 20 adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    [ "$booted" = "1" ] && break
    [ "$SECONDS" -ge "$boot_deadline" ] && {
      echo "::error::boot timeout in runner script"
      exit 1
    }
    sleep 2
  done
  for _ in $(seq 1 24); do
    if timeout 20 adb shell pm path android >/dev/null 2>&1; then
      echo "flightvis-ci: pm ready"
      break
    fi
    sleep 5
  done
  timeout 20 adb shell pm path android
}