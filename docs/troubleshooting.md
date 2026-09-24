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
| A reused scheme doesn't exist on a branch | Shared schemes differ per branch | Pass several candidates: `scheme: "AppA AppB"` |
| Claude review stuck for 20+ minutes | The action downloads and installs Claude Code every run; slow network | Set `claude-path`/`bun-path` to local installs (bootstrap does this) |
| Claude review cancelled at the time limit on a huge PR | Reading vendored binaries/SDKs | Timeout is 45 min and the prompt skips binaries; split huge PRs |
| Builds wait behind the review | One runner = one job at a time | Each repo gets a second runner (`claude-review` label) |
| Required check never turns green after switching to reusable workflows | The check is now named `<caller job> / <called job>` (`pr-check / build`) | Update the ruleset's required check; push a new commit to open PRs |
| `Workflow does not have 'workflow_dispatch' trigger` | Invalid YAML in the caller file | `gh workflow view` / check the file renders correctly |
| Rulesets API returns 403 "Upgrade to GitHub Pro" | Private repo on GitHub Free | Upgrade, or skip rulesets (checks still show on PRs) |
| `gh api … "sha" wasn't supplied` when updating a file | Shell word-splitting of optional args | Build the argument list as an array (see `bootstrap-repo.sh`) |
| Runner download extremely slow | Home network | `runner-add.sh` caches the tarball in `~/actions-runners/_dist` and verifies it |
| Disk fills up | DerivedData, simulators, archives | `xcrun simctl delete unavailable`; clean old DerivedData; the jobs refuse to start under 8 GB free |
