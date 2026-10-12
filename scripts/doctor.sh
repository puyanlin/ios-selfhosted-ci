#!/bin/zsh
# Check this Mac's runner environment, or compare it with another runner Mac.
# Usage: doctor.sh                     this Mac: what the jobs will see, and what's broken
#        doctor.sh --compare <host> [<clone dir on host>]
#                                      side by side with <host> (ssh with key auth), differences marked ≠
# Read-only. Prints no secrets (key IDs and certificate names only).
# Several Macs share the same runner labels and GitHub hands each job to whichever is idle, so a difference
# here (another Xcode build, a missing simulator runtime) shows up as a PR that passes on one Mac and fails
# on the other.
set -uo pipefail

probe() {
  local cfg=${IOS_SELFHOSTED_CI_CONFIG:-$HOME/.config/ios-selfhosted-ci/config} ci=${DOCTOR_CI_DIR:-}
  # Piped over ssh there is no script path to start from, so look in the usual places.
  if [[ -z $ci ]]; then
    for d in ~/ios-selfhosted-ci ~/*/ios-selfhosted-ci(N/) ~/*/*/ios-selfhosted-ci(N/) ~/*/*/*/ios-selfhosted-ci(N/); do
      [[ -d $d/.git ]] && { ci=$d; break; }
    done
  fi
  [[ $ci == '~/'* ]] && ci=$HOME/${ci#'~/'}   # a path given for the other Mac, expanded there
  [[ -n $ci && ! -d $ci/.git ]] && ci=""
  local XCODE_APP=/Applications/Xcode.app XCODE_BETA_APP=
  [[ -f $cfg ]] && eval "$(grep -E '^XCODE_(BETA_)?APP=' $cfg)"
  xbuild() { /usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' $1/Contents/version.plist 2>/dev/null; }
  # Resolve tools with the PATH the runners captured at install (.path), not this shell's: with two installs
  # (say Homebrew's claude and the native one in ~/.local/bin) they can pick different ones.
  local jobpath=$PATH p; for p in ~/actions-runners/*/.path(N); do jobpath=$(<$p); break; done
  ver() { local b; b=$(PATH=$jobpath whence -p $1) || { echo missing; return; }; $b --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1; }

  echo "host=$(scutil --get LocalHostName)"
  echo "macos=$(sw_vers -productVersion) $(uname -m)"
  [[ -d $XCODE_APP ]] && echo "xcode=$XCODE_APP $(xbuild $XCODE_APP)" || echo "xcode=MISSING $XCODE_APP"
  if [[ -z $XCODE_BETA_APP ]]; then echo "xcode_beta=(not set)"
  elif [[ -d $XCODE_BETA_APP ]]; then echo "xcode_beta=$XCODE_BETA_APP $(xbuild $XCODE_BETA_APP)"
  else echo "xcode_beta=MISSING $XCODE_BETA_APP"; fi
  # Every Xcode xcode.sh can find counts (Spotlight, so one left in ~/Downloads too): `xcode: 27.1` and
  # .xcode-version pick the newest match on each Mac.
  local apps=(${(f)"$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null)"} /Applications/Xcode*.app(N))
  local all=() x
  for x in ${(u)apps}; do [[ -f $x/Contents/version.plist ]] && all+=("$(defaults read $x/Contents/Info CFBundleShortVersionString 2>/dev/null) ($(xbuild $x))"); done
  all=(${(uo)all}); echo "xcodes_installed=${(j:, :)all}"
  echo "ios_runtimes=$(DEVELOPER_DIR=$XCODE_APP/Contents/Developer xcrun simctl list runtimes 2>/dev/null \
    | sed -nE 's/^iOS ([0-9.]+) \([0-9.]+ - ([A-Za-z0-9]+)\).*/\1 (\2)/p' | sort | paste -sd, -)"
  for t in gh claude bun asc python3 git; do echo "$t=$(ver $t)"; done
  if [[ -n $ci ]]; then
    local ref=${CI_REF:-v1} r=   # like _config.sh: the config wins, else the environment, else v1
    [[ -f $cfg ]] && r=$(sed -nE 's/^CI_REF=([^[:space:]#]+).*/\1/p' $cfg | tr -d '"' | tail -1)
    [[ -n $r ]] && ref=$r
    # Full hashes; a clone ahead of the ref (main with commits not tagged yet) is fine, only behind is stale.
    local refsha=$(git -C $ci ls-remote origin "refs/tags/$ref" "refs/tags/$ref^{}" "refs/heads/$ref" 2>/dev/null | tail -1 | cut -f1)
    local head=$(git -C $ci rev-parse HEAD) state
    if [[ -z $refsha ]]; then state="unknown (can't reach origin)"
    elif [[ $head == $refsha ]]; then state="at $ref"
    elif git -C $ci merge-base --is-ancestor $refsha HEAD 2>/dev/null; then state="ahead of $ref"
    else state="behind $ref"; fi
    echo "ci_repo=$state, ${head:0:7}$([[ -n $(git -C $ci status --porcelain) ]] && echo ' +local changes')"
  else
    echo "ci_repo=MISSING"
  fi
  # Values only, comments stripped; machine-specific paths will show up as a difference, which is the point.
  [[ -f $cfg ]] && echo "config=$(grep -E '^[A-Z_]+=' $cfg | sed -E 's/[[:space:]]+#.*$//' | sort | md5 | cut -c1-8)" \
                || echo "config=MISSING"
  local kc=~/Library/Keychains/ci.keychain-db
  if [[ -f $kc ]]; then
    # Development identities are per Mac by design; Distribution identities should be the same everywhere.
    echo "signing_distribution=$(security find-identity -v -p codesigning $kc | grep -oE '"Apple Distribution: [^"]+"' | tr -d '"' | sort -u | paste -sd, -)"
    echo "signing_development=$(security find-identity -v -p codesigning $kc | grep -c '"Apple Development:') identities"
  else
    echo "signing_distribution=NO ci.keychain"; echo "signing_development=NO ci.keychain"
  fi
  echo "asc_keys=$(grep -hs '^ASC_KEY_ID=' ~/.appstoreconnect/ci*.env | cut -d= -f2 | sort -u | paste -sd, -)"
  local runners=(~/actions-runners/*/.runner(N)) listeners=(~/actions-runners/*/bin/Runner.Listener(N))
  # Count live listener processes rather than launchd jobs: that's what actually takes jobs, and it reads the
  # same over ssh as in a GUI session.
  echo "runners=${#runners} registered, $(pgrep -f 'actions-runners/.*/bin/Runner.Listener' | wc -l | tr -d ' ') running"
  echo "runner_version=$( (( ${#listeners} )) && ${listeners[1]} --version 2>/dev/null || echo none)"
  echo "disk_free_gb=$(( $(df -k ~ | awk 'NR==2{print $4}') / 1024 / 1024 ))"
  echo "jobs_running=$(pgrep -f Runner.Worker | wc -l | tr -d ' ')"
}

# Per-machine by nature: never a mismatch.
INFO=(host disk_free_gb jobs_running signing_development)
# Worth saying, but not a problem with the Mac: doesn't count towards the exit status.
NOTES=(jobs_running)

problems() {  # problems <key> <value>: what's wrong with one value on its own
  case $1 in
    xcode|xcode_beta) [[ $2 == MISSING* ]] && echo "path in the config doesn't exist" ;;
    ci_repo) [[ $2 == MISSING ]] && echo "clone not found: DOCTOR_CI_DIR=<dir> here, or --compare <host> <dir> for the other Mac"
             [[ $2 == behind* ]] && echo "doesn't contain ${${2#behind }%%,*}: git pull --ff-only on main"
             [[ $2 == *local* ]] && echo "uncommitted changes" ;;
    config) [[ $2 == MISSING ]] && echo "no ~/.config/ios-selfhosted-ci/config" ;;
    signing_distribution) [[ $2 == NO* ]] && echo "run scripts/ci-signing-setup.sh keychain" ;;
    asc_keys) [[ -z $2 ]] && echo "no API key (TestFlight jobs will fail): scripts/ci-signing-setup.sh asc" ;;
    runners) local r=${2%% *} s=${${2#*, }%% *}; (( r > s )) && echo "$((r - s)) runner(s) not running (./svc.sh start in its folder)" ;;
    disk_free_gb) (( $2 < 20 )) && echo "low; jobs refuse to start under ${MIN_FREE_GB:-8} GB" ;;
    jobs_running) (( $2 > 0 )) && echo "don't upgrade or clean up on this Mac right now" ;;
    *) [[ $2 == missing ]] && echo "not installed" ;;
  esac
}

