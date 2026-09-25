#!/bin/zsh
# Called by action.yml; all parameters come in as environment variables.
set -euo pipefail

source ${0:A:h}/lib.sh
trap 'rm -rf $DD' EXIT

# Signing: the runner LaunchAgent keeps SessionCreate=true, so jobs cannot see the unlocked login keychain.
# Identities live in the dedicated ci.keychain made by scripts/ci-signing-setup.sh.
#   cloud  (default) Xcode cloud-managed distribution signing — needs an Admin API key
#   manual           your own Apple Distribution identity + App Store profiles — works with an App Manager key
#                    or an Apple ID + app-specific password (company teams)
CI_KC=$HOME/Library/Keychains/ci.keychain-db
[[ -f $CI_KC ]] || { echo "::error::No ci.keychain on this Mac: run scripts/ci-signing-setup.sh keychain"; exit 1; }
security unlock-keychain -p "$(cat $HOME/.appstoreconnect/ci-keychain.pass)" $CI_KC
SIGNING=${SIGNING_STYLE:-cloud}

# Upload auth: per-team file first (ci-<TEAMID>.env), then the default ci.env.
ASC_KEY_ID=""; ASC_ISSUER_ID=""; ASC_APPLE_ID=""
for env in $HOME/.appstoreconnect/ci-$TEAM_ID.env $HOME/.appstoreconnect/ci.env; do
  [[ -f $env ]] && { source $env; break; }
done
AUTH=()
if [[ -n $ASC_KEY_ID ]]; then
  AUTH=(-authenticationKeyPath $HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
        -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID)
  echo "Upload auth: App Store Connect API key $ASC_KEY_ID"
elif [[ -n $ASC_APPLE_ID ]]; then
  echo "Upload auth: Apple ID $ASC_APPLE_ID (app-specific password in ci.keychain)"
  [[ $SIGNING == manual ]] || { echo "::error::An Apple ID can't do cloud signing; use signing: manual for team $TEAM_ID"; exit 1; }
else
  echo "::error::No upload credentials for team $TEAM_ID: run scripts/ci-signing-setup.sh asc … or appleid …"; exit 1
fi

BUILD=${BUILD_NUMBER:-$(date +%y%m%d)01}
[[ $BUILD =~ '^[0-9]+(\.[0-9]+)*$' ]] || { echo "::error::build-number must be numeric (got '$BUILD')"; exit 1; }
ARCHIVE=$HOME/Library/Developer/Xcode/Archives/$(date +%F)/$SCHEME-$BUILD-ci-$GITHUB_RUN_ID.xcarchive

