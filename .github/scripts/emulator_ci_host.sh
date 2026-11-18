#!/usr/bin/env bash
# Self-hosted emulator job helpers (source from workflow steps).
set -euo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
DIAG_DIR="${WORKSPACE}/ci-emulator-diagnostics"

adb_has_booted_device() {
  timeout 10 adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{found=1} END{exit !found}'
}

adb_server_cleanup() {
  timeout 10 adb kill-server 2>/dev/null || timeout 10 pkill -9 -x adb 2>/dev/null || true
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

emulator_delete_test_avd_if_present() {
  local sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/home/ghrunner/android-sdk}}"
  local avdmanager="$sdk/cmdline-tools/latest/bin/avdmanager"
  if [ ! -x "$avdmanager" ]; then
    avdmanager="$(find "$sdk/cmdline-tools" -name avdmanager -type f 2>/dev/null | head -1 || true)"
  fi
  if [ -n "$avdmanager" ] && [ -x "$avdmanager" ]; then
    if avdmanager list avd 2>/dev/null | grep -q 'Name: test'; then
      echo "flightvis-ci: deleting stale AVD 'test' before android-emulator-runner"
      echo no | "$avdmanager" delete avd -n test 2>/dev/null || true
    fi
  fi
}

emulator_clear_avd_locks() {
  local avd_home="${ANDROID_AVD_HOME:-${HOME}/.android/avd}"
  if [ -d "$avd_home" ]; then
    find "$avd_home" -name '*.lock' -delete 2>/dev/null || true
  fi
}

emulator_stale_process_cleanup() {
  adb_server_cleanup
  timeout 10 pkill -9 -x qemu-system-x86_64 2>/dev/null || true
  timeout 10 pkill -9 -x qemu-system-x86 2>/dev/null || true
  timeout 10 pkill -9 -x emulator 2>/dev/null || true
  emulator_clear_avd_locks
}

emulator_host_stale_cleanup() {
  echo "flightvis-ci: clearing stale emulator/adb locks"
  emulator_delete_test_avd_if_present
  emulator_stale_process_cleanup
  timeout 10 adb start-server 2>/dev/null || true
  timeout 10 adb devices -l 2>/dev/null || true
}

# android-emulator-runner always invokes sdkmanager; on omarchibald-android-emu
# packages live under /home/ghrunner/android-sdk — install only gaps and retry nets.
emulator_ensure_host_sdk_for_runner() {
  local root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/home/ghrunner/android-sdk}}"
  export ANDROID_SDK_ROOT="$root"
  export ANDROID_HOME="$root"
  local api="${FLIGHTVIS_EMULATOR_API:-30}"
  local arch="${FLIGHTVIS_EMULATOR_ARCH:-x86_64}"
  local target="${FLIGHTVIS_EMULATOR_TARGET:-google_apis}"
  local sdkmgr="$root/cmdline-tools/latest/bin/sdkmanager"
  if [ ! -x "$sdkmgr" ]; then
    echo "::error::Host SDK cmdline-tools missing at $sdkmgr"
    exit 1
  fi
  if [ ! -f "$sdkmgr.orig" ]; then
    cp "$sdkmgr" "$sdkmgr.orig"
    cp "${WORKSPACE}/.github/scripts/sdkmanager_host.sh" "$sdkmgr"
    chmod +x "$sdkmgr"
    echo "flightvis-ci: installed sdkmanager host shim at $sdkmgr"
  fi
  local packages=(
    platform-tools
    "build-tools;37.0.0"
    "platforms;android-${api}"
    emulator
    "system-images;android-${api};${target};${arch}"
  )
  echo "flightvis-ci: ensure host SDK packages (api=${api} arch=${arch} target=${target})"
  "$sdkmgr" --install "${packages[@]}"
}

emulator_append_sdk_inventory() {
  mkdir -p "$DIAG_DIR"
  {
    echo "=== sdkmanager --list_installed @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    sdkmanager --list_installed 2>/dev/null | grep -E 'system-images|emulator' || true
    echo "=== avdmanager list avd ==="
    avdmanager list avd 2>/dev/null || true
  } >>"$DIAG_DIR/sdk-inventory.txt" 2>&1 || true
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

emulator_collect_log_files() {
  mkdir -p "$DIAG_DIR"
  for f in emulator-logcat-output.txt emulator-qemu.log emulator-stdio.log sdk-inventory.txt; do
    if [ -f "$DIAG_DIR/$f" ]; then
      echo "flightvis-ci: captured $DIAG_DIR/$f ($(wc -c <"$DIAG_DIR/$f") bytes)"
    fi
  done
  if [ -f "$DIAG_DIR/emulator-launch.log" ]; then
    echo "flightvis-ci: emulator-launch.log $(wc -c <"$DIAG_DIR/emulator-launch.log") bytes"
  fi
}

collect_host_diagnostics() {
  mkdir -p "$DIAG_DIR"
  emulator_collect_log_files
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
  emulator_append_sdk_inventory
  if [ -f mock_server.pid ]; then
    kill "$(cat mock_server.pid)" 2>/dev/null || true
  fi
  timeout 15 adb -s emulator-5554 emu kill 2>/dev/null || timeout 15 adb emu kill 2>/dev/null || true
  timeout 10 pkill -f '[m]ock_flight_vis_server.dart' 2>/dev/null || true
  timeout 10 pkill -9 -x qemu-system-x86_64 2>/dev/null || true
  timeout 10 pkill -9 -x qemu-system-x86 2>/dev/null || true
  timeout 10 pkill -9 -x emulator 2>/dev/null || true
  adb_server_cleanup
  if [ -f android/gradlew ]; then
    timeout 60 android/gradlew --stop 2>/dev/null || true
  fi
  timeout 10 pkill -9 -f '[G]radleDaemon' 2>/dev/null || true
  timeout 10 pkill -9 -f '[K]otlinCompileDaemon' 2>/dev/null || true
  timeout 10 pkill -9 -f '[d]art ' 2>/dev/null || true
  timeout 10 pkill -9 -x dartvm 2>/dev/null || true
  collect_emulator_avd_logs
}