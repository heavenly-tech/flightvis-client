#!/usr/bin/env bash
# Self-hosted sdkmanager shim: skip installs when paths exist; retry downloads.
set -euo pipefail

ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/home/ghrunner/android-sdk}}"
ORIG="$ROOT/cmdline-tools/latest/bin/sdkmanager.orig"
if [ ! -x "$ORIG" ]; then
  echo "flightvis-ci: sdkmanager.orig missing at $ORIG" >&2
  exit 1
fi

_sdk_pkg_installed() {
  local pkg="$1"
  case "$pkg" in
    build-tools\;*)
      local ver="${pkg#build-tools;}"
      [ -d "$ROOT/build-tools/$ver" ]
      ;;
    platforms\;android-*)
      local level="${pkg#platforms;android-}"
      [ -d "$ROOT/platforms/android-$level" ]
      ;;
    platform-tools)
      [ -x "$ROOT/platform-tools/adb" ]
      ;;
    emulator)
      [ -x "$ROOT/emulator/emulator" ]
      ;;
    system-images\;android-*\;*\;*)
      local rest="${pkg#system-images;}"
      local api="${rest%%;*}"
      rest="${rest#*;}"
      local target="${rest%%;*}"
      local arch="${rest#*;}"
      api="${api#android-}"
      [ -d "$ROOT/system-images/android-$api/$target/$arch" ]
      ;;
    ndk\;*)
      local ver="${pkg#ndk;}"
      [ -d "$ROOT/ndk/$ver" ]
      ;;
    cmake\;*)
      local ver="${pkg#cmake;}"
      [ -d "$ROOT/cmake/$ver" ]
      ;;
    *)
      return 1
      ;;
  esac
}

_run_sdkmanager_with_retry() {
  local attempt max=4 delay=4
  for ((attempt = 1; attempt <= max; attempt++)); do
    if "$ORIG" "$@"; then
      return 0
    fi
    echo "flightvis-ci: sdkmanager failed (attempt $attempt/$max): $*" >&2
    sleep "$delay"
    delay=$((delay * 2))
  done
  return 1
}

if [ "$1" = "--licenses" ]; then
  _run_sdkmanager_with_retry "$@"
  exit $?
fi

if [ "$1" = "--install" ]; then
  shift
  missing=()
  channel_args=()
  for pkg in "$@"; do
    case "$pkg" in
      --channel=*|--sdk_root=*|--verbose)
        channel_args+=("$pkg")
        ;;
      *)
        if _sdk_pkg_installed "$pkg"; then
          echo "flightvis-ci: sdkmanager skip installed $pkg"
        else
          missing+=("$pkg")
        fi
        ;;
    esac
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    exit 0
  fi
  _run_sdkmanager_with_retry --install "${missing[@]}" "${channel_args[@]}"
  exit $?
fi

_run_sdkmanager_with_retry "$@"