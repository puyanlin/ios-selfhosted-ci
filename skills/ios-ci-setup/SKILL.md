---
name: ios-ci-setup
description: Set up self-hosted CI for a (new or existing) private iOS app repo in one go — Mac runners, PR check (unit tests), TestFlight from any branch, Claude review, and a "PR check must pass" ruleset — using ios-selfhosted-ci's bootstrap-repo.sh. Talks to the user in English or Traditional Chinese. Use when the user asks to set up CI / runners / TestFlight workflow / PR checks / auto review for an app repo (e.g. "set up CI for MyApp", 「新 app 設 CI」「幫 X repo 設 GitHub 環境」).
---

# Set up CI for an iOS app repo

Tool: `scripts/bootstrap-repo.sh` in the ios-selfhosted-ci checkout. Settings (owner, Team ID, Xcode, review
language, commit trailer) come from `~/.config/ios-selfhosted-ci/config`.

## Language

Read `LANGUAGE` from `~/.config/ios-selfhosted-ci/config`:

- `zh-TW` → talk to the user in **Traditional Chinese with Taiwan wording** (e.g. 檔案、設定、分支、編譯、送審).
- `en` → English.
- unset → use the language of the user's messages.

This only affects how you talk to the user. Commands, file contents and identifiers stay as they are.

## Before running

- The repo must exist on GitHub, be **private** (the script refuses public repos: fork PRs could run code on the
  Mac), and contain the Xcode project. If it doesn't exist yet, create it (`gh repo create <owner>/<name> --private`)
  and push the project first.
- A CocoaPods project without committed `Pods/` stops the script. Talk to the user: install CocoaPods on the
  runner, or migrate to SPM.
- If `~/.config/ios-selfhosted-ci/config` is missing, help the user create it from `config.example`.

## Run

```bash
scripts/bootstrap-repo.sh <repo> [options]
```

| Option | When |
|---|---|
| `--scheme "A B"` | Auto-detected if omitted. Several candidates = each branch uses the one it has (two apps on different long-lived branches) |
| `--project path/X.xcodeproj` | The project isn't at the repo root |
| `--branch name` | Extra long-lived branches that also get the workflows and the ruleset |
| `--destination device` | PR check builds for device (unsigned), e.g. an SDK lacks an arm64 simulator slice |
| `--no-test` / `--skip-testing "T/Suite"` | Unit tests are broken for now, or some need skipping (UI tests are always skipped) |
| `--no-testflight` | The app belongs to an App Store Connect team you can't sign for |
| `--no-ruleset` | The default branch doesn't build yet |
| `--review-language "…"` | Override the review language from the config |

It is safe to re-run. Existing runners are kept, unchanged workflow files aren't committed, and an existing ruleset
that requires `pr-check / build` isn't duplicated. At the end it runs the PR check once to verify. If that run
fails, show the user the error and fix it together; don't skip it.

## Tell the user afterwards

- **Claude review token**: if the script reports it missing, don't run it for them. The token would land in the
  transcript, and it needs a browser login. Ask them to run these in their own terminal:
  1. `claude setup-token`, then copy the `sk-ant-oat…` token
  2. `scripts/set-claude-token.sh <repo>`, then paste it (the input is hidden)
- **TestFlight**: the app record must exist in App Store Connect with the same bundle ID. After that, use
  *Actions › TestFlight › Run workflow*. The `branch` field takes any ref. The Xcode choice `default` follows the
  repo's `.xcode-version`, otherwise the release Xcode.
- **Submitting for review** is the `app-store-submit` skill.

## Changing the pipeline

Every app repo calls the reusable workflows in ios-selfhosted-ci. After changing them, move the tag:
`git tag -f v1 && git push -f origin v1`. If the checkout is public, never put personal data in it (Team ID,
API keys, local paths, app names). Personal settings belong in the config file and in each repo's caller files.
