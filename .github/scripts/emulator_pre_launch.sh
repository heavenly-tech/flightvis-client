#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "${GITHUB_WORKSPACE:-.}/.github/scripts/emulator_ci_host.sh"
emulator_delete_test_avd
emulator_prepare_log_capture