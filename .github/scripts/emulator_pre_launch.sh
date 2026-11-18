#!/usr/bin/env bash
# Runs AFTER android-emulator-runner creates the AVD, immediately before qemu launch.
# Do NOT delete the AVD here (that caused "Unknown AVD name [test]" on d2887bf).
set -euo pipefail
# shellcheck disable=SC1091
source "${GITHUB_WORKSPACE:-.}/.github/scripts/emulator_ci_host.sh"

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/home/ghrunner/android-sdk}}"
export ANDROID_HOME="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
export PATH="$ANDROID_SDK_ROOT/emulator:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH"

FLIGHTVIS_SYSTEM_IMAGE_PKG="${FLIGHTVIS_SYSTEM_IMAGE_PKG:-system-images;android-30;google_apis;x86_64}"

mkdir -p "$DIAG_DIR"
adb_server_cleanup

{
  echo "flightvis-ci: pre-emulator-launch $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT"
  echo "ANDROID_AVD_HOME=${ANDROID_AVD_HOME:-<unset>}"
  echo "=== sdkmanager --list_installed (system-images) ==="
  sdkmanager --list_installed 2>/dev/null | grep 'system-images' || true
  echo "=== avdmanager list avd ==="
  avdmanager list avd 2>/dev/null || true
} | tee -a "$DIAG_DIR/emulator-launch.log"

if ! sdkmanager --list_installed 2>/dev/null | grep -Fq "$FLIGHTVIS_SYSTEM_IMAGE_PKG"; then
  echo "flightvis-ci: reinstalling missing $FLIGHTVIS_SYSTEM_IMAGE_PKG"
  sdkmanager --install "$FLIGHTVIS_SYSTEM_IMAGE_PKG" >>"$DIAG_DIR/emulator-launch.log" 2>&1 || true
fi

if ! avdmanager list avd 2>/dev/null | grep -q 'Name: test'; then
  echo "::error::AVD 'test' missing after avdmanager create (see emulator-launch.log)"
  exit 1
fi

echo "flightvis-ci: AVD test present; emulator log: $DIAG_DIR/emulator-stdio.log" >>"$DIAG_DIR/emulator-launch.log"