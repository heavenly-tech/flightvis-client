#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "${GITHUB_WORKSPACE:-.}/.github/scripts/emulator_runner_common.sh"

wait_for_android_ready
timeout 120 adb install -r build/app/outputs/flutter-apk/app-debug.apk
set +e
flutter test integration_test/screenshot_flow_test.dart \
  --dart-define-from-file=tool/ci_screenshot_defines.json \
  -d emulator-5554 --timeout 12m --no-uninstall --reporter expanded
TEST_EXIT=$?
set -e
mkdir -p docs/emulator-screenshots
if adb_has_booted_device; then
  timeout 90 adb pull /sdcard/Download/flightvis-emulator/. docs/emulator-screenshots/ || true
fi
ls -la docs/emulator-screenshots || true
if [ "$TEST_EXIT" -ne 0 ]; then
  collect_emulator_diagnostics
  exit "$TEST_EXIT"
fi