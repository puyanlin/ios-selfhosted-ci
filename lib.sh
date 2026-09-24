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
# Full xcodebuild output goes to a file; on failure print the error lines and the tail.
xcb() {
  local log=$WORK/$1.log; shift
  if ! xcodebuild "$@" > $log 2>&1; then
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
