# Shared by testflight.sh and check.sh: pick Xcode, find the project/scheme, wrap xcodebuild.
WORK=$RUNNER_TEMP/ios-ci
DD=$WORK/DerivedData
SPM_CACHE=$HOME/actions-runners/_cache/spm/${GITHUB_REPOSITORY//\//_}
rm -rf $WORK && mkdir -p $WORK $DD $SPM_CACHE
# Keep SPM checkouts at Xcode's default DerivedData/SourcePackages but point it at a persistent cache.
# (Run scripts such as Crashlytics look for ${BUILD_DIR%/Build/*}/SourcePackages, so
#  -clonedSourcePackagesDirPath breaks them.)
ln -s $SPM_CACHE $DD/SourcePackages

step() { echo "::group::$1"; }
endstep() { echo "::endgroup::"; }
# Run a command in the background in its own process group and wait for it, so the caller's signal traps fire
# right away (zsh defers traps while a foreground child runs) and stop_bg can kill the command with everything
# it spawned. Options: -t SECONDS hard time limit (TERM the group, KILL 15 s later, return 124);
# -o FILE / -e FILE redirect the command's stdout / stderr (-o alone sends both there) — redirect this way
# rather than on the run_bg call, or a trap's own output would land in the file too.
run_bg() {
  local limit=0 out='' err=''
  while [[ ${1:-} == -[toe] ]]; do case $1 in -t) limit=$2;; -o) out=$2;; -e) err=$2;; esac; shift 2; done
  if [[ -n $out && -n $err ]]; then perl -MPOSIX -e 'setpgid(0,0); exec @ARGV' "$@" > $out 2> $err &
  elif [[ -n $out ]]; then perl -MPOSIX -e 'setpgid(0,0); exec @ARGV' "$@" > $out 2>&1 &
  elif [[ -n $err ]]; then perl -MPOSIX -e 'setpgid(0,0); exec @ARGV' "$@" 2> $err &
  else perl -MPOSIX -e 'setpgid(0,0); exec @ARGV' "$@" &
  fi
  BG_PID=$!; BG_WATCHDOG=''
  local flag=$WORK/.timed-out.$BG_PID
  if (( limit > 0 )); then
    # One perl process (so it can be killed cleanly). Before firing it checks the pid is still our child, in
    # case this watchdog outlived the script and the pid was recycled.
    perl -e '($t,$pg,$parent,$flag)=@ARGV; sleep $t; exit unless qx(ps -o ppid= -p $pg) =~ /^\s*$parent\s*$/;
             open F,">",$flag; close F; kill TERM => -$pg; sleep 15; kill KILL => -$pg' $limit $BG_PID $$ $flag &
    BG_WATCHDOG=$!
  fi
  local rc=0; wait $BG_PID || rc=$?
  BG_PID=''
  [[ -n $BG_WATCHDOG ]] && kill -KILL $BG_WATCHDOG 2>/dev/null; BG_WATCHDOG=''
  [[ -e $flag ]] && { rm -f $flag; return 124; }
  return $rc
}
# Stop the command run_bg is waiting for (its whole process group: TERM, up to 5 s, then KILL) and its
# watchdog. Called from signal traps, where run_bg's `wait` has not returned yet.
stop_bg() {
  [[ -n ${BG_WATCHDOG:-} ]] && kill -KILL $BG_WATCHDOG 2>/dev/null; BG_WATCHDOG=''
  [[ -n ${BG_PID:-} ]] || return 0
  kill -TERM -- -$BG_PID 2>/dev/null
  local i; for i in {1..20}; do kill -0 $BG_PID 2>/dev/null || break; sleep 0.25; done
  kill -KILL -- -$BG_PID 2>/dev/null
  BG_PID=''
}
# Full xcodebuild output goes to a file; on failure print the error lines and the tail.
# XCB_TIMEOUT (seconds, optional) is a hard time limit: on it xcb prints an error and returns 124.
xcb() {
  local name=$1 log=$WORK/$1.log; shift
  local rc=0
  run_bg -t ${XCB_TIMEOUT:-0} -o $log xcodebuild "$@" || rc=$?
  if (( rc == 124 )); then
    endstep
    echo "::error::xcodebuild $name did not finish within $(( XCB_TIMEOUT / 60 )) minutes (hard time limit) and was stopped ($log)"
    tail -30 $log
    return 124
  fi
  if (( rc != 0 )); then
    endstep
    echo "::error::xcodebuild failed ($log)"
    grep -E ' error: |^error: |\*\* .* FAILED|Failing tests:|\) failed \(|No such file or directory|command not found' $log | sort -u | head -40 || true
    echo '----- end of log -----'; tail -60 $log
    return 1
  fi
  tail -3 $log
}

source ${0:A:h}/xcode.sh

free_gb=$(( $(df -k $RUNNER_TEMP | awk 'NR==2{print $4}') / 1024 / 1024 ))
if (( free_gb < ${MIN_FREE_GB:-8} )); then
  echo "::error::Only ${free_gb}GB free, need ${MIN_FREE_GB:-8}GB. Clean ~/Library/Developer/Xcode/DerivedData."
  exit 1
fi

if [[ -z ${PROJECT:-} ]]; then
  candidates=(*.xcworkspace(N) *.xcodeproj(N))
  (( ${#candidates} )) || { echo "::error::No .xcworkspace/.xcodeproj at the repo root; set the project input"; exit 1; }
  PROJECT=${candidates[1]}
fi
[[ $PROJECT == *.xcworkspace ]] && PROJ_ARGS=(-workspace $PROJECT) || PROJ_ARGS=(-project $PROJECT)

# Several scheme candidates (space separated): use the first one this branch has.
# Handy when one repo hosts two apps on different long-lived branches.
if [[ $SCHEME == *' '* ]]; then
  available=(${(f)"$(xcodebuild "${PROJ_ARGS[@]}" -list -json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print("\n".join((d.get("project") or d.get("workspace"))["schemes"]))')"})
  picked=''
  for c in ${=SCHEME}; do (( ${available[(Ie)$c]} )) && { picked=$c; break; }; done
  [[ -z $picked ]] && { echo "::error::None of the schemes ($SCHEME) exist on this branch (found: $available)"; exit 1; }
  echo "Scheme: $picked (candidates: $SCHEME)"
  SCHEME=$picked
fi
BRANCH_LABEL=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ -z $BRANCH_LABEL || $BRANCH_LABEL == HEAD ]]; then BRANCH_LABEL=$GITHUB_REF_NAME; fi
