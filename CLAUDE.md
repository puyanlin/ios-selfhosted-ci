# ios-selfhosted-ci — notes for AI agents

Public repo: reusable workflows and scripts that app repos call at `@v1`. Never commit personal data
(Team IDs, API keys, local paths, app names); those live in `~/.config/ios-selfhosted-ci/config` and the
app repos' caller files.

## Shipping a change

Moving `v1` is what ships a change to every app repo, so it must not be skipped past a release:

1. Merge to `main` through a PR (this repo's own PRs get the AI review).
2. `scripts/release.sh <x.y.z> --draft` — the commits since the last release.
3. Write release notes for people who don't read commits: what changed, why it matters, how to upgrade
   (usually "callers on `@v1` already run this"). Match the tone of the existing releases.
4. `scripts/release.sh <x.y.z> notes.md "<short title>"` — annotated tag, GitHub release (Latest), `v1` moved.

Semver: a fix → patch; a new input, script or feature → minor; anything callers must change → major
(new `v2`, leave `v1` alone).

## Checking

- `zsh -n` every changed zsh script; `python3 -m unittest discover -s check` for the path filter.
- `scripts/doctor.sh` (and `--compare <host>` with a second runner Mac) for environment changes.
