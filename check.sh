#!/bin/zsh
# Called by check/action.yml: unsigned build or simulator tests for pull requests. Never signs or uploads.
set -euo pipefail
MIN_FREE_GB=5
source ${0:A:h}/lib.sh
trap 'rm -rf $DD' EXIT

COMMON=("${PROJ_ARGS[@]}" -scheme "$SCHEME" -derivedDataPath $DD CODE_SIGNING_ALLOWED=NO)

if [[ $RUN_TESTS == true ]]; then
  SIM=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
devs=[d for rt,ds in json.load(sys.stdin)["devices"].items() if "iOS" in rt for d in ds if d["name"].startswith("iPhone")]
print(devs[-1]["udid"] if devs else "")')
  [[ -z $SIM ]] && { echo "::error::No available iPhone simulator"; exit 1; }
  step "Test $SCHEME (simulator $SIM)"
  xcb test test "${COMMON[@]}" -destination "id=$SIM" -parallel-testing-enabled NO
  endstep
elif [[ ${BUILD_FOR:-simulator} == device ]]; then
  step "Build $SCHEME (device, unsigned)"
  xcb build build "${COMMON[@]}" -destination 'generic/platform=iOS'
  endstep
else
  step "Build $SCHEME (iOS simulator)"
  xcb build build "${COMMON[@]}" -destination 'generic/platform=iOS Simulator'
  endstep
fi
echo "### ✅ $SCHEME $([[ $RUN_TESTS == true ]] && echo 'tests passed' || echo 'build passed') ($(git rev-parse --short HEAD))" >> $GITHUB_STEP_SUMMARY
