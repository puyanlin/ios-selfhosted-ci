#!/bin/zsh
# Called by check/action.yml: unsigned build or simulator tests for pull requests. Never signs or uploads.
set -euo pipefail
zmodload zsh/datetime
MIN_FREE_GB=5
source ${0:A:h}/lib.sh

# Hard time limit for the test phase, below the job's timeout-minutes (40 in the reusable workflow): a hung
# xcodebuild is stopped and cleaned up here instead of by GitHub, which only signals this process.
TEST_TIMEOUT=${TEST_TIMEOUT_SECONDS:-$(( ${TEST_TIMEOUT_MINUTES:-35} * 60 ))}
LOCK=$HOME/actions-runners/_locks/simulator-tests
# No live job can hold the lock longer than create + boot (≤ 6 min) + the tests + cleanup.
LOCK_MAX_AGE=$(( TEST_TIMEOUT + 600 ))

# --- cleanup --------------------------------------------------------------------------------------------
# When GitHub cancels the job (new commit, timeout, runner lost), the runner sends this process SIGINT,
# SIGTERM 7.5 s later and SIGKILL 2.5 s after that — and signals nothing else, so xcodebuild and the
# simulator would live on for hours holding the lock. On a signal: stop xcodebuild's process group, release
# the lock at once, and hand the slow simulator cleanup to a detached process that survives the SIGKILL.
SIM='' LOCK_HELD='' STOPPED_BY='' PARENT_WATCHDOG='' CLEANED=''
simctl_quiet() { perl -e 'alarm 60; exec @ARGV' xcrun simctl "$@" >/dev/null 2>&1 || true; }
release_lock() {
  if [[ -n $LOCK_HELD && $(cat $LOCK/pid 2>/dev/null) == $$ ]]; then rm -rf $LOCK; fi
  LOCK_HELD=''
}
cleanup() {
  [[ -n $CLEANED ]] && return 0; CLEANED=1
  set +e; trap '' INT TERM HUP
  stop_xcodebuild
  [[ -n $PARENT_WATCHDOG ]] && kill -KILL $PARENT_WATCHDOG 2>/dev/null
  # Anything started but not recorded yet (a signal can land between `cmd &` and `PID=$!`): kill the
  # remaining direct children and, for process-group leaders such as xcodebuild, their whole group.
  local p; for p in ${(f)"$(pgrep -P $$)"}; do kill -KILL -- -$p $p 2>/dev/null; done
  if [[ -n $STOPPED_BY ]]; then
    release_lock
    # Own session, HUP ignored: finishes even after the runner kills this process. Each simctl call is time-boxed.
    perl -MPOSIX -e '$SIG{HUP}="IGNORE"; setsid(); exec @ARGV' zsh -c '
      if [[ -n $1 ]]; then
        perl -e "alarm 60; exec @ARGV" xcrun simctl shutdown $1
        perl -e "alarm 60; exec @ARGV" xcrun simctl delete $1
      fi
      rm -rf $2' _ "$SIM" "$DD" </dev/null >/dev/null 2>&1 &
  else
    [[ -n $SIM ]] && simctl_quiet shutdown $SIM
    release_lock
    [[ -n $SIM ]] && simctl_quiet delete $SIM
    rm -rf $DD
  fi
  return 0
}
trap cleanup EXIT
on_signal() {  # on_signal <signal> <exit code>
  trap '' INT TERM HUP
  STOPPED_BY=$1
  echo "::error::Stopped by SIG$1 (job cancelled or runner gone): stopping xcodebuild, releasing the simulator lock"
  # Clean up right here: inside a function zsh defers `exit` until the interrupted `wait` for xcodebuild
  # returns, and that only happens once cleanup has stopped it. (cleanup runs once; the EXIT trap is a no-op.)
  cleanup
  exit $2
}
trap 'on_signal INT 130' INT; trap 'on_signal TERM 143' TERM; trap 'on_signal HUP 129' HUP
# Our parent is the runner's Worker process (check/action.yml execs this script). If it dies — killed by the
# runner after a cancel, or gone with a lost server connection — the job is over but nothing signals us.
# (The watchdog only fires if our pid is still check.sh and has been reparented to launchd, so an orphaned
#  watchdog cannot hit a recycled pid.)
if (( PPID > 1 )); then
  perl -e '($p,$me)=@ARGV; while (kill(0,$p) || $!{EPERM}) { sleep 10 }
           kill TERM => $me if qx(ps -o ppid=,command= -p $me) =~ /^\s*1\s.*check\.sh/' $PPID $$ &
  PARENT_WATCHDOG=$!
