---
name: app-store-submit
description: Submit an iOS app version for App Review end to end via the App Store Connect API — check status, pick the build, let the user choose locales (default = the existing ones) and draft What's New, dry run, confirm, submit, report. Talks to the user in English or Traditional Chinese. Use when the user asks to submit / release / send a version for review (e.g. "submit 1.4 for review", 「送審」「把 X 送審」「上架 X 版」).
---

# Submit an app version for App Review

Tool: `scripts/asc-release.py` in the ios-selfhosted-ci checkout (API key from `~/.appstoreconnect/ci.env`,
installed by `scripts/ci-signing-setup.sh asc`). No App Store Connect website login needed.

## Language

Read `LANGUAGE` from `~/.config/ios-selfhosted-ci/config`:

- `zh-TW` → talk to the user in **Traditional Chinese with Taiwan wording** (e.g. 檔案、設定、語系、送審、新功能).
- `en` → English.
- unset → use the language of the user's messages.

This only affects how you talk to the user. What's New text follows the locales the user picks, and commands and
identifiers stay as they are.

## Steps

1. **App and version**
   - Get the bundle ID from the project's `PRODUCT_BUNDLE_IDENTIFIER`. If one repo hosts several apps on
     different branches, map the branch to the right app, and ask if unsure.
   - Run `asc-release.py status --bundle-id <id> --version <v>`. Show the user the version state, its locales,
     and the processed builds.
2. **Build**
   - Use the build the user tested; ask if unclear. The default is the newest VALID build of that version.
     If it is still processing, add `--wait-build 30`.
   - It must be built with a **release** Xcode. Builds from beta SDKs can go to TestFlight but cannot be
     submitted, so check the build's SDK when the team uses betas.
3. **Locales and What's New**
   - `status` lists the version's locales. A version that doesn't exist yet inherits the latest version's locales.
   - **Ask which locales to fill** (AskUserQuestion). The first option is "Existing locales (default)", naming
     them (e.g. `zh-Hant, en-US`); the other options are a subset, or adding locales. Apps differ, so never
     assume a fixed set.
   - Pass the choice as `--locales a,b`.
     - An unselected existing locale with empty text blocks the submission. Either fill it too, or remove it
       from this version with `--drop-unlisted`. Removing deletes that locale's description as well, so confirm
       with the user first.
     - Adding a locale also needs `<notes-dir>/<locale>/description.txt` and `keywords.txt`. The app name for a
       new locale is set on the website (App Information).
   - Text: reuse what App Store Connect already has. Otherwise draft it from
     `git log <previous release>..HEAD`: user-facing changes only, short bullets, one text per chosen locale,
     written natively in that language. Put it in `fastlane/metadata/<locale>/release_notes.txt`
     (`--notes-dir fastlane/metadata`) or pass `--whats-new <locale>=…`.
4. **Release settings**: release after approval or manually (`--release`), 7-day phased release
   (`--phased` / `--no-phased`; "release to 100%" means `--no-phased`), and review notes (`--review-notes`).
   Default to what the previous version did, and ask if unknown.
5. **Dry run**: run everything with `--dry-run` and fix what it reports. Common problems are a locale without
   text, a build with no export-compliance answer (set `ITSAppUsesNonExemptEncryption` in Info.plist), and a
   build that hasn't finished processing.
6. **Confirm**: show app, version, build, release settings, locales and the full What's New per locale. Wait for
   an explicit yes, because submitting is outward-facing.
7. **Submit**: run the same command without `--dry-run`, then report the final state (`WAITING_FOR_REVIEW`).
8. **Wrap up**
   - Record the submission (time, build, settings) wherever the project keeps release notes or memory.
   - If other agent sessions own this app, tell them it was submitted so they handle the review outcome.

## After a rejection

Fix the issue, then follow the same steps. The script reuses the open submission that has unresolved issues.
