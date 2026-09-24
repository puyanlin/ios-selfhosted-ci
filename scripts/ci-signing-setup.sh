#!/bin/zsh
# Signing for the self-hosted runner: a dedicated ci.keychain (signing identities only) + an App Store Connect API key.
# Runner jobs run in their own security session (SessionCreate=true) and cannot see your unlocked login keychain;
# they only unlock ci.keychain, so they never get the other passwords/tokens in your login keychain.
#
# Usage:
#   ci-signing-setup.sh keychain                          create ci.keychain and copy the signing identities from login (macOS asks for your password)
#   ci-signing-setup.sh asc <AuthKey_XXXX.p8> <Issuer ID>  install an App Store Connect API key
#   ci-signing-setup.sh status                            show what is set up
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
  p8=${2:?path to the .p8}; issuer=${3:?Issuer ID}
  id=$(basename $p8 .p8); id=${id#AuthKey_}
  cp $p8 $DIR/private_keys/AuthKey_$id.p8 && chmod 600 $DIR/private_keys/AuthKey_$id.p8
  printf 'ASC_KEY_ID=%s\nASC_ISSUER_ID=%s\n' $id $issuer > $DIR/ci.env && chmod 600 $DIR/ci.env
  echo "API key $id installed ($DIR/ci.env). Move the downloaded $p8 into your password manager and delete it."
  ;;
status)
  [[ -f $KC ]] && { echo "ci.keychain: yes"; security find-identity -v -p codesigning $KC | sed 's/^/  /'; } || echo "ci.keychain: no"
  [[ -f $DIR/ci.env ]] && { echo "App Store Connect API key:"; sed 's/^/  /' $DIR/ci.env; } || echo "App Store Connect API key: no"
  ;;
*) sed -n '6,9p' $0; exit 1 ;;
esac
