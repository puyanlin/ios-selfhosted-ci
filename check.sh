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
  # Each job gets its own throwaway simulator: parallel jobs sharing one device kill each other's test hosts.
  SDKVER=$(xcrun --sdk iphonesimulator --show-sdk-version)
  read -r RUNTIME DEVTYPE <<< "$(xcrun simctl list -j runtimes devicetypes | SDKVER=$SDKVER python3 -c '
import json,os,re,sys
d=json.load(sys.stdin); sdk=[int(x) for x in os.environ["SDKVER"].split(".")]
v=lambda s:[int(x) for x in s.split(".")]
rts=[r for r in d["runtimes"] if r.get("isAvailable") and "iOS" in r["name"]]
# Prefer the runtime that matches this Xcode'"'"'s simulator SDK; otherwise the newest one not newer than it.
same=[r for r in rts if v(r["version"])[:2]==sdk[:2]]
older=sorted([r for r in rts if v(r["version"])<=sdk+[99]], key=lambda r:v(r["version"]))
rt=(sorted(same,key=lambda r:v(r["version"]))[-1:] or older[-1:] or [None])[0]
supported=[t for t in (rt or {}).get("supportedDeviceTypes",[]) if t.get("productFamily")=="iPhone"]
plain=sorted([t for t in supported if re.fullmatch(r"iPhone \d+", t["name"])], key=lambda t:int(t["name"].split()[1]))
pick=(plain or supported or [None])[-1]
print((rt or {}).get("identifier",""), (pick or {}).get("identifier",""))')"
  [[ -n $RUNTIME && -n $DEVTYPE ]] || { echo "::error::No iOS $SDKVER simulator runtime / iPhone device type installed"; exit 1; }
  # One simulator test run per machine at a time: booting several fresh simulators at once on a busy Mac
  # can take forever. Builds still run in parallel; only this phase is serialized (mkdir is atomic).
  LOCK=$HOME/actions-runners/_locks/simulator-tests
  mkdir -p ${LOCK:h}
  waited=0
  until mkdir $LOCK 2>/dev/null; do
    holder=$(cat $LOCK/pid 2>/dev/null || true)
    if [[ -n $holder ]] && ! kill -0 $holder 2>/dev/null; then rm -rf $LOCK; continue; fi   # stale lock
    (( waited % 60 == 0 )) && echo "Waiting for another job's simulator tests to finish…"
    sleep 5; (( waited += 5 ))
    (( waited > 1800 )) && { echo "::error::Waited 30 minutes for the simulator lock"; exit 1; }
  done
  echo $$ > $LOCK/pid
  SIM=$(xcrun simctl create "ci-${GITHUB_RUN_ID:-local}-$$" $DEVTYPE $RUNTIME)
  # Cleanup must never hang the job: give simctl at most a minute, then release the lock.
  trap 'perl -e "alarm 60; exec @ARGV" xcrun simctl shutdown $SIM >/dev/null 2>&1; perl -e "alarm 60; exec @ARGV" xcrun simctl delete $SIM >/dev/null 2>&1; rm -rf $LOCK $DD' EXIT
  # A fresh device's first boot can take longer than xcodebuild's 60 s; boot it up front.
  xcrun simctl boot $SIM
  if ! perl -e 'alarm 300; exec @ARGV' xcrun simctl bootstatus $SIM >/dev/null 2>&1; then
    echo "::error::Simulator did not finish booting within 5 minutes"; exit 1
  fi
  echo "Simulator: ${DEVTYPE##*.} / ${RUNTIME##*.} ($SIM)"
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
