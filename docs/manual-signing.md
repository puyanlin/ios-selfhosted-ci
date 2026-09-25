# Manual signing (company teams without an Admin key)

The default TestFlight path uses **Xcode cloud signing**, which needs an App Store Connect API key with the
**Admin** role. In a company team you are often only **App Manager** or **Developer**, and nobody will hand
an Admin key to your Mac. Manual signing works with what you *can* get:

| You need | From whom | Used for |
|---|---|---|
| An **Apple Distribution** certificate with its private key (`.p12`) | a team Admin creates it once; or export the one already on your Mac (Keychain Access › login › My Certificates › Export) | signing the archive |
| An **App Store** provisioning profile per bundle ID (app **and** every extension / watch app) | a team Admin (Certificates, Identifiers & Profiles › Profiles › + › App Store Connect) | signing the archive |
| Upload credentials: an **App Manager** API key, *or* your **Apple ID + an app-specific password** | a team Admin (key), or yourself (appleid.apple.com) | uploading to TestFlight |

Xcode-managed profiles (“iOS Team Store Provisioning Profile: …”) **can't** be used — Xcode refuses them for
manual signing. Wildcard profiles are ignored; use one profile per bundle ID.

All commands below run from your ios-selfhosted-ci checkout (`cd ~/ios-selfhosted-ci`).

## 1. Put the signing identity on the runner Mac

**On the Mac you already publish from** (or wherever the Admin created the certificate):

1. Keychain Access › **login** › **My Certificates** › right-click “Apple Distribution: <Company> (<TEAMID>)” ›
   **Export** › *Personal Information Exchange (.p12)*, and set a password.
   - No disclosure triangle / no .p12 option? Quit and reopen Keychain Access, or select the certificate **and**
     its private key (category *Keys*) and export both, or use Xcode › Settings › Accounts › (team) ›
     Manage Certificates › right-click › Export Certificate.
2. Find the App Store profile files: `python3 scripts/profiles.py list --team <TEAMID>` prints each profile's
   path (it works on a Mac without `ci.keychain`). They live in
   `~/Library/Developer/Xcode/UserData/Provisioning Profiles/<UUID>.mobileprovision`.
3. AirDrop the `.p12` and the `.mobileprovision` files to the runner Mac (they land in `~/Downloads`).

**On the runner Mac**, in **Terminal.app** (the password prompts must not go through an AI agent):

```bash
scripts/ci-signing-setup.sh keychain                          # once per Mac; fine if the login keychain has no identities
scripts/ci-signing-setup.sh p12 ~/Downloads/company.p12       # asks for the .p12 password
scripts/ci-signing-setup.sh profile ~/Downloads/*.mobileprovision
rm ~/Downloads/company.p12                                    # it contains the private key
```

`profile` checks every file: App Store type, not expired, and whether its certificate is in `ci.keychain`.

## 2. Upload credentials for that team

Either an App Manager API key for that team:

```bash
scripts/ci-signing-setup.sh asc ~/Downloads/AuthKey_XXXX.p8 <issuer-id> --team <TEAMID>
```

or your Apple ID with an app-specific password (account.apple.com › Sign-In and Security › App-Specific Passwords):

```bash
scripts/ci-signing-setup.sh appleid you@example.com --team <TEAMID>
```

If a team has both, the API key is used. Check everything with `scripts/ci-signing-setup.sh status`.

## 3. Use it in the app repo

`team-id` must be the **company's** Team ID, not the one in your config:

```bash
scripts/bootstrap-repo.sh MyCompanyApp --signing manual --team <TEAMID>
```

or edit the repo's `.github/workflows/testflight.yml`:

```yaml
jobs:
  testflight:
    uses: puyanlin/ios-selfhosted-ci/.github/workflows/testflight.yml@v1
    with:
      scheme: MyCompanyApp
      team-id: <TEAMID>
      signing: manual
      # branch / upload / xcode / build-number as before
```

The TestFlight job then:

1. hands `xcodebuild` every App Store profile of the team (for one Distribution identity); each target picks
   its own by bundle ID;
2. archives with manual signing;
3. exports an `.ipa` with the profiles of the bundles actually in the archive (app, extensions, watch app, App Clip);
4. **verifies the entitlements** survived with production values (`aps-environment: production`,
   `get-task-allow: false`) — the job fails otherwise;
5. uploads with `altool` (API key or Apple ID).

## Security

The company's private key now lives in the runner's `ci.keychain`: anything that runs as the runner's macOS
user can sign as the company. Keep company repos private, prefer a dedicated macOS user for the runners, delete
the `.p12` after importing, and ask the Admin to revoke the certificate when the Mac or you leave the project.

## Limits

- Submitting for review ([asc](https://asccli.sh)) needs an API key; with only an Apple ID, submit on the website.
- `internal-only` can't be applied through `altool`.
- Profiles **and** the Distribution certificate expire after a year; the job warns 30 days before a profile
  expires. New profile: run `profile` again. New certificate: redo step 1 (new `.p12` and profiles).
- Tested: a single-target app in a company team, and the cloud path (no regression). Not yet tested: a multi-target app
  (extensions + watch app) with manual signing, and an Apple ID upload from a runner job.
