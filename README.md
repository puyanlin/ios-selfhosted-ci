# ios-selfhosted-ci

Turn the Mac on your desk into the CI for all your iOS apps — **PR checks with unit tests, TestFlight builds of any branch from your phone, and AI code review**, managed from one repo.

This project is the **infrastructure** layer: self-hosted runners, reusable workflows, keychain isolation, signing (cloud or manual). For everything App Store Connect it pairs with [asc](https://asccli.sh); for marketing screenshots with [app-store-screenshots](https://github.com/ParthJadhav/app-store-screenshots).

| Layer | Tool |
|---|---|
| Runners, PR check + tests, any-branch TestFlight, signing, one-command repo setup | **this repo** |
| AI PR review | Claude Code, Codex or Gemini CLI on your Mac (this repo), one prompt, inline comments |
| Submissions, metadata, TestFlight groups, review status | [asc](https://asccli.sh) |
| Marketing screenshots | [app-store-screenshots](https://github.com/ParthJadhav/app-store-screenshots) → `asc screenshots upload` |

[繁體中文說明 →](README.zh-TW.md)

## Why

For a solo developer with a handful of private iOS apps:

| | Monthly cost (~12 apps) | AI review | GitHub required checks | Any branch from phone |
|---|---|---|---|---|
| **This (your own Mac)** | ~$0 | ✅ Claude, on your subscription | ✅ | ✅ |
| Xcode Cloud | 25 h free, then $49.99+ | ❌ | ❌ | ✅ |
| Codemagic / Bitrise | ~$50+ | ❌ | ✅ | ✅ |
| GitHub-hosted macOS runners | ~$60+ | ✅ | ✅ | ✅ |

What you get:

- **PR check** — every PR runs the unit tests on your Mac (UI tests skipped; build-only when there are no tests, or an unsigned device build). Enforced with a ruleset.
- **TestFlight from anywhere** — `Actions › TestFlight › Run workflow`, type **any** branch/tag/commit (it doesn't even need to contain the workflow). Build number defaults to `YYMMDD01` and Xcode bumps it on clashes.
- **AI review** — each PR gets inline comments + a summary from Claude, Codex or Gemini (whichever you use), through its CLI on a dedicated runner so it never blocks builds.
- **No certificates to juggle** — Xcode cloud signing with an App Store Connect API key; no p12/profiles in secrets, no fastlane match. (Already on fastlane? See [docs/fastlane.md](docs/fastlane.md).)
- **One command per new app** — `scripts/bootstrap-repo.sh MyApp` sets up runners, workflows, ruleset and verifies a build.
- **Change once, apply everywhere** — app repos only call the reusable workflows; edit prompts, models or steps here.

> ⚠️ **Private repos only.** A self-hosted runner on a public repo lets anyone's pull request run code on your Mac. The scripts refuse public repos. Read [docs/security.md](docs/security.md) before you start.

## Recommended setup

| | Recommendation |
|---|---|
| Machine | Apple silicon Mac mini, 16 GB+ RAM (24 GB+ if it also runs VMs/containers), 256 GB+ free SSD space |
| macOS user | Ideally a **separate standard user** just for CI (see security). Auto-login + never sleep. |
| Power | *System Settings › Energy*: prevent sleep, start after power failure |
| Xcode | Release Xcode at `/Applications/Xcode.app`. Keep betas elsewhere and only select them explicitly. |
| Tools | [GitHub CLI](https://cli.github.com) (`gh auth login`), Claude Code (`claude`), [bun](https://bun.sh) (makes reviews start fast), [asc](https://asccli.sh) (`brew install asc`) |
| GitHub | Rulesets on private repos need **GitHub Pro** (personal) or Team (org). Everything else works on Free. |
| Network | Wired Ethernet. Point the review workflow at locally installed `claude`/`bun` so jobs don't re-download them. |

## Who can set this up

**App Store Connect** (the API key lives on the runner Mac):

| Step | Who | Notes |
|---|---|---|
| Enable the App Store Connect API for the team (first time only) | **Account Holder** | The "Request Access" button on *Users and Access › Integrations* |
| Create the **team** API key | **Admin** (or Account Holder) | Users with other roles can't open the Team Keys page |
| Key role used by this project | **Admin** | Verified for everything here: archive with automatic signing, cloud-managed distribution signing, TestFlight upload, submission with asc |
| Key role for asc alone (versions, What's New, submit) | App Manager should be enough | Not verified here; replying to customer reviews needs Admin |
| Individual (personal) API keys | ❌ not supported | Apple: individual keys can't use the Provisioning endpoints (needed for signing), and the scripts expect an Issuer ID |

Cloud-managed distribution signing is available by default to Account Holder and Admin; Developers need the
*Access to Cloud Managed Distribution Certificate* permission. Whether an **App Manager key** can cloud-sign
isn't documented — use Admin unless you've tested otherwise.

If the app belongs to a team where you're only App Manager or Developer (typical for a company account), use
**[manual signing](docs/manual-signing.md)**: an Apple Distribution certificate + App Store profiles from the
team's Admin (or exported from the Mac you already publish from), and an App Manager key or your Apple ID +
app-specific password for uploads — no Admin key needed. Otherwise you can still use the PR check and Claude
review (`--no-testflight`).

**GitHub**: you need admin rights on the app repos (runners, secrets, rulesets). Rulesets on **private** repos
need GitHub Pro (personal accounts) or Team (organizations).

**The Mac**: the runner user's login keychain must hold an *Apple Development* identity for the team (Xcode ›
Settings › Accounts creates it); `ci-signing-setup.sh keychain` copies it into `ci.keychain`.

Sources: [Creating API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api) ·
[Cloud-managed certificates](https://developer.apple.com/help/account/certificates/cloud-managed-certificates/) ·
[Program roles](https://developer.apple.com/help/account/access/roles/)

## Setup (about 20 minutes)

### 1. Use this repo

Either reference it directly (`puyanlin/ios-selfhosted-ci@v1`) or **fork it** (recommended: you control updates). If you fork, replace `puyanlin/ios-selfhosted-ci` with your fork in `.github/workflows/*.yml` and set `CI_REPO` below. For a private fork, allow access: *fork › Settings › Actions › General › Access → "Accessible from repositories owned by the user"*.

```bash
git clone https://github.com/puyanlin/ios-selfhosted-ci ~/ios-selfhosted-ci
mkdir -p ~/.config/ios-selfhosted-ci
cp ~/ios-selfhosted-ci/config.example ~/.config/ios-selfhosted-ci/config
open -e ~/.config/ios-selfhosted-ci/config      # GH_OWNER, TEAM_ID, CI_REPO …
```

### 2. Signing (once per Mac)

1. **Signing identity** — make sure Xcode has created your *Apple Development* certificate (Xcode › Settings › Accounts). Then:
   ```bash
   scripts/ci-signing-setup.sh keychain     # macOS asks for your login password once
   ```
   This creates `ci.keychain` holding only your signing identities. Jobs unlock this keychain and never see your login keychain.
2. **App Store Connect API key** — App Store Connect › Users and Access › Integrations › App Store Connect API › Team Keys › **+**, access **Admin** (needed for cloud-managed distribution signing). Download the `.p8` (only once!) and note the Issuer ID:
   ```bash
   scripts/ci-signing-setup.sh asc ~/Downloads/AuthKey_XXXXXXXXXX.p8 <issuer-id>
   scripts/ci-signing-setup.sh status
   ```

### 3. Each app repo

```bash
scripts/bootstrap-repo.sh MyApp
# two apps in one repo on different branches:
scripts/bootstrap-repo.sh MyApp --scheme "MyApp MyAppPro" --branch pro
# an SDK without an arm64 simulator slice:
scripts/bootstrap-repo.sh MyApp --destination device
# review comments in another language (or set REVIEW_LANGUAGE in the config):
scripts/bootstrap-repo.sh MyApp --review-language "Traditional Chinese"
# PR check + review only, no TestFlight:
scripts/bootstrap-repo.sh MyApp --no-testflight
# no ruleset yet (the default branch does not build yet):
scripts/bootstrap-repo.sh MyApp --no-ruleset
# PR check builds only (tests are broken for now) / skip some tests:
scripts/bootstrap-repo.sh MyApp --no-test
scripts/bootstrap-repo.sh MyApp --skip-testing "MyAppTests/SlowTests"
```

Re-running it on a repo that is already set up is safe: it only updates changed caller files and never duplicates the ruleset. Set `XCODE_BETA_APP` in the config to offer a beta Xcode in the TestFlight menu.

> Using Claude Code? `ln -s ~/ios-selfhosted-ci/skills/ios-ci-setup ~/.claude/skills/ios-ci-setup` and just ask it to "set up CI for MyApp" — the [ios-ci-setup skill](skills/ios-ci-setup/SKILL.md) runs this for you.

### 4. Claude review token (once, plus once per new repo)

In **your own terminal** (not through an AI agent, so the token never lands in a transcript):

```bash
claude setup-token                       # copy the sk-ant-oat… token
scripts/set-claude-token.sh              # every repo with a runner; or: set-claude-token.sh MyApp
```

Personal GitHub accounts have no account-wide Actions secrets, so each repo needs the secret.

## Daily use

- **Open a PR** → `pr-check / build` and `review / review` start in parallel.
- **Ship a build** → *Actions › TestFlight › Run workflow*: branch (any ref), upload on/off, Xcode, build number. The GitHub mobile app works.
  ```bash
  gh workflow run testflight.yml -R you/MyApp -f branch=feature/x          # from a terminal
  gh workflow run testflight.yml -R you/MyApp -f branch=main -f upload=false  # dry run
  ```
- **Change the pipeline** → edit `.github/workflows/*` here, then `git tag -f v1 && git push -f origin v1`. Every app picks it up on its next run. (Pin callers to a commit SHA instead of `v1` if you prefer immutable versions.)

## Releasing to the App Store (with asc)

This project doesn't talk to the App Store Connect API itself — use **[asc](https://asccli.sh)** (App Store Connect CLI, MIT),
which covers submissions, metadata, screenshots, TestFlight groups, review status and more. It uses the same API key:

```bash
brew install asc
asc telemetry disable                  # optional: it sends anonymous usage stats by default
asc install-skills                     # optional: 25 agent skills (asc-release-flow, asc-whats-new-writer, …)
scripts/ci-signing-setup.sh asc …      # installs the key for the runner AND registers it with asc
```

A typical release, after the TestFlight workflow uploaded the build:

```bash
asc release stage --app APP_ID --version 1.4.0 --build BUILD_ID --metadata-dir ./metadata/version/1.4.0 --dry-run
asc release stage --app APP_ID --version 1.4.0 --build BUILD_ID --metadata-dir ./metadata/version/1.4.0 --confirm
asc validate --app APP_ID --version 1.4.0 --platform IOS
asc review submit --app APP_ID --version 1.4.0 --build BUILD_ID --confirm
asc review status --app APP_ID
```

Only the API key is needed — no Apple ID password. (`asc web auth login` is optional, for extra checks Apple exposes
only on the website.) For marketing screenshots, [app-store-screenshots](https://github.com/ParthJadhav/app-store-screenshots)
designs them and `asc screenshots upload` uploads them.

## AI review: pick a provider

Every repo's `.github/workflows/ai-review.yml` sets `provider:` — use whichever service the runner's owner already
pays for. All three run **on your Mac** through their own CLI, share one review prompt (`review/prompt.md`) and one
output format, and post the same way: a PR review with **inline comments** on the affected lines plus a summary.

| `provider` | CLI on the runner | Sign-in (pick one) |
|---|---|---|
| `claude` (default) | `claude` | secret `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token` → `scripts/set-claude-token.sh`) |
| `codex` | `codex` (`npm i -g @openai/codex`) | `codex login` on the runner (ChatGPT sign-in), or secret `OPENAI_API_KEY` |
| `gemini` | `gemini` (`npm i -g @google/gemini-cli`) | sign in once by running `gemini` on the runner, or secret `GEMINI_API_KEY` |

Each job copies only the credentials into a fresh config folder, so your own settings, plugins and MCP servers
never load in CI. Set the default for new repos with `REVIEW_PROVIDER` in the config or
`bootstrap-repo.sh MyApp --review-provider codex`; override the model with `model:`. `runner: '"ubuntu-latest"'`
also works (the CLI is installed on the fly; an API-key secret is then required). Codex and Gemini are less
battle-tested than Claude here.

## Choosing the Xcode version

Every workflow resolves Xcode the same way (see `xcode.sh`):

1. the `xcode` input — a path (`/Applications/Xcode-beta.app`) **or a version** (`27.1`, or `27` = newest installed 27.x, release builds preferred over betas);
2. otherwise the repo's **`.xcode-version`** file (the xcodes/fastlane convention, e.g. `27.1`);
3. otherwise the runner default (`/Applications/Xcode.app`).

Install several Xcodes side by side (e.g. with [xcodes](https://github.com/XcodesOrg/xcodes)) and pin per repo with `.xcode-version`.

## Reusable workflow inputs

| Workflow | Input | Default | Notes |
|---|---|---|---|
| pr-check | `scheme` | — | Several space-separated candidates allowed |
| | `project` | auto | `.xcodeproj`/`.xcworkspace` at the root |
| | `destination` | `simulator` | `device` = unsigned device build |
| | `test` | `true` | Unit tests on an iPhone simulator (ad-hoc signed test host); falls back to a build when the scheme has no tests |
| | `skip-ui-tests` | `true` | Skip every `*UITests` target |
| | `skip-testing` | — | Extra `-skip-testing` identifiers, space separated |
| testflight | `scheme`, `team-id` | — | |
| | `branch` | dispatched ref | Any branch/tag/SHA |
| | `upload` | `true` | `false` = archive + export only |
| | `xcode` | `.xcode-version`, else runner default | Path or version (`27.1`, `27`) |
| | `build-number` | `YYMMDD01` | Numeric only |
| | `fastlane-lane` | — | Run `bundle exec fastlane <lane>` instead |
| | `signing` | `cloud` | `manual` = your Distribution identity + App Store profiles ([docs](docs/manual-signing.md)) |
| ai-review | `provider` | `claude` | `claude`, `codex` or `gemini` |
| | `model` | provider default | e.g. `claude-opus-5-5` |
| | `runner` | `auto` | `auto` = your Mac's `claude-review` runner |
| | `claude-path`, `bun-path` | download each run | Point at local installs |
| | `language` | `English` | Language of the review comments |
| all | `runner-label` | `macos-xcode` / `claude-review` | |

## More

- [docs/security.md](docs/security.md) — threat model and hardening
- [docs/troubleshooting.md](docs/troubleshooting.md) — every pitfall we hit, with fixes
- [docs/fastlane.md](docs/fastlane.md) — using your existing fastlane lanes
- [docs/manual-signing.md](docs/manual-signing.md) — company teams without an Admin key

## License

MIT
