#!/bin/bash
# Run the review with the provider's own CLI and write $WORK/review.json (summary + issues).
# Env: PROVIDER, MODEL, PROMPT_FILE, SCHEMA_FILE, WORK, CLAUDE_PATH, and optionally
#      CLAUDE_CODE_OAUTH_TOKEN / OPENAI_API_KEY / GEMINI_API_KEY (else the runner user's CLI login is used).
set -euo pipefail
RAW=$WORK/raw.txt
PROMPT=$(cat "$PROMPT_FILE")
hosted() { [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ]; }
need() {  # need <command> <npm package> <login hint>
  command -v "$1" >/dev/null && return
  if hosted; then npm install -g "$2" >/dev/null 2>&1; command -v "$1" >/dev/null && return; fi
  echo "::error::$1 is not installed on this runner. Install it: npm install -g $2 && $3"; exit 1
}

case "$PROVIDER" in
claude)
  CLAUDE=${CLAUDE_PATH:-claude}; command -v "$CLAUDE" >/dev/null || { need claude @anthropic-ai/claude-code "claude setup-token"; CLAUDE=claude; }
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || { echo "::error::Claude needs the CLAUDE_CODE_OAUTH_TOKEN secret (claude setup-token)"; exit 1; }
  # Fresh config dir: never load the runner user's ~/.claude (hooks, plugins, MCP servers) in a headless job.
  export CLAUDE_CONFIG_DIR=$WORK/claude-config
  "$CLAUDE" -p "$PROMPT" --model "${MODEL:-claude-opus-5-5}" --output-format json \
    --allowedTools "Read,Grep,Glob" > "$WORK/claude.json"
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("result",""))' "$WORK/claude.json" > "$RAW"
  ;;
codex)
  need codex @openai/codex "codex login"
  # Own CODEX_HOME with just the credentials — the user's config, MCP servers and history stay out.
  export CODEX_HOME=$WORK/codex-home; mkdir -p "$CODEX_HOME"
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    printf %s "$OPENAI_API_KEY" | codex login --with-api-key >/dev/null
  elif [ -f "$HOME/.codex/auth.json" ]; then
    cp "$HOME/.codex/auth.json" "$CODEX_HOME/"
  else
    echo "::error::Codex is not logged in on this runner (run: codex login) and no OPENAI_API_KEY secret"; exit 1
  fi
  args=(exec --sandbox read-only --skip-git-repo-check --output-schema "$SCHEMA_FILE" --output-last-message "$RAW")
  [ -n "${MODEL:-}" ] && args+=(--model "$MODEL")
  codex "${args[@]}" "$PROMPT" > "$WORK/codex.log" 2>&1 || { tail -30 "$WORK/codex.log"; exit 1; }
  ;;
gemini)
  need gemini @google/gemini-cli "gemini (and sign in)"
  GHOME=$WORK/gemini-home; mkdir -p "$GHOME/.gemini"
  if [ -z "${GEMINI_API_KEY:-}" ]; then
    # Reuse the runner user's Google sign-in, without their settings, extensions or MCP servers.
    for f in oauth_creds.json google_accounts.json installation_id; do
      [ -f "$HOME/.gemini/$f" ] && cp "$HOME/.gemini/$f" "$GHOME/.gemini/"
    done
    [ -f "$GHOME/.gemini/oauth_creds.json" ] || { echo "::error::Gemini is not signed in on this runner (run: gemini) and no GEMINI_API_KEY secret"; exit 1; }
    echo '{"security":{"auth":{"selectedType":"oauth-personal"}}}' > "$GHOME/.gemini/settings.json"
  fi
  args=(--output-format json -p "$PROMPT")
  [ -n "${MODEL:-}" ] && args=(--model "$MODEL" "${args[@]}")
  HOME=$GHOME gemini "${args[@]}" > "$WORK/gemini.json" 2> "$WORK/gemini.log" || { tail -30 "$WORK/gemini.log"; exit 1; }
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("response",""))' "$WORK/gemini.json" > "$RAW"
  ;;
*) echo "::error::provider must be claude, codex or gemini (got '$PROVIDER')"; exit 1 ;;
esac

# Pull the JSON object out of the answer (models sometimes wrap it in prose or ``` fences) and sanity-check it.
python3 - "$RAW" "$WORK/review.json" <<'PY'
import json,re,sys
t=open(sys.argv[1]).read()
t=re.sub(r'^```(?:json)?\s*|\s*```$','',t.strip())
a,b=t.find('{'),t.rfind('}')
if a<0 or b<a: print('::error::The model did not return JSON:\n'+t[:2000]); sys.exit(1)
d=json.loads(t[a:b+1])
d.setdefault('issues',[])
if not isinstance(d.get('summary'),str) or not isinstance(d['issues'],list):
    print('::error::Unexpected review format'); sys.exit(1)
json.dump(d,open(sys.argv[2],'w'),ensure_ascii=False)
print(f"review: {len(d['issues'])} issue(s)")
PY
