# Pick the Xcode for this job and export DEVELOPER_DIR. Sourced by lib.sh and fastlane/action.yml.
# Xcode selection: the xcode input (a path, or a version such as 27.1 / 27) wins; otherwise the repo's
# .xcode-version file (same convention as xcodes/fastlane); otherwise the runner default.
resolve_xcode() {  # resolve_xcode <path|version> → prints an Xcode.app path
  # "27" / "27.1" pick the newest installed match, preferring release builds over betas.
  local want=$1 app ver best="" bestver="" pass
  [[ -d $want ]] && { echo $want; return; }
  [[ $want =~ '^[0-9]+(\.[0-9]+)*$' ]] || { echo "::error::xcode must be a path or a version number (got '$want')" >&2; return 1; }
  local apps=(${(f)"$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null)"} /Applications/Xcode*.app(N))
  for pass in release beta; do
    for app in ${(u)apps}; do
      [[ -f $app/Contents/Info.plist ]] || continue
      if [[ $pass == release ]]; then [[ ${app:l} == *beta* ]] && continue; else [[ ${app:l} == *beta* ]] || continue; fi
      ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $app/Contents/Info.plist 2>/dev/null) || continue
      [[ $ver == $want || $ver == $want.* ]] || continue
      if [[ -z $best || $(printf '%s\n%s\n' $bestver $ver | sort -V | tail -1) == $ver && $ver != $bestver ]]; then best=$app; bestver=$ver; fi
    done
    [[ -n $best ]] && break
  done
  [[ -n $best ]] || { echo "::error::No Xcode $want installed on this runner" >&2; return 1; }
  echo $best
}
if [[ -z ${XCODE_APP:-} || ${XCODE_APP:-} == default ]] && [[ -f .xcode-version ]]; then
  XCODE_APP=$(tr -d ' \n' < .xcode-version); echo "Using .xcode-version: $XCODE_APP"
fi
if [[ -n ${XCODE_APP:-} && $XCODE_APP != default ]]; then
  XCODE_APP=$(resolve_xcode "$XCODE_APP") || exit 1
  export DEVELOPER_DIR=$XCODE_APP/Contents/Developer
fi
: ${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}
export DEVELOPER_DIR
echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
