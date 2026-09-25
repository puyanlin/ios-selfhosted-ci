---
name: app-store-submit
description: Submit an iOS app version for App Review end to end via the App Store Connect API (scripts/asc-release.py) — check status, draft What's New from git history, dry run, confirm with the user, submit, report. Use when the user asks to submit / release / send a version for review.
---

# Submit an app version for App Review

Tool: `scripts/asc-release.py` from ios-selfhosted-ci (API key in `~/.appstoreconnect/ci.env`).

1. **Identify** the app (bundle ID from the Xcode project's `PRODUCT_BUNDLE_IDENTIFIER`) and the version. Run
   `asc-release.py status --bundle-id <id> --version <v>` and show the user the versions and the processed builds.
2. **Pick the build**: the one the user tested (ask if unclear); default = newest VALID build of that version.
   If it is still processing, use `--wait-build 30`.
3. **What's New** for every locale the app has: reuse what App Store Connect already has, or draft it from
   `git log <previous release tag or version bump>..HEAD` — user-facing changes only, short bullet points, one
   file per locale under `fastlane/metadata/<locale>/release_notes.txt` or `--whats-new <locale>=…`.
4. **Release settings**: release after approval or manually, phased release on/off, review notes. Ask if unknown.
5. **Dry run** with all the chosen flags and `--dry-run`. Fix anything it reports (missing locale text,
   no export-compliance answer, no processed build).
6. **Confirm**: show the user app, version, build, release settings and the full What's New per locale, and
   wait for an explicit yes. Submitting is outward-facing.
7. **Submit**: same command without `--dry-run`. Report the final state (`WAITING_FOR_REVIEW`).
