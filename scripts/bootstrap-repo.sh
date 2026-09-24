#!/bin/zsh
# Set up one private iOS app repo in one go: self-hosted runners, the PR check / TestFlight / Claude review
# caller workflows, a "PR check must pass" ruleset, then run the PR check once to verify. Safe to re-run
# (existing pieces are skipped; unchanged workflow files are not re-committed).
#
# Usage: bootstrap-repo.sh <repo> [--scheme "A B"] [--project path/X.xcodeproj] [--destination device]
#                                 [--branch other-long-lived-branch]... [--review-language "Traditional Chinese"]
#   --scheme       auto-detected when omitted; several space-separated candidates = each branch uses the one it has
#   --project      only needed when the project is not at the repo root
#   --destination  device = PR check builds for device (unsigned); use when an SDK lacks an arm64 simulator slice
#   --branch       extra long-lived branches that also get the workflows and the ruleset
set -euo pipefail
source ${0:A:h}/_config.sh
TEMPLATES=${0:A:h}/../templates

repo=${1:?usage: bootstrap-repo.sh <repo> [options]}; shift
scheme=""; project=""; destination=""; language=""; branches=()
while (( $# )); do
  case $1 in
    --scheme) scheme=$2; shift 2 ;;
    --project) project=$2; shift 2 ;;
    --destination) destination=$2; shift 2 ;;
    --review-language) language=$2; shift 2 ;;
    --branch) branches+=$2; shift 2 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done
R=$GH_OWNER/$repo
say() { print -P "%B==> $1%b"; }

[[ $(gh repo view $R --json visibility -q .visibility) == PRIVATE ]] || { echo "$repo is not private — refusing (fork PRs could run code on this Mac)"; exit 1; }
default=$(gh repo view $R --json defaultBranchRef -q .defaultBranchRef.name)
all_branches=($default $branches)
tmp=$(mktemp -d); trap 'rm -rf $tmp' EXIT

say "Runners"
${0:A:h}/runner-add.sh $repo

