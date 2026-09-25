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
typeset -A PROFILES; CERT=""

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
  # Hand xcodebuild every App Store profile of the team that uses one Distribution identity; each target
  # picks its own through a nested build-setting macro keyed by its bundle ID (SPM targets resolve to none).
  # Listing targets up front is unreliable (-showBuildSettings -scheme skips implicit dependencies such as
  # extensions and watch apps), so the archive itself is the ground truth for the export afterwards.
  step "Manual signing: profiles"
  PLAN=(${(f)"$(python3 ${0:A:h}/scripts/profiles.py plan --team $TEAM_ID)"}) || exit 1
  PROFILE_ARGS=('PROVISIONING_PROFILE_SPECIFIER=$(CI_PROFILE_$(PRODUCT_BUNDLE_IDENTIFIER:c99extidentifier))')
  for line in $PLAN; do
    parts=(${(s: :)line})
    case $parts[1] in
      IDENTITY) CERT=$parts[2]; echo "  identity: ${parts[3,-1]} ($CERT)" ;;
      # Profiles are referenced by UUID: names aren't unique (old and renewed profiles share one).
      PROFILE)  PROFILES[$parts[2]]=$parts[4]; PROFILE_ARGS+=("CI_PROFILE_$parts[3]=$parts[4]")
                echo "  $parts[2] → ${parts[5,-1]} ($parts[4])" ;;
    esac
  done
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
if [[ $SIGNING == manual && $INTERNAL == true ]]; then
  echo "::warning::internal-only can't be set when uploading with altool (manual signing); the build is uploaded normally"
fi
# Every bundle actually inside the archive (app, extensions, watch app, App Clip…) needs a profile for export.
python3 - $ARCHIVE $WORK/ExportOptions.plist $DEST $TEAM_ID $INTERNAL $SIGNING "${CERT:-}" "${(@kv)PROFILES}" <<'PY' || exit 1
import os,plistlib,sys
arch,out,dest,team,internal,signing,cert=sys.argv[1:8]
profiles=dict(zip(sys.argv[8::2],sys.argv[9::2]))
opts={'method':'app-store-connect','destination':dest,'teamID':team,'uploadSymbols':True,
      'testFlightInternalTestingOnly':internal=='true'}
if signing=='manual':
    bundles=[]
    for root,dirs,files in os.walk(os.path.join(arch,'Products','Applications')):
        for d in dirs:
            if d.endswith(('.app','.appex')):
                info=os.path.join(root,d,'Info.plist')
                if os.path.isfile(info): bundles.append(plistlib.load(open(info,'rb'))['CFBundleIdentifier'])
    missing=[b for b in bundles if b not in profiles]
    if missing:
        print(f"::error::No App Store profile for: {', '.join(missing)}. Install one per bundle ID with ci-signing-setup.sh profile … "
              "(it must use the same Distribution certificate as the others; wildcard profiles are ignored — see the warnings above)"); sys.exit(1)
    opts.update(signingStyle='manual',signingCertificate=cert,provisioningProfiles={b:profiles[b] for b in bundles})
    print('  bundles in archive:',', '.join(bundles))
else:
    opts.update(signingStyle='automatic',manageAppVersionAndBuildNumber=True)
plistlib.dump(opts,open(out,'wb'))
PY

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
base=os.path.join(arch,'Products','Applications')
bundles=[os.path.join(r,d) for r,ds,_ in os.walk(base) for d in ds if d.endswith(('.app','.appex'))]
for a in bundles:
    rel=os.path.relpath(a,base); x=os.path.join(ipa,'Payload',rel)
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