if [[ $SIGNING == manual ]]; then
  # Map every app/extension bundle ID of the project to an installed App Store profile, and sign the archive
  # with it: each target picks its own profile through a nested build-setting macro, SPM targets get none.
  step "Manual signing: matching provisioning profiles"
  BUNDLES=(${(f)"$(xcodebuild "${PROJ_ARGS[@]}" -scheme "$SCHEME" -configuration $CONFIGURATION -destination generic/platform=iOS \
    -showBuildSettings -json 2>/dev/null | python3 -c '
import json,sys
for t in json.load(sys.stdin):
    b=t["buildSettings"]
    if b.get("WRAPPER_EXTENSION") in ("app","appex") and b.get("PRODUCT_BUNDLE_IDENTIFIER"): print(b["PRODUCT_BUNDLE_IDENTIFIER"])' | sort -u)"})
  (( ${#BUNDLES} )) || { echo "::error::Could not read the bundle IDs of $SCHEME"; exit 1; }
  MAP=(${(f)"$(python3 ${0:A:h}/scripts/profiles.py match --team $TEAM_ID $BUNDLES)"}) || exit 1
  PROFILE_ARGS=('PROVISIONING_PROFILE_SPECIFIER=$(CI_PROFILE_$(PRODUCT_BUNDLE_IDENTIFIER:c99extidentifier))')
  typeset -A PROFILES
  for line in $MAP; do
    b=${line%%$'\t'*}; rest=${line#*$'\t'}; name=${rest%%$'\t'*}; CERT=${rest##*$'\t'}
    PROFILES[$b]=$name
    PROFILE_ARGS+=("CI_PROFILE_$(python3 -c 'import re,sys;s=re.sub(r"[^A-Za-z0-9_]","_",sys.argv[1]);print(("_"+s) if s[0].isdigit() else s)' $b)=$name")
    echo "  $b → $name"
  done
  echo "Signing identity: $CERT"
  endstep
  step "Archive $SCHEME ($PROJECT, build $BUILD, manual signing)"
  xcb archive archive "${PROJ_ARGS[@]}" -scheme "$SCHEME" -configuration $CONFIGURATION \
    -destination generic/platform=iOS -archivePath $ARCHIVE -derivedDataPath $DD \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=$TEAM_ID CODE_SIGN_IDENTITY=$CERT "${PROFILE_ARGS[@]}" \
    CURRENT_PROJECT_VERSION=$BUILD OTHER_CODE_SIGN_FLAGS="--keychain $CI_KC"
  endstep
else
  [[ -n $ASC_KEY_ID ]] || { echo "::error::Cloud signing needs an App Store Connect API key (Admin)"; exit 1; }
  step "Archive $SCHEME ($PROJECT, build $BUILD)"
  xcb archive archive "${PROJ_ARGS[@]}" -scheme "$SCHEME" -configuration $CONFIGURATION \
    -destination generic/platform=iOS -archivePath $ARCHIVE -derivedDataPath $DD \
    -allowProvisioningUpdates "${AUTH[@]}" \
    CURRENT_PROJECT_VERSION=$BUILD OTHER_CODE_SIGN_FLAGS="--keychain $CI_KC"
  endstep
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' $ARCHIVE/Info.plist)
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleIdentifier' $ARCHIVE/Info.plist)

[[ $INTERNAL_ONLY == true ]] && INTERNAL=true || INTERNAL=false
# Cloud signing uploads straight from exportArchive. Manual signing exports an .ipa first so the entitlements
# can be verified, then uploads it with altool (API key or Apple ID).
if [[ $SIGNING == manual ]]; then DEST=export; else [[ $UPLOAD == true ]] && DEST=upload || DEST=export; fi
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  echo '<plist version="1.0"><dict>'
  echo "  <key>method</key><string>app-store-connect</string>"
  echo "  <key>destination</key><string>$DEST</string>"
  echo "  <key>teamID</key><string>$TEAM_ID</string>"
  echo "  <key>uploadSymbols</key><true/>"
  echo "  <key>testFlightInternalTestingOnly</key><$INTERNAL/>"
  if [[ $SIGNING == manual ]]; then
    echo "  <key>signingStyle</key><string>manual</string>"
    echo "  <key>signingCertificate</key><string>$CERT</string>"
    echo "  <key>provisioningProfiles</key><dict>"
    for b name in ${(kv)PROFILES}; do echo "    <key>$b</key><string>$name</string>"; done
    echo "  </dict>"
  else
    echo "  <key>signingStyle</key><string>automatic</string>"
    echo "  <key>manageAppVersionAndBuildNumber</key><true/>"
  fi
  echo '</dict></plist>'
} > $WORK/ExportOptions.plist

step "Export (destination=$DEST, signing=$SIGNING)"
if [[ $SIGNING == manual ]]; then
  xcb export -exportArchive -archivePath $ARCHIVE -exportPath $WORK/export -exportOptionsPlist $WORK/ExportOptions.plist
else
  xcb export -exportArchive -archivePath $ARCHIVE -exportPath $WORK/export \
    -exportOptionsPlist $WORK/ExportOptions.plist -allowProvisioningUpdates "${AUTH[@]}"
fi
endstep

if [[ $SIGNING == manual ]]; then
  IPA=($WORK/export/*.ipa(N)); IPA=${IPA[1]:-}
  [[ -n $IPA ]] || { echo "::error::Export produced no .ipa"; exit 1; }
  # The exported app must keep the archive's entitlements (push, iCloud, App Groups…) with production values.
  step "Verify entitlements"
  rm -rf $WORK/ipa && mkdir -p $WORK/ipa && ditto -x -k $IPA $WORK/ipa
  python3 - $ARCHIVE $WORK/ipa <<'PY' || exit 1
import glob,os,plistlib,subprocess,sys
def ents(app):
    out=subprocess.run(['codesign','-d','--entitlements','-','--xml',app],capture_output=True).stdout
    return plistlib.loads(out) if out.strip() else {}
arch,ipa=sys.argv[1],sys.argv[2]
ok=True
for a in glob.glob(arch+'/Products/Applications/*.app')+glob.glob(arch+'/Products/Applications/*.app/PlugIns/*.appex'):
    rel=a.split('/Products/Applications/')[1]; x=os.path.join(ipa,'Payload',rel)
    ea,ex=ents(a),ents(x)
    lost=sorted(set(ea)-set(ex)-{'get-task-allow'})
    bad=[]
    if ex.get('get-task-allow'): bad.append('get-task-allow=true')
    if 'aps-environment' in ex and ex['aps-environment']!='production': bad.append('aps-environment='+ex['aps-environment'])
    print(f"  {rel}: {len(ex)} entitlements" + (f"  ✗ lost {lost}" if lost else '') + (f"  ✗ {bad}" if bad else ''))
    ok = ok and not lost and not bad
if not ok: print('::error::The exported app lost or changed entitlements'); sys.exit(1)
PY
  endstep
  if [[ $UPLOAD == true ]]; then
    step "Upload with altool"
    if [[ -n $ASC_KEY_ID ]]; then
      UP=(--apiKey $ASC_KEY_ID --apiIssuer $ASC_ISSUER_ID)
    else
      export ALTOOL_APP_PASSWORD=$(security find-generic-password -a "$ASC_APPLE_ID" -s ios-selfhosted-ci-upload -w $CI_KC)
      UP=(-u "$ASC_APPLE_ID" -p @env:ALTOOL_APP_PASSWORD)
    fi
    xcrun altool --upload-app -t ios -f $IPA "${UP[@]}" > $WORK/upload.log 2>&1 || {
      endstep; echo "::error::altool upload failed"; grep -iE 'error|fail' $WORK/upload.log | head -20; exit 1; }
    tail -3 $WORK/upload.log
    endstep
    DEST=upload
  fi
fi

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
