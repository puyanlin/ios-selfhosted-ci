#!/bin/zsh
# Called by check/action.yml: unsigned build or simulator tests for pull requests. Never signs or uploads.
set -euo pipefail
zmodload zsh/datetime
START=$EPOCHSECONDS
MIN_FREE_GB=5
source ${0:A:h}/lib.sh

# Hard time limit for the test phase itself, counted from when xcodebuild test starts: a hang guard that
# works even when no cancel ever arrives. The job's timeout-minutes (40 in the reusable workflow) still
# bounds the whole job — lock wait and simulator boot included — and its cancel runs the same cleanup.
TEST_TIMEOUT=${TEST_TIMEOUT_SECONDS:-$(( ${TEST_TIMEOUT_MINUTES:-35} * 60 ))}
LOCK=$HOME/actions-runners/_locks/simulator-tests
# A holder records its own deadline in the lock: start + every time-boxed step it may run while holding it
# (simctl create 120 s, boot 300 s, bootstatus 300 s, xcodebuild -list 300 s, its TEST_TIMEOUT, the 15 s
# kill grace, and the time-boxed cleanup) — so waiters never judge a slow but healthy job by their own limits.
LOCK_MARGIN=$(( 120 + 300 + 300 + 300 + 15 + 120 ))

# --- cleanup --------------------------------------------------------------------------------------------
# When GitHub cancels the job (new commit, timeout, runner lost), the runner sends this process SIGINT,
# SIGTERM 7.5 s later and SIGKILL 2.5 s after that — and signals nothing else, so xcodebuild and the
# simulator would live on for hours holding the lock. On a signal: stop the running child's process group,
# release the lock at once, and hand the slow simulator cleanup to a detached process that survives SIGKILL.
# Every long-running child (simctl, xcodebuild) goes through run_bg so traps fire while it runs.
SIM='' SIM_NAME='' LOCK_HELD='' STOPPED_BY='' PARENT_WATCHDOG='' CLEANED=''
simctl_quiet() { perl -e 'alarm 60; exec @ARGV' xcrun simctl "$@" >/dev/null 2>&1 || true; }
release_lock() {
  local info; info=$(cat $LOCK/info 2>/dev/null || true)
  if [[ -n $LOCK_HELD && ${info%% *} == $$ ]]; then rm -rf $LOCK; fi   # only if it is still our lock
  LOCK_HELD=''
}
cleanup() {
  [[ -n $CLEANED ]] && return 0; CLEANED=1
  set +e; trap '' INT TERM HUP
  stop_bg
  [[ -n $PARENT_WATCHDOG ]] && kill -KILL $PARENT_WATCHDOG 2>/dev/null
  # Anything started but not recorded yet (a signal can land between `cmd &` and `PID=$!`): kill the
  # remaining direct children and, for process-group leaders such as xcodebuild, their whole group.
  local p; for p in ${(f)"$(pgrep -P $$)"}; do kill -KILL -- -$p $p 2>/dev/null; done
  # The simulator by UDID, or by its unique name if we were stopped before simctl create answered.
  local dev=${SIM:-$SIM_NAME}
  rm -rf $LOCK.new.$$
  if [[ -n $STOPPED_BY ]]; then
    release_lock
    # DerivedData lives at the same path for every job on this runner, so rename it now (instant) and let the
    # detached process delete the renamed copy — deleting $DD minutes later could hit the next job's build.
    local trash=''
    if [[ -d $DD ]]; then trash=$DD.trash.$$; mv $DD $trash 2>/dev/null || trash=''; fi
    # Own session, HUP ignored: finishes even after the runner kills this process. Each simctl call is time-boxed.
    perl -MPOSIX -e '$SIG{HUP}="IGNORE"; setsid(); exec @ARGV' zsh -c '
      if [[ -n $1 ]]; then
        perl -e "alarm 60; exec @ARGV" xcrun simctl shutdown $1
        perl -e "alarm 60; exec @ARGV" xcrun simctl delete $1
      fi
      [[ -n $2 ]] && rm -rf $2' _ "$dev" "$trash" </dev/null >/dev/null 2>&1 &
  else
    [[ -n $dev ]] && simctl_quiet shutdown $dev
    release_lock
    [[ -n $dev ]] && simctl_quiet delete $dev
    rm -rf $DD
  fi
  return 0
}
trap cleanup EXIT
on_signal() {  # on_signal <signal> <exit code>
  trap '' INT TERM HUP
  STOPPED_BY=$1
  echo "::error::Stopped by SIG$1 (job cancelled or runner gone): stopping xcodebuild, releasing the simulator lock"
  # Clean up right here: inside a function zsh defers `exit` until the interrupted `wait` in run_bg returns,
  # and that only happens once cleanup has stopped the child. (cleanup runs once; the EXIT trap is a no-op.)
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
  # can take forever. Builds still run in parallel; only this phase is serialized (lock taken by atomic rename).
  # $LOCK/info records the holder (pid, the runner process that started it, start time, deadline, run URL)
  # in one line, so a lock left behind by a dead or orphaned job is recognised and removed instead of
  # blocking everyone for 30 min.
  mkdir -p ${LOCK:h}
  # Acquire with rename(2): our lock dir is prepared with its info inside and renamed into place in one
  # step. rename fails while another non-empty lock dir exists (and replaces an empty one, which is never a
  # live lock), so a lock is never seen without its info. (mv would move a dir *into* an existing one.)
  rename_dir() { perl -e 'rename $ARGV[0], $ARGV[1] or exit 1' "$1" "$2"; }
  run_url="local run"
  [[ -n ${GITHUB_RUN_ID:-} ]] && run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
  parent_field=-; (( PPID > 1 )) && parent_field=$PPID
  NEW=$LOCK.new.$$; rm -rf $NEW; mkdir $NEW
  waited=0
  while :; do
    print -r -- "$$ $parent_field $EPOCHSECONDS $(( EPOCHSECONDS + TEST_TIMEOUT + LOCK_MARGIN )) $run_url" > $NEW/info
    rename_dir $NEW $LOCK && break
    snapshot=$(cat $LOCK/info $LOCK/pid 2>/dev/null || true)   # what we judge; re-read before acting on it
    read -r holder parent started deadline run <<< "$(cat $LOCK/info 2>/dev/null)"
    [[ -z ${holder:-} ]] && holder=$(cat $LOCK/pid 2>/dev/null || true)   # lock from the previous check.sh (pid file only)
    [[ -z ${started:-} ]] && started=$(stat -f %m $LOCK 2>/dev/null || echo $EPOCHSECONDS)   # no info: use the dir's age
    age=$(( EPOCHSECONDS - started ))
    stale=''
    if [[ -z ${holder:-} ]]; then (( age > 60 )) && stale="no holder recorded after $age s"   # neither info nor pid
    elif ! kill -0 $holder 2>/dev/null; then stale="pid $holder is gone"
    elif [[ $(ps -o command= -p $holder 2>/dev/null) != *check.sh* ]]; then stale="pid $holder is no longer check.sh"
    elif [[ ${parent:--} != - ]] && ! kill -0 $parent 2>/dev/null; then stale="the runner process that started pid $holder is gone"
    elif (( EPOCHSECONDS > ${deadline:-$(( started + TEST_TIMEOUT + LOCK_MARGIN ))} )); then stale="held for $(( age / 60 )) min, past the deadline the holder recorded"
    fi
    if [[ -n $stale ]]; then
      # Take it atomically: re-read (the lock may have changed hands since the snapshot), rename (only one
      # waiter can win), make sure what we renamed is still the lock we judged, and only then delete it.
      [[ "$(cat $LOCK/info $LOCK/pid 2>/dev/null)" == "$snapshot" ]] || { sleep 1; continue; }
      if rename_dir $LOCK $LOCK.stale.$$ 2>/dev/null; then
        moved=$(cat $LOCK.stale.$$/info 2>/dev/null || cat $LOCK.stale.$$/pid 2>/dev/null || true)
        if [[ ${moved%% *} == ${holder:-} ]]; then
          echo "Removing stale simulator lock: $stale (${run:-unknown run})"; rm -rf $LOCK.stale.$$
        else
          # Someone else's fresh lock: give it back with the same atomic rename; if yet another lock appeared
          # meanwhile that holder loses its entry (it will not remove anyone else's lock at exit).
          rename_dir $LOCK.stale.$$ $LOCK 2>/dev/null || rm -rf $LOCK.stale.$$
          sleep 1
        fi
      fi
      continue
    fi
    (( waited % 60 == 0 )) && echo "Waiting for another job's simulator tests to finish (pid ${holder:-?}, ${run:-unknown run}, held for $(( age / 60 )) min)…"
    sleep 5; (( waited += 5 ))
    (( waited > 1800 )) && { rm -rf $NEW; echo "::error::Waited 30 minutes for the simulator lock, held by pid ${holder:-?} (${run:-unknown run}). See docs/troubleshooting.md"; exit 1; }
  done
  LOCK_HELD=1
  SIM_NAME="ci-${GITHUB_RUN_ID:-local}-$$"
  run_bg -t 120 -o $WORK/sim-udid.txt -e $WORK/simctl-create.log xcrun simctl create $SIM_NAME $DEVTYPE $RUNTIME \
    || { rc=$?; cat $WORK/simctl-create.log; echo "::error::simctl create failed (exit $rc)"; exit 1; }
  SIM=$(<$WORK/sim-udid.txt)
  # A fresh device's first boot can take longer than xcodebuild's 60 s; boot it up front (5 min limit each).
  run_bg -t 300 -o $WORK/simctl-boot.log xcrun simctl boot $SIM || {
    rc=$?; cat $WORK/simctl-boot.log
    echo "::error::simctl boot failed (exit $rc; 124 = no answer within 5 minutes). CoreSimulator is probably wedged on this runner: run 'xcrun simctl shutdown all; killall -9 com.apple.CoreSimulator.CoreSimulatorService; pkill -9 -f launchd_sim', then boot an existing simulator to verify. See docs/troubleshooting.md"
    exit 1
  }
  if ! run_bg -t 300 -o /dev/null xcrun simctl bootstatus $SIM; then
    echo "::error::Simulator did not finish booting within 5 minutes"; exit 1
  fi
  echo "Simulator: ${DEVTYPE##*.} / ${RUNTIME##*.} ($SIM)"
  SKIP=()
  if [[ ${SKIP_UI_TESTS:-true} == true ]]; then
    # UI tests (and Xcode's template testLaunchPerformance) are slow and flaky on CI; run unit tests only.
    run_bg -t 300 -o $WORK/targets.json -e /dev/null xcodebuild "${PROJ_ARGS[@]}" -list -json || true
    for t in ${(f)"$(python3 -c 'import json,sys;d=json.load(sys.stdin);print("\n".join(t for t in (d.get("project") or {}).get("targets",[]) if t.endswith("UITests")))' < $WORK/targets.json 2>/dev/null)"}; do
      SKIP+=(-skip-testing:$t)
    done
  fi
  for t in ${=SKIP_TESTING:-}; do SKIP+=(-skip-testing:$t); done
  (( ${#SKIP} )) && echo "Skipping: ${SKIP[*]//-skip-testing:/}"
  echo "Time used so far: $(( (EPOCHSECONDS - START) / 60 )) min (lock wait $(( waited / 60 )) min); the job's timeout-minutes covers the whole job"
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
    # The build needs neither the simulator nor the lock: hand both back before it starts.
    simctl_quiet shutdown $SIM; release_lock; simctl_quiet delete $SIM; SIM='' SIM_NAME=''
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
