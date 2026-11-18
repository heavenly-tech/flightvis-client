#!/usr/bin/env bash
# Runs after android-emulator-runner creates the AVD, immediately before qemu launch.
# Only stale process cleanup and AVD lock removal — never delete the AVD here.
set -euo pipefail
# shellcheck disable=SC1091
source "${GITHUB_WORKSPACE:-.}/.github/scripts/emulator_ci_host.sh"

mkdir -p "$DIAG_DIR"
{
  echo "flightvis-ci: pre-emulator-launch $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "flightvis-ci: stale process + lock cleanup (no AVD delete)"
} >>"$DIAG_DIR/emulator-launch.log"

emulator_stale_process_cleanup