#!/bin/zsh
# Register self-hosted runners on this Mac for a repo (LaunchAgents, start at login).
# Two per repo:  ~/actions-runners/<repo>         label macos-xcode    builds / TestFlight
#                ~/actions-runners/<repo>-review  label claude-review  Claude review only, never blocks builds
# Usage: runner-add.sh <repo> [<repo> ...]     (already-installed runners are skipped)
#        runner-add.sh --remove <repo>        removes both runners of the repo
# Personal accounts can only register repo-level runners, hence one pair per repo.
# PRIVATE REPOS ONLY: on a public repo anyone's fork PR could run code on this Mac.
set -euo pipefail
source ${0:A:h}/_config.sh
BASE=$HOME/actions-runners
DIST=$BASE/_dist/runner.tar.gz

fetch_runner() {
  [[ -f $DIST ]] && gzip -t $DIST 2>/dev/null && return
  mkdir -p ${DIST:h}
  local v=$(gh api repos/actions/runner/releases/latest -q .tag_name | sed 's/^v//')
  echo "Downloading actions runner $v …"
  curl -fSL --retry 3 -o $DIST "https://github.com/actions/runner/releases/download/v$v/actions-runner-osx-arm64-$v.tar.gz"
  gzip -t $DIST
}

remove_one() {
  local repo=$1 dir=$2
  [[ -d $dir ]] || return 0
  (cd $dir && ./svc.sh stop >/dev/null 2>&1; ./svc.sh uninstall >/dev/null 2>&1 || true)
  local tok=$(gh api -X POST repos/$GH_OWNER/$repo/actions/runners/remove-token -q .token)
  (cd $dir && ./config.sh remove --token "$tok")
  rm -rf $dir
  echo "$repo: removed ${dir:t}"
}

add_one() {  # add_one <repo> <dir> <name suffix> <label>
  local repo=$1 dir=$2 suffix=$3 label=$4
  if [[ -f $dir/.runner ]]; then echo "$repo: ${dir:t} already installed"; return; fi
  mkdir -p $dir && tar xzf $DIST -C $dir
  local tok=$(gh api -X POST repos/$GH_OWNER/$repo/actions/runners/registration-token -q .token)
  (cd $dir && ./config.sh --unattended --replace \
      --url https://github.com/$GH_OWNER/$repo --token "$tok" \
      --name "$(scutil --get LocalHostName)-$repo$suffix" --labels $label --work _work) >/dev/null
  # xcode-select often points at CommandLineTools; give jobs a real Xcode.
  echo "DEVELOPER_DIR=$XCODE_APP/Contents/Developer" >> $dir/.env
  # NOTE: svc.sh's LaunchAgent sets SessionCreate=true. Keep it: jobs then run in their own security
  # session and cannot read your unlocked login keychain. Signing uses ci.keychain instead.
  (cd $dir && ./svc.sh install >/dev/null && ./svc.sh start >/dev/null)
  echo "$repo: ${dir:t} started ($label)"
}

add() {
  local repo=$1
  if [[ $(gh repo view $GH_OWNER/$repo --json visibility -q .visibility) != PRIVATE ]]; then
    echo "$repo: not a private repo — refusing to attach a self-hosted runner"; return
  fi
  add_one $repo $BASE/$repo "" macos-xcode
  add_one $repo $BASE/$repo-review -review claude-review
}

if [[ ${1:-} == --remove ]]; then
  shift; for r in "$@"; do remove_one $r $BASE/$r; remove_one $r $BASE/$r-review; done; exit
fi
[[ $# -gt 0 ]] || { sed -n '2,8p' $0; exit 1; }
fetch_runner
for r in "$@"; do add $r; done