# Over ssh the login shell may print its own lines first; the marker keeps them out of the results.
[[ ${1:-} == --probe ]] && { probe | sed 's/^/doctor:/'; exit; }
DOCTOR_CI_DIR=${DOCTOR_CI_DIR:-${0:A:h:h}}
typeset -A A B; typeset -a KEYS
while IFS='=' read -r k v; do KEYS+=$k; A[$k]=$v; done < <(DOCTOR_CI_DIR=$DOCTOR_CI_DIR probe)
issues=0

if [[ ${1:-} != --compare ]]; then
  for k in $KEYS; do
    printf '%-22s %s\n' $k "${A[$k]}"
    for p in "${(@f)$(problems $k "${A[$k]}")}"; do
      [[ -n $p ]] && { printf '%-22s ⚠️  %s\n' '' "$p"; (( ${NOTES[(Ie)$k]} )) || (( issues++ )); }
    done
  done
  (( issues )) && echo "\n$issues issue(s)." || echo "\nNo issues."
  exit $(( issues > 0 ))
fi

host=${2:?usage: doctor.sh --compare <ssh-host> [<clone dir on host>]}
remote=$(ssh -o BatchMode=yes -o ConnectTimeout=10 $host "${3:+DOCTOR_CI_DIR=${(q)3} }zsh -l -s -- --probe" < $0) || { echo "Can't reach $host over ssh."; exit 2; }
while IFS='=' read -r k v; do B[${k#doctor:}]=$v; done < <(grep '^doctor:' <<< $remote)
[[ -n ${B[host]:-} ]] || { echo "No probe output from $host."; exit 2; }
w=$(( COLUMNS > 100 ? (COLUMNS - 28) / 2 : 36 ))
printf "%-22s %-${w}.${w}s   %s\n" '' "${A[host]}" "${B[host]}"
for k in $KEYS; do
  [[ $k == host ]] && continue
  mark=' '
  a=${A[$k]} b=${B[$k]}
  [[ $k == ci_repo ]] && { a=${a%%,*}; b=${b%%,*}; }   # where it stands vs the ref, not the exact commit
  if (( ! ${INFO[(Ie)$k]} )) && [[ $a != $b ]]; then
    mark='≠'; (( issues++ ))
  fi
  printf "%s %-20s %-${w}.${w}s   %s\n" $mark $k "${A[$k]}" "${B[$k]}"
  for side in A B; do
    name=${${(P)side}[host]}; val=${${(P)side}[$k]}
    for p in "${(@f)$(problems $k "$val")}"; do
      [[ -n $p ]] && { printf '  %-20s ⚠️  %s: %s\n' '' $name "$p"; (( ${NOTES[(Ie)$k]} )) || (( issues++ )); }
    done
  done
done
(( issues )) && echo "\n$issues difference(s)/issue(s). Align the older side with the newer one; Xcode, macOS and simulator runtimes by hand." \
             || echo "\nBoth Macs match."
exit $(( issues > 0 ))
