# Shared by the scripts: load ~/.config/ios-selfhosted-ci/config.
CONFIG=${IOS_SELFHOSTED_CI_CONFIG:-$HOME/.config/ios-selfhosted-ci/config}
[[ -f $CONFIG ]] || { echo "Missing $CONFIG — copy config.example there and edit it."; exit 1; }
source $CONFIG
: ${GH_OWNER:?set GH_OWNER in $CONFIG} ${TEAM_ID:?set TEAM_ID in $CONFIG}
: ${CI_REPO:=puyanlin/ios-selfhosted-ci} ${CI_REF:=v1} ${XCODE_APP:=/Applications/Xcode.app}
: ${XCODE_BETA_APP:=} ${REVIEW_LANGUAGE:=} ${COMMIT_TRAILER:=}