if [[ -z $scheme || -z $project ]]; then
  say "Detecting project and scheme ($default)"
  git clone -q --depth 1 -b $default https://github.com/$R $tmp/src
  if [[ -z $project ]]; then
    root=($tmp/src/*.xcworkspace(N) $tmp/src/*.xcodeproj(N))
    if (( ! ${#root} )); then
      found=($tmp/src/*/*.xcworkspace(N) $tmp/src/*/*.xcodeproj(N) $tmp/src/*/*/*.xcodeproj(N))
      (( ${#found} )) || { echo "no .xcodeproj / .xcworkspace found"; exit 1; }
      project=${found[1]#$tmp/src/}; root=($found[1])
    fi
    [[ -f $tmp/src/Podfile && ! -d $tmp/src/Pods ]] && { echo "This repo uses CocoaPods without committed Pods/ — install CocoaPods on the runner or migrate to SPM first"; exit 1; }
  fi
  if [[ -z $scheme ]]; then
    p=${project:+$tmp/src/$project}; p=${p:-$root[1]}
    [[ $p == *.xcworkspace ]] && flag=-workspace || flag=-project
    schemes=(${(f)"$(DEVELOPER_DIR=$XCODE_APP/Contents/Developer xcodebuild $flag $p -list -json 2>/dev/null \
      | python3 -c 'import json,sys;d=json.load(sys.stdin);print("\n".join((d.get("project") or d.get("workspace"))["schemes"]))')"})
    name=${${p:t}:r}
    if (( ${schemes[(Ie)$repo]} )); then scheme=$repo
    elif (( ${schemes[(Ie)$name]} )); then scheme=$name
    else
      apps=(${schemes:#*(Tests|UITests|Watch|Widget|Extension|Kit|Notification|Sticker|TV|tvOS)*})
      scheme=${apps[1]:-$schemes[1]}
    fi
    echo "scheme: $scheme (all: ${(j:, :)schemes})"
  fi
fi

render() {  # render <template>
  local with="" review_with=""
  [[ -n $project ]] && with+="      project: $project"$'\n'
  [[ $1 == pr-check && -n $destination ]] && with+="      destination: $destination"$'\n'
  if [[ $1 == claude-review ]]; then
    local c=$(command -v claude || true) b=$(command -v bun || true)
    [[ -n $c || -n $b || -n $language ]] && review_with="    with:"$'\n'
    [[ -n $c ]] && review_with+="      claude-path: $c"$'\n'
    [[ -n $b ]] && review_with+="      bun-path: $b"$'\n'
    [[ -n $language ]] && review_with+="      language: $language"$'\n'
  fi
  WITH=${with%$'\n'} REVIEW_WITH=${review_with%$'\n'} awk \
    -v scheme="$scheme" -v ci_repo="$CI_REPO" -v ci_ref="$CI_REF" -v team="$TEAM_ID" -v xcode="$XCODE_APP" '
    { gsub(/__SCHEME__/, scheme); gsub(/__CI_REPO__/, ci_repo); gsub(/__CI_REF__/, ci_ref); gsub(/__TEAM_ID__/, team); gsub(/__XCODE_APP__/, xcode) }
    /^__WITH__$/ { if (ENVIRON["WITH"] != "") print ENVIRON["WITH"]; next }
    /^__REVIEW_WITH__$/ { if (ENVIRON["REVIEW_WITH"] != "") print ENVIRON["REVIEW_WITH"]; next }
    { print }' $TEMPLATES/$1.yml
}

say "Workflows → ${(j:, :)all_branches}"
for br in $all_branches; do
  for wf in pr-check testflight claude-review; do
    fp=.github/workflows/$wf.yml
    render $wf > $tmp/$wf.yml
    sha=$(gh api "repos/$R/contents/$fp?ref=$br" -q .sha 2>/dev/null) || sha=""
    if [[ -n $sha && "$(gh api "repos/$R/contents/$fp?ref=$br" -H 'Accept: application/vnd.github.raw')" == "$(cat $tmp/$wf.yml)" ]]; then
      echo "  $br $wf: unchanged"; continue
    fi
    args=(-f "message=ci: $wf workflow (ios-selfhosted-ci)" -f branch=$br -f "content=$(base64 -i $tmp/$wf.yml)")
    [[ -n $sha ]] && args+=(-f sha=$sha)
    gh api -X PUT repos/$R/contents/$fp $args -q '.commit.sha[0:7]' | sed "s|^|  $br $wf: |"
  done
done

say "Claude review token"
if gh secret list -R $R | grep -q CLAUDE_CODE_OAUTH_TOKEN; then echo "  set"
else echo "  ⚠️ missing: in your own terminal run \`claude setup-token\`, then \`scripts/set-claude-token.sh $repo\`"; fi

say "Ruleset"
if gh api repos/$R/rulesets -q '.[].name' 2>/dev/null | grep -qx 'PR check must pass'; then echo "  exists"
elif ! gh api repos/$R/rulesets >/dev/null 2>&1; then echo "  ⚠️ rulesets on private repos need GitHub Pro/Team — skipped"
else
  python3 - $all_branches[2,-1] <<'PY' > $tmp/ruleset.json
import json,sys
print(json.dumps({"name":"PR check must pass","target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]+[f"refs/heads/{b}" for b in sys.argv[1:]],"exclude":[]}},
 "rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":False,"do_not_enforce_on_create":True,
   "required_status_checks":[{"context":"pr-check / build","integration_id":15368}]}}],
 "bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]}))
PY
  gh api -X POST repos/$R/rulesets --input $tmp/ruleset.json -q '"  #\(.id) \(.conditions.ref_name.include|join(", "))"'
fi

say "Verifying PR check ($default)"
gh workflow run pr-check.yml -R $R --ref $default >/dev/null; sleep 15
id=$(gh run list -R $R -w "PR check" -b $default -L 1 --json databaseId -q '.[0].databaseId')
gh run watch $id -R $R --exit-status >/dev/null 2>&1 && echo "  ✅ build passed" || { echo "  ❌ failed: $(gh run view $id -R $R --json url -q .url)"; exit 1; }

cat <<MSG

Done. Next:
- Create the app in App Store Connect (same bundle ID) before the first TestFlight upload.
- Ship a build: GitHub › $repo › Actions › TestFlight › Run workflow (the branch field takes any ref).
MSG
