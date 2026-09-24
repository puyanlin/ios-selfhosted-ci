# Security

A self-hosted runner executes whatever the workflow and the code under test tell it to — as the macOS user that runs it, on your machine. Know what you are trusting.

## Hard rules

1. **Private repositories only.** On a public repo, anyone can open a pull request whose build scripts (Xcode run scripts, SPM plugins, test code) run on your Mac. `runner-add.sh` and `bootstrap-repo.sh` refuse public repos. The Claude review workflow additionally skips PRs from forks.
2. **Only you (and people you fully trust) should have write access** to repos that use the runner. Anyone who can push a branch can run code on the Mac.
3. **Never commit secrets.** The `.p8`, `ci.env`, and keychain password live only in `~/.appstoreconnect` on the runner (mode 600).

## What the design protects

- **Login keychain isolation.** The runner LaunchAgent created by `svc.sh` has `SessionCreate=true`, so jobs run in their own security session and cannot use your unlocked login keychain (browser passwords, tokens, iCloud keys). Signing uses `ci.keychain`, which contains **only** your signing identities. Do not remove `SessionCreate` to "fix" signing — use `ci-signing-setup.sh` instead.
- **No signing material in GitHub.** Certificates and the API key never go to GitHub secrets, so a leaked Actions log or a malicious workflow in another repo can't exfiltrate them via GitHub.
- **Reviews can't push code.** The Claude review job has `contents: read` and only the tools needed to read the diff and comment.

## What it does not protect

- **Same-user files.** Jobs run as your macOS user. `SessionCreate` blocks the login keychain, not files in your home folder (`~/.ssh`, `~/.appstoreconnect`, other repos). **Recommended:** run the runners under a **separate standard macOS user** that has only the Xcode account, `ci.keychain` and API key it needs.
- **Persistent state between jobs.** Runners are not ephemeral: DerivedData is wiped per job, but the SPM cache (`~/actions-runners/_cache/spm`) and anything a job writes to `$HOME` persist. A malicious dependency could plant something. If that matters to you, use ephemeral macOS VMs (e.g. [tart](https://github.com/cirruslabs/tart)).
- **Admin API key blast radius.** Cloud-managed distribution signing needs an **Admin** key. If it leaks, the attacker can manage your whole App Store Connect team. Keep it only on the runner, rotate it if the Mac is compromised, and revoke it in App Store Connect when you retire the machine. If you sign with your own distribution certificate instead, an **App Manager** key is enough for uploads.
- **Prompt injection in reviews.** PR content is fed to Claude. It could try to steer the review ("approve this"). The review can only comment — treat it as advice, not a gate. Don't give the review job write tools or secrets beyond the Claude token.

## Hygiene

- Inputs such as `branch` and `build-number` are passed through environment variables (not interpolated into shell) and `build-number`/`fastlane-lane` are validated.
- Pin app repos to a tag you control (`@v1` on your fork) or to a commit SHA.
- Revoke tokens you no longer use: `claude setup-token` tokens (claude.ai settings), App Store Connect keys, runner registrations (`runner-add.sh --remove`).
