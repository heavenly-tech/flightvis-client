#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "${GITHUB_WORKSPACE:-.}/.github/scripts/emulator_runner_common.sh"

wait_for_android_ready
timeout 120 adb install -r build/app/outputs/flutter-apk/app-debug.apk
set +e
flutter test integration_test/ci_functional_suite.dart \
  --dart-define-from-file=tool/ci_functional_defines.json \
  -d emulator-5554 --timeout 10m --no-uninstall --reporter expanded
TEST_EXIT=$?
set -e
if [ "$TEST_EXIT" -ne 0 ]; then
  collect_emulator_diagnostics
  exit "$TEST_EXIT"
fi