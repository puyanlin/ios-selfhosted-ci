# Troubleshooting

Real problems hit while building this, and what fixed them.

| Symptom | Cause | Fix |
|---|---|---|
| `errSecInternalComponent` during codesign | The runner LaunchAgent has `SessionCreate=true`, so the job can't use the login keychain | Run `scripts/ci-signing-setup.sh keychain` (dedicated `ci.keychain`). Don't remove `SessionCreate`. |
| `App Store Connect access for "TEAMID" is required` | No API key and no Xcode account visible to the job | `scripts/ci-signing-setup.sh asc …` with an **Admin** key |
| `Crashlytics/run: No such file or directory` | `-clonedSourcePackagesDirPath` moves SPM checkouts; Crashlytics' run script expects `DerivedData/SourcePackages` | Already handled: `lib.sh` symlinks `DerivedData/SourcePackages` to the persistent cache |
| `xcodebuild: error: … requires Xcode` / wrong Xcode | `xcode-select` points at CommandLineTools | Runners get `DEVELOPER_DIR` in their `.env`; or pass `xcode:` |
| `IPHONEOS_DEPLOYMENT_TARGET is set to 13.0, but the range … is 15.0 to …` | New Xcode dropped old deployment targets | Raise the target in the project (and local `Package.swift` platforms) |
| `… is missing architecture(s) required by this target (arm64)` then link errors | An old binary SDK has no arm64 simulator slice | Update the SDK, or use `destination: device` for the PR check |
| Tests fail with CloudKit / entitlement errors (`must have a com.apple.developer.icloud-services entitlement`) | Unsigned (`CODE_SIGNING_ALLOWED=NO`) test hosts have no entitlements | Already handled: tests are signed ad hoc (`CODE_SIGN_IDENTITY=-`), no certificate needed |
| `Test crashed with signal term before establishing connection` when several PRs run at once | Parallel jobs shared one simulator and killed each other's test host | Already handled: each job creates its own simulator (runtime matched to the Xcode SDK), boots it, deletes it afterwards |
| `There are no test bundles available to test` | The unit test target isn't in the scheme's Test action (or `TEST_HOST` is wrong) | Add the test target to the shared scheme; until then the PR check falls back to a build |
| A reused scheme doesn't exist on a branch | Shared schemes differ per branch | Pass several candidates: `scheme: "AppA AppB"` |
| Claude review hangs silently until the timeout, no transcript at all | With `claude-path`, Claude Code runs as the runner's macOS user and loads that user's `~/.claude` (hooks, plugins, MCP servers, remote control) — something there blocks a headless job | Already handled: the review step sets `CLAUDE_CONFIG_DIR` to a fresh per-job directory. Debug with `show-full-output: true` on a test branch only |
| Claude review stuck for 20+ minutes | The action downloads and installs Claude Code every run; slow network | Set `claude-path`/`bun-path` to local installs (bootstrap does this) |
| Claude review cancelled at the time limit on a huge PR | Reading vendored binaries/SDKs | Timeout is 45 min and the prompt skips binaries; split huge PRs |
| Builds wait behind the review | One runner = one job at a time | Each repo gets a second runner (`claude-review` label) |
| Required check never turns green after switching to reusable workflows | The check is now named `<caller job> / <called job>` (`pr-check / build`) | Update the ruleset's required check; push a new commit to open PRs |
| `Workflow does not have 'workflow_dispatch' trigger` | Invalid YAML in the caller file | `gh workflow view` / check the file renders correctly |
| Rulesets API returns 403 "Upgrade to GitHub Pro" | Private repo on GitHub Free | Upgrade, or skip rulesets (checks still show on PRs) |
| `gh api … "sha" wasn't supplied` when updating a file | Shell word-splitting of optional args | Build the argument list as an array (see `bootstrap-repo.sh`) |
| Runner download extremely slow | Home network | `runner-add.sh` caches the tarball in `~/actions-runners/_dist` and verifies it |
| Disk fills up | DerivedData, simulators, archives | `xcrun simctl delete unavailable`; clean old DerivedData; the jobs refuse to start under 8 GB free |
