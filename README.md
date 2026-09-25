# ios-selfhosted-ci

Turn the Mac on your desk into the CI for all your iOS apps — **PR checks, TestFlight builds of any branch from your phone, and AI code review**, managed from one repo.

[繁體中文說明 →](README.zh-TW.md)

```
 app repo (thin caller files)            this repo (reusable workflows + actions)          your Mac mini
 ┌──────────────────────────┐   uses   ┌────────────────────────────────────┐  runs-on  ┌─────────────────────┐
 │ .github/workflows/        │ ───────▶ │ pr-check.yml      unsigned build    │ ────────▶ │ runner  macos-xcode  │
 │   pr-check.yml   (8 lines)│          │ testflight.yml    archive → upload  │           │ runner  claude-review│
 │   testflight.yml          │          │ claude-review.yml Claude PR review  │           │ ci.keychain + ASC key│
 │   claude-review.yml       │          └────────────────────────────────────┘           └─────────────────────┘
 └──────────────────────────┘
```

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
- **Claude review** — each PR gets inline comments + a summary from Claude (Opus by default) via [anthropics/claude-code-action](https://github.com/anthropics/claude-code-action), on a dedicated runner so it never blocks builds.
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
| Tools | [GitHub CLI](https://cli.github.com) (`gh auth login`), Claude Code (`claude`), [bun](https://bun.sh) (makes reviews start fast) |
| GitHub | Rulesets on private repos need **GitHub Pro** (personal) or Team (org). Everything else works on Free. |
| Network | Wired Ethernet. Point the review workflow at locally installed `claude`/`bun` so jobs don't re-download them. |

## Who can set this up

**App Store Connect** (the API key lives on the runner Mac):

| Step | Who | Notes |
|---|---|---|
| Enable the App Store Connect API for the team (first time only) | **Account Holder** | The "Request Access" button on *Users and Access › Integrations* |
| Create the **team** API key | **Admin** (or Account Holder) | Users with other roles can't open the Team Keys page |
| Key role used by this project | **Admin** | Verified for everything here: archive with automatic signing, cloud-managed distribution signing, TestFlight upload, `asc-release.py` submission |
| Key role for `asc-release.py` alone (versions, What's New, submit) | App Manager should be enough | Not verified here; replying to customer reviews needs Admin |
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

## Submitting for App Review

`scripts/asc-release.py` does the whole App Store submission through the App Store Connect API — no website, no login that expires:

```bash
scripts/asc-release.py status --bundle-id com.example.app
scripts/asc-release.py submit --bundle-id com.example.app --version 1.4.0 \
    --notes-dir fastlane/metadata \            # <locale>/release_notes.txt (fastlane deliver layout)
    --release after-approval --no-phased --dry-run    # drop --dry-run to submit
```

It creates (or reuses) the version, waits for the build to finish processing (`--wait-build 30`), attaches it, fills "What's New" per locale, sets release type / phased release / review notes, checks nothing is missing, and submits — also after a rejection. `--dry-run` prints every step and changes nothing.

Using an AI agent? [`skills/app-store-submit/SKILL.md`](skills/app-store-submit/SKILL.md) is a Claude Code skill that lets you pick the locales, drafts the release notes from git history, shows you the plan, and only submits after you confirm. It talks to you in English or Traditional Chinese (`LANGUAGE` in the config). Install: `ln -s ~/ios-selfhosted-ci/skills/app-store-submit ~/.claude/skills/app-store-submit`.

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
| claude-review | `model` | `claude-opus-5-5` | Any Claude model ID |
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
