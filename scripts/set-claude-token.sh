#!/bin/zsh
# Store your Claude Code OAuth token as the CLAUDE_CODE_OAUTH_TOKEN secret of app repos (for Claude review).
# 1) run `claude setup-token` and copy the sk-ant-oat… token  2) run this and paste it (input is hidden).
# Run it in your own terminal — not through an AI agent — so the token never lands in a transcript.
# Usage: set-claude-token.sh              every repo that has a runner on this Mac
#        set-claude-token.sh <repo> ...   only these repos
set -euo pipefail
source ${0:A:h}/_config.sh
REPOS=($HOME/actions-runners/*/.runner(N:h:t)); REPOS=(${REPOS:#*-review})
(( $# )) && REPOS=("$@")
read -rs "tok?Paste the token from claude setup-token (hidden): "; echo
[[ $tok == sk-ant-* ]] || { echo "That does not look like a Claude token (should start with sk-ant-)"; exit 1; }
for r in $REPOS; do gh secret set CLAUDE_CODE_OAUTH_TOKEN -R $GH_OWNER/$r --body "$tok" && echo "✓ $r"; done
