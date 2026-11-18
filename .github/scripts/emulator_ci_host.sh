#!/usr/bin/env bash
# Self-hosted emulator job helpers (source from workflow steps).
set -euo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
DIAG_DIR="${WORKSPACE}/ci-emulator-diagnostics"

adb_has_booted_device() {
  timeout 10 adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{found=1} END{exit !found}'
}

adb_server_cleanup() {
  timeout 10 adb kill-server 2>/dev/null || timeout 10 pkill -9 -f adb 2>/dev/null || true
}

_emulator_bin() {
  local sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  if [ -z "$sdk" ]; then
    sdk="/home/ghrunner/android-sdk"
  fi
  if [ -x "$sdk/emulator/emulator" ]; then
    echo "$sdk/emulator/emulator"
    return 0
  fi
  command -v emulator 2>/dev/null || return 1
}

emulator_host_preflight_checks() {
  mkdir -p "$DIAG_DIR"
  local avd_home="${ANDROID_AVD_HOME:-${HOME}/.android/avd}"
  local report="$DIAG_DIR/host-preflight.txt"
  {
    echo "flightvis-ci: host preflight $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "=== df -h / /tmp HOME ==="
    df -h / /tmp "${HOME:-/home/ghrunner}" 2>&1 || true
    echo "=== AVD directory size ==="
    du -sh "$avd_home" 2>/dev/null || echo "(no avd dir)"
    echo "=== /dev/kvm ==="
    ls -l /dev/kvm 2>&1 || true
    echo "=== emulator -accel-check ==="
    local emu
    emu="$(_emulator_bin)" || true
    if [ -n "$emu" ]; then
      "$emu" -accel-check 2>&1 || true
    else
      echo "emulator binary not found"
    fi
  } | tee "$report"

  local avail_kb
  avail_kb="$(df -k / | awk 'NR==2 {print $4}')"
  local min_kb=$((8 * 1024 * 1024))
  if [ -z "$avail_kb" ] || [ "$avail_kb" -lt "$min_kb" ]; then
    echo "::error::Root filesystem has less than 8 GiB free (${avail_kb:-?} KiB available); refusing to start emulator"
    exit 1
  fi
  test -r /dev/kvm && test -w /dev/kvm
}

emulator_host_stale_cleanup() {
  echo "flightvis-ci: clearing stale emulator/adb locks"
  adb_server_cleanup
  timeout 10 pkill -9 -f qemu-system-x86_64 2>/dev/null || true
  timeout 10 pkill -9 -f qemu-system-x86 2>/dev/null || true
  timeout 10 pkill -9 -f 'emulator.*-avd' 2>/dev/null || true
  local avd_home="${ANDROID_AVD_HOME:-${HOME}/.android/avd}"
  if [ -d "$avd_home" ]; then
    find "$avd_home" -name '*.lock' -delete 2>/dev/null || true
  fi
  timeout 10 adb start-server 2>/dev/null || true
  timeout 10 adb devices -l 2>/dev/null || true
}

emulator_delete_test_avd() {
  local sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/home/ghrunner/android-sdk}}"
  local avdmanager="$sdk/cmdline-tools/latest/bin/avdmanager"
  if [ ! -x "$avdmanager" ]; then
    avdmanager="$(find "$sdk/cmdline-tools" -name avdmanager -type f 2>/dev/null | head -1 || true)"
  fi
  if [ -n "$avdmanager" ] && [ -x "$avdmanager" ]; then
    echo "flightvis-ci: deleting existing AVD 'test' before recreate"
    echo "no" | "$avdmanager" delete avd -n test 2>/dev/null || true
  fi
  mkdir -p "$DIAG_DIR"
  echo "flightvis-ci: AVD test deleted (force recreation next)" >> "$DIAG_DIR/emulator-launch.log"
}

emulator_prepare_log_capture() {
  mkdir -p "$DIAG_DIR"
  : >"$DIAG_DIR/emulator-launch.log"
  echo "flightvis-ci: emulator will use -verbose -show-kernel (also in Actions step log)" >> "$DIAG_DIR/emulator-launch.log"
}

collect_emulator_avd_logs() {
  mkdir -p "$DIAG_DIR"
  timeout 5 dmesg 2>/dev/null | tail -300 >"$DIAG_DIR/dmesg-tail.txt" 2>/dev/null || true
  local avd_home="${ANDROID_AVD_HOME:-${HOME}/.android/avd}"
  if [ -d "$avd_home" ]; then
    find "$avd_home" -type f \( -name '*.log' -o -name 'initrd' -o -name 'emu-launch-params.txt' \) -print 2>/dev/null \
      | head -40 >>"$DIAG_DIR/avd-log-index.txt" || true
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      timeout 10 cp "$f" "$DIAG_DIR/avd-$base" 2>/dev/null || true
    done < <(find "$avd_home" -type f -name '*.log' 2>/dev/null | head -20)
  fi
}

collect_host_diagnostics() {
  mkdir -p "$DIAG_DIR"
  timeout 10 adb devices -l >"$DIAG_DIR/adb-devices.txt" 2>&1 || true
  if ! adb_has_booted_device; then
    echo "flightvis-ci: no adb device in 'device' state; skipping logcat/screencap/meminfo"
    return 0
  fi
  timeout 25 adb exec-out screencap -p >"$DIAG_DIR/host-screen.png" 2>/dev/null || true
  timeout 25 adb logcat -d >"$DIAG_DIR/host-logcat.txt" 2>/dev/null || true
  timeout 25 adb shell dumpsys meminfo cl.heavenly.flightvis >"$DIAG_DIR/host-meminfo.txt" 2>/dev/null || true
}

emulator_job_cleanup() {
  if [ -f mock_server.pid ]; then
    kill "$(cat mock_server.pid)" 2>/dev/null || true
  fi
  timeout 15 adb -s emulator-5554 emu kill 2>/dev/null || timeout 15 adb emu kill 2>/dev/null || true
  timeout 10 pkill -f mock_flight_vis_server.dart 2>/dev/null || true
  timeout 10 pkill -9 -f qemu-system 2>/dev/null || true
  adb_server_cleanup
  if [ -f android/gradlew ]; then
    timeout 60 android/gradlew --stop 2>/dev/null || true
  fi
  timeout 10 pkill -9 -f GradleDaemon 2>/dev/null || true
  timeout 10 pkill -9 -f KotlinCompileDaemon 2>/dev/null || true
  timeout 10 pkill -9 -f '[d]art ' 2>/dev/null || true
  timeout 10 pkill -9 -f dartvm 2>/dev/null || true
  collect_emulator_avd_logs
}