fi

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
  # The lock records who holds it (pid, the runner process that started it, start time, run URL) so a lock
  # left behind by a dead or orphaned job is recognised and removed instead of blocking everyone for 30 min.
  mkdir -p ${LOCK:h}
  waited=0
  until mkdir $LOCK 2>/dev/null; do
    holder=$(cat $LOCK/pid 2>/dev/null || true)
    parent=$(cat $LOCK/parent 2>/dev/null || true)
    started=$(cat $LOCK/started 2>/dev/null || true)
    run=$(cat $LOCK/run 2>/dev/null || echo 'unknown run')
    age=$(( EPOCHSECONDS - ${started:-$EPOCHSECONDS} ))
    stale=''
    if [[ -n $holder ]] && ! kill -0 $holder 2>/dev/null; then stale="pid $holder is gone"
    elif [[ -n $holder && $(ps -o command= -p $holder 2>/dev/null) != *check.sh* ]]; then stale="pid $holder is no longer check.sh"
    elif [[ -n $parent ]] && ! kill -0 $parent 2>/dev/null; then stale="the runner process that started pid $holder is gone"
    elif (( age > LOCK_MAX_AGE )); then stale="held for $(( age / 60 )) min, longer than any test run can take"
    fi
    if [[ -n $stale ]]; then echo "Removing stale simulator lock: $stale ($run)"; rm -rf $LOCK; continue; fi
    (( waited % 60 == 0 )) && echo "Waiting for another job's simulator tests to finish (pid ${holder:-?}, $run, held for $(( age / 60 )) min)…"
    sleep 5; (( waited += 5 ))
    (( waited > 1800 )) && { echo "::error::Waited 30 minutes for the simulator lock, held by pid ${holder:-?} ($run). See docs/troubleshooting.md"; exit 1; }
  done
  LOCK_HELD=1
  echo $$ > $LOCK/pid
  (( PPID > 1 )) && echo $PPID > $LOCK/parent
  echo $EPOCHSECONDS > $LOCK/started
  if [[ -n ${GITHUB_RUN_ID:-} ]]; then echo "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID" > $LOCK/run
  else echo "local run" > $LOCK/run; fi
  SIM=$(xcrun simctl create "ci-${GITHUB_RUN_ID:-local}-$$" $DEVTYPE $RUNTIME)
  # A fresh device's first boot can take longer than xcodebuild's 60 s; boot it up front.
  boot_log=$(perl -e 'alarm 300; exec @ARGV' xcrun simctl boot $SIM 2>&1) || {
    rc=$?; echo $boot_log
    echo "::error::simctl boot failed (exit $rc; 142 = no answer within 5 minutes). CoreSimulator is probably wedged on this runner: run 'xcrun simctl shutdown all; killall -9 com.apple.CoreSimulator.CoreSimulatorService; pkill -9 -f launchd_sim', then boot an existing simulator to verify. See docs/troubleshooting.md"
    exit 1
  }
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
  step "Test $SCHEME (simulator $SIM, time limit $(( TEST_TIMEOUT / 60 )) min)"
  # Tests launch the app as the test host, so it needs its entitlements (CloudKit etc. abort without them).
  # Sign ad hoc ("Sign to Run Locally") — works on the simulator without any certificate or profile.
  ADHOC=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
  rc=0
  XCB_TIMEOUT=$TEST_TIMEOUT xcb test test "${PROJ_ARGS[@]}" -scheme "$SCHEME" -derivedDataPath $DD "${ADHOC[@]}" \
    -destination "id=$SIM" -parallel-testing-enabled NO "${SKIP[@]}" || rc=$?
  if (( rc == 0 )); then
    endstep; RESULT="tests passed"
  elif (( rc == 124 )); then
    exit 1   # hard time limit; xcb printed the error, cleanup deletes the simulator and releases the lock
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
