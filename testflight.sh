#!/bin/zsh
# Called by action.yml; all parameters come in as environment variables.
set -euo pipefail

source ${0:A:h}/lib.sh
trap 'rm -rf $DD' EXIT

# Signing: the runner LaunchAgent keeps SessionCreate=true, so jobs cannot see the unlocked login keychain.
# Use the dedicated ci.keychain (signing identities only) + App Store Connect API key made by scripts/ci-signing-setup.sh.
CI_KC=$HOME/Library/Keychains/ci.keychain-db
if [[ ! -f $CI_KC || ! -f $HOME/.appstoreconnect/ci.env ]]; then
  echo "::error::Signing is not set up on this Mac: run scripts/ci-signing-setup.sh status"
  exit 1
fi
security unlock-keychain -p "$(cat $HOME/.appstoreconnect/ci-keychain.pass)" $CI_KC
source $HOME/.appstoreconnect/ci.env
AUTH=(-authenticationKeyPath $HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
      -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID)
echo "Signing: ci.keychain; auth: App Store Connect API key $ASC_KEY_ID"

BUILD=${BUILD_NUMBER:-$(date +%y%m%d)01}
[[ $BUILD =~ '^[0-9]+(\.[0-9]+)*$' ]] || { echo "::error::build-number must be numeric (got '$BUILD')"; exit 1; }
ARCHIVE=$HOME/Library/Developer/Xcode/Archives/$(date +%F)/$SCHEME-$BUILD-ci-$GITHUB_RUN_ID.xcarchive

step "Archive $SCHEME ($PROJECT, build $BUILD)"
xcb archive archive "${PROJ_ARGS[@]}" -scheme "$SCHEME" -configuration $CONFIGURATION \
  -destination generic/platform=iOS -archivePath $ARCHIVE -derivedDataPath $DD \
  -allowProvisioningUpdates "${AUTH[@]}" \
  CURRENT_PROJECT_VERSION=$BUILD OTHER_CODE_SIGN_FLAGS="--keychain $CI_KC"
endstep

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' $ARCHIVE/Info.plist)
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleIdentifier' $ARCHIVE/Info.plist)

[[ $UPLOAD == true ]] && DEST=upload || DEST=export
[[ $INTERNAL_ONLY == true ]] && INTERNAL=true || INTERNAL=false
cat > $WORK/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DEST</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><true/>
  <key>testFlightInternalTestingOnly</key><$INTERNAL/>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST

step "Export (destination=$DEST)"
xcb export -exportArchive -archivePath $ARCHIVE -exportPath $WORK/export \
  -exportOptionsPlist $WORK/ExportOptions.plist -allowProvisioningUpdates "${AUTH[@]}"
endstep

# Xcode may have bumped the build number to avoid a clash; trust the export summary.
FINAL=$BUILD
SUMMARY=$WORK/export/DistributionSummary.plist
if [[ -f $SUMMARY ]]; then
  FINAL=$(python3 -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); print(next(iter(d.values()))[0].get("buildNumber",""))' $SUMMARY 2>/dev/null || true)
  [[ -z $FINAL ]] && FINAL=$BUILD
fi

echo "archive-path=$ARCHIVE" >> $GITHUB_OUTPUT
echo "build-number=$FINAL" >> $GITHUB_OUTPUT
{
  echo "### $SCHEME $VERSION ($FINAL)"
  echo "- Bundle ID: \`$BUNDLE_ID\`"
  echo "- Commit: \`$(git rev-parse --short HEAD)\` ($BRANCH_LABEL)"
  if [[ $DEST == upload ]]; then
    echo "- ✅ Uploaded to App Store Connect; it shows up in TestFlight once processed$([[ $INTERNAL == true ]] && echo ' (internal testing only)')"
  else
    echo "- 🧪 Dry run: exported the .ipa, nothing uploaded"
  fi
  echo "- Archive (visible in Xcode Organizer): \`$ARCHIVE\`"
} >> $GITHUB_STEP_SUMMARY
cat $GITHUB_STEP_SUMMARY
