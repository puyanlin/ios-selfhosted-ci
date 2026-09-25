#!/bin/zsh
# Signing for the self-hosted runner: a dedicated ci.keychain (signing identities only) + an App Store Connect API key.
# Runner jobs run in their own security session (SessionCreate=true) and cannot see your unlocked login keychain;
# they only unlock ci.keychain, so they never get the other passwords/tokens in your login keychain.
#
# Usage:
#   ci-signing-setup.sh keychain                          create ci.keychain and copy the signing identities from login (macOS asks for your password)
#   ci-signing-setup.sh asc <AuthKey_XXXX.p8> <Issuer ID> [--team TEAMID]   install an App Store Connect API key (per team if --team)
#   ci-signing-setup.sh status                            show what is set up
# Manual signing (no Admin key — e.g. a company team where you are App Manager):
#   ci-signing-setup.sh p12 <distribution.p12>            import an Apple Distribution identity into ci.keychain (asks for the .p12 password)
#   ci-signing-setup.sh profile <file.mobileprovision>... install App Store provisioning profiles (checked against ci.keychain)
#   ci-signing-setup.sh appleid <apple-id> --team TEAMID  upload with an Apple ID + app-specific password instead of an API key
set -euo pipefail

DIR=$HOME/.appstoreconnect
KC=$HOME/Library/Keychains/ci.keychain-db
PASSFILE=$DIR/ci-keychain.pass
mkdir -p $DIR/private_keys && chmod 700 $DIR

case ${1:-} in
keychain)
  if [[ ! -f $KC ]]; then
    openssl rand -hex 24 > $PASSFILE && chmod 600 $PASSFILE
    security create-keychain -p "$(cat $PASSFILE)" $KC
    security set-keychain-settings $KC          # no auto-lock
  fi
  pass=$(cat $PASSFILE)
  security unlock-keychain -p "$pass" $KC
  tmp=$(mktemp -d -t ci-identity); p12=$tmp/identity.p12; p12pass=$(openssl rand -hex 16)
  trap 'rm -rf $tmp' EXIT
  security export -k $HOME/Library/Keychains/login.keychain-db -t identities -f pkcs12 -P "$p12pass" -o $p12
  security import $p12 -k $KC -P "$p12pass" -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" $KC >/dev/null
  # Add to the user keychain search list (xcodebuild looks up identities there); login stays first.
  current=(${(f)"$(security list-keychains -d user | tr -d ' "')"})
  (( ${current[(I)$KC]} )) || security list-keychains -d user -s $current $KC
  echo "ci.keychain ready:"; security find-identity -v -p codesigning $KC
  ;;
asc)
  p8=${2:?path to the .p8}; issuer=${3:?Issuer ID}; team=""
  [[ ${4:-} == --team ]] && team=${5:?Team ID}
  id=$(basename $p8 .p8); id=${id#AuthKey_}
  cp $p8 $DIR/private_keys/AuthKey_$id.p8 && chmod 600 $DIR/private_keys/AuthKey_$id.p8
  env=$DIR/ci${team:+-$team}.env
  printf 'ASC_KEY_ID=%s\nASC_ISSUER_ID=%s\n' $id $issuer > $env && chmod 600 $env
  [[ -f $DIR/ci.env ]] || cp $env $DIR/ci.env
  echo "API key $id installed ($env). Move the downloaded $p8 into your password manager and delete it."
  ;;
p12)
  p12=${2:?path to the .p12}
  [[ -f $KC ]] || { echo "Run '$0 keychain' first"; exit 1; }
  pass=$(cat $PASSFILE); security unlock-keychain -p "$pass" $KC
  read -rs "p12pass?Password of $p12 (hidden): "; echo
  security import $p12 -k $KC -P "$p12pass" -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild
  # Without this, codesign stops at a (headless, invisible) permission prompt until the job times out.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" $KC >/dev/null
  echo "Identities in ci.keychain:"; security find-identity -v -p codesigning $KC
  ;;
profile)
  shift; (( $# )) || { echo "usage: $0 profile <file.mobileprovision>..."; exit 1; }
  python3 ${0:A:h}/profiles.py install "$@"
  ;;
appleid)
  appleid=${2:?Apple ID}; [[ ${3:-} == --team ]] || { echo "usage: $0 appleid <apple-id> --team TEAMID"; exit 1; }; team=${4:?Team ID}
  [[ -f $KC ]] || { echo "Run '$0 keychain' first"; exit 1; }
  echo "Create an app-specific password at https://account.apple.com (Sign-In and Security › App-Specific Passwords)."
  read -rs "apppass?App-specific password for $appleid (hidden): "; echo
  security unlock-keychain -p "$(cat $PASSFILE)" $KC
  security add-generic-password -U -a "$appleid" -s ios-selfhosted-ci-upload -w "$apppass" $KC
  printf 'ASC_APPLE_ID=%s\n' "$appleid" > $DIR/ci-$team.env && chmod 600 $DIR/ci-$team.env
  echo "Uploads for team $team will use $appleid ($DIR/ci-$team.env). Submitting for review still needs an API key or the website."
  ;;
status)
  [[ -f $KC ]] && { echo "ci.keychain: yes"; security find-identity -v -p codesigning $KC | sed 's/^/  /'; } || echo "ci.keychain: no"
  found=0
  for env in $DIR/ci.env $DIR/ci-*.env(N); do
    [[ -f $env ]] || continue; found=1
    echo "Upload auth ${${env:t:r}#ci}:"; sed 's/^/  /' $env
  done
  (( found )) || echo "App Store Connect API key: no"
  echo "App Store profiles for manual signing:"; python3 ${0:A:h}/profiles.py list | sed 's/^/  /'
  ;;
*) sed -n '6,14p' $0; exit 1 ;;
esac
