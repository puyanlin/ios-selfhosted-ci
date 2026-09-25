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

## 1. Put the signing identity on the runner Mac

On the Mac that has the certificate (Keychain Access › **login** › **My Certificates** › right-click
“Apple Distribution: <Company> (<TEAMID>)” › **Export** › *Personal Information Exchange (.p12)*, set a password).
Move the `.p12` and the `.mobileprovision` files to the runner Mac (AirDrop), then in **Terminal.app** on the
runner (the password prompts must not go through an AI agent):

```bash
scripts/ci-signing-setup.sh keychain                    # once per Mac, if not done yet
scripts/ci-signing-setup.sh p12 ~/Desktop/company.p12   # asks for the .p12 password
scripts/ci-signing-setup.sh profile ~/Desktop/*.mobileprovision
rm ~/Desktop/company.p12                                # it contains the private key
```

`profile` checks every file: App Store type, not expired, and whether its certificate is in `ci.keychain`.

## 2. Upload credentials for that team

Either an App Manager API key, per team:

```bash
scripts/ci-signing-setup.sh asc ~/Downloads/AuthKey_XXXX.p8 <issuer-id> --team <TEAMID>
```

or your Apple ID with an app-specific password (appleid.apple.com › Sign-In and Security › App-Specific Passwords):

```bash
scripts/ci-signing-setup.sh appleid you@example.com --team <TEAMID>
```

Check everything with `scripts/ci-signing-setup.sh status`.

## 3. Use it in the app repo

```bash
scripts/bootstrap-repo.sh MyCompanyApp --signing manual
```

or set `signing: manual` in the repo's `.github/workflows/testflight.yml`. The TestFlight job then:

1. hands `xcodebuild` every App Store profile of the team (for one Distribution identity); each target picks
   its own by bundle ID;
2. archives with manual signing;
3. exports an `.ipa` with the profiles of the bundles actually in the archive (app, extensions, watch app, App Clip);
4. **verifies the entitlements** survived with production values (`aps-environment: production`,
   `get-task-allow: false`) — the job fails otherwise;
5. uploads with `altool` (API key or Apple ID).

## Limits

- Submitting for review (`asc-release.py`) needs an API key; with only an Apple ID, submit on the website.
- `internal-only` can't be applied through `altool`.
- Profiles expire after a year; the job warns 30 days ahead. Renewed profile? Run `profile` again.
- Tested: a single-target app in a company team, and the cloud path (no regression). Not yet tested: a multi-target app
  (extensions + watch app) with manual signing, and an Apple ID upload from a runner job.
