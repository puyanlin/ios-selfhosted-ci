# Using fastlane

This project and [fastlane](https://fastlane.tools) don't compete — they cover different layers:

| Layer | This project | fastlane |
|---|---|---|
| Where/when jobs run (runners, triggers, PR checks, rulesets, AI review) | ✅ | — |
| How the app is archived, signed and uploaded | built-in `xcodebuild` path | `gym`, `match`, `pilot`, … |

The built-in path needs no Ruby: Xcode cloud signing + an App Store Connect API key + `manageAppVersionAndBuildNumber`. If you already have lanes, keep them:

```yaml
# .github/workflows/testflight.yml in the app repo
jobs:
  testflight:
    uses: puyanlin/ios-selfhosted-ci/.github/workflows/testflight.yml@v1
    with:
      scheme: MyApp            # still required by the interface
      team-id: ABCDE12345
      fastlane-lane: beta      # runs `bundle install && bundle exec fastlane beta`
      branch: ${{ inputs.branch }}
      upload: ${{ inputs.upload }}
      build-number: ${{ inputs.build-number }}
```

Inside your lane these environment variables are available: `CI_BUILD_NUMBER`, `CI_UPLOAD` (`true`/`false`), and `DEVELOPER_DIR` (selected Xcode). The App Store Connect key installed by `ci-signing-setup.sh asc` is at `~/.appstoreconnect/private_keys/AuthKey_<ID>.p8` with IDs in `~/.appstoreconnect/ci.env`; use `app_store_connect_api_key(...)` to load it. If you use `match`, keep its keychain separate from your login keychain for the same reason `ci.keychain` exists (see [security.md](security.md)).
