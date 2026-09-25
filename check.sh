#!/bin/zsh
# Called by check/action.yml: unsigned build or simulator tests for pull requests. Never signs or uploads.
set -euo pipefail
MIN_FREE_GB=5
source ${0:A:h}/lib.sh
trap 'rm -rf $DD' EXIT

COMMON=("${PROJ_ARGS[@]}" -scheme "$SCHEME" -derivedDataPath $DD CODE_SIGNING_ALLOWED=NO)

if [[ ${BUILD_FOR:-simulator} == device ]]; then
  # Tests need a simulator; a device destination means "unsigned device build only".
  step "Build $SCHEME (device, unsigned)"
  xcb build build "${COMMON[@]}" -destination 'generic/platform=iOS'
  endstep; RESULT="build passed (device)"
elif [[ $RUN_TESTS == true ]]; then
  SIM=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
devs=[d for rt,ds in json.load(sys.stdin)["devices"].items() if "iOS" in rt for d in ds if d["name"].startswith("iPhone")]
print(devs[-1]["udid"] if devs else "")')
  [[ -z $SIM ]] && { echo "::error::No available iPhone simulator"; exit 1; }
  SKIP=()
  if [[ ${SKIP_UI_TESTS:-true} == true ]]; then
    # UI tests (and Xcode's template testLaunchPerformance) are slow and flaky on CI; run unit tests only.
    for t in ${(f)"$(xcodebuild "${PROJ_ARGS[@]}" -list -json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print("\n".join(t for t in (d.get("project") or {}).get("targets",[]) if t.endswith("UITests")))')"}; do
      SKIP+=(-skip-testing:$t)
    done
  fi
  for t in ${=SKIP_TESTING:-}; do SKIP+=(-skip-testing:$t); done
  (( ${#SKIP} )) && echo "Skipping: ${SKIP[*]//-skip-testing:/}"
  step "Test $SCHEME (simulator $SIM)"
  # Tests launch the app as the test host, so it needs its entitlements (CloudKit etc. abort without them).
  # Sign ad hoc ("Sign to Run Locally") — works on the simulator without any certificate or profile.
  ADHOC=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
  if xcb test test "${PROJ_ARGS[@]}" -scheme "$SCHEME" -derivedDataPath $DD "${ADHOC[@]}" \
       -destination "id=$SIM" -parallel-testing-enabled NO "${SKIP[@]}"; then
    endstep; RESULT="tests passed"
  elif grep -qE 'is not currently configured for the test action|There are no test bundles available to test' $WORK/test.log; then
    endstep; echo "No tests configured for $SCHEME — building instead"
    step "Build $SCHEME (iOS simulator)"
    xcb build build "${COMMON[@]}" -destination 'generic/platform=iOS Simulator'
    endstep; RESULT="build passed (no tests configured)"
  else
    exit 1
  fi
else
  step "Build $SCHEME (iOS simulator)"
  xcb build build "${COMMON[@]}" -destination 'generic/platform=iOS Simulator'
  endstep; RESULT="build passed"
fi
echo "### ✅ $SCHEME $RESULT ($(git rev-parse --short HEAD))" >> $GITHUB_STEP_SUMMARY
