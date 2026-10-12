#!/bin/zsh
# Ship what's on main: an annotated vX.Y.Z tag, the major tag (v1) moved to it, and a GitHub release.
# Usage: scripts/release.sh 1.4.0 --draft                       commits since the last release, to write notes from
#        scripts/release.sh 1.4.0 notes.md "Short title"        tag, move v1, publish the release
# Every app repo runs whatever v1 points at, so moving v1 *is* the release — this keeps the version history
# and the notes from being skipped. Semver: a fix is a patch, a new input or feature a minor, a change
# callers must act on a major (new v2 tag; v1 stays where it is).
# Safe to re-run after a failure: an existing tag on HEAD and an existing release are reused.
set -euo pipefail
notes=${2:-}; [[ -n $notes ]] && notes=${notes:A}   # before the cd, so a relative notes path still works
cd ${0:A:h:h}
ver=${1:?usage: release.sh <x.y.z> --draft | <x.y.z> <notes.md> <title>}
[[ $ver =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.4.0 (got $ver)"; exit 1; }
tag=v$ver major=v${ver%%.*}
git fetch -q --tags --force origin
prev=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' --exclude $tag origin/main 2>/dev/null || true)
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)

if [[ ${2:-} == --draft ]]; then
  echo "Since ${prev:-the first commit}:"; git log --format='- %h %s' ${prev:+$prev..}origin/main; exit
fi
title=${3:?usage: release.sh <x.y.z> <notes.md> <title>}
[[ -s $notes ]] || { echo "$notes is missing or empty — write what changed, why it matters, and how to upgrade"; exit 1; }
[[ $(git branch --show-current) == main ]] || { echo "Release from main"; exit 1; }
[[ -z $(git status --porcelain --untracked-files=no) ]] || { echo "Uncommitted changes"; exit 1; }
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "main isn't in sync with origin/main (pull or push first)"; exit 1; }
if git rev-parse -q --verify refs/tags/$tag >/dev/null; then
  [[ $(git rev-parse $tag^{commit}) == $(git rev-parse HEAD) ]] || { echo "$tag already exists on another commit"; exit 1; }
  echo "$tag already on HEAD, continuing"
fi
# Newer than every release of this major line, wherever it was tagged; Latest only if newer than all lines.
highest() { git tag -l "$1" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -vx $tag | sort -V | tail -1; }
top_major=$(highest "$major.*") top_all=$(highest 'v*')
[[ -n $top_major ]] && [[ $(printf '%s\n%s\n' ${top_major#v} $ver | sort -V | tail -1) != $ver ]] && { echo "$ver isn't newer than $top_major"; exit 1; }
latest=true; [[ -n $top_all ]] && [[ $(printf '%s\n%s\n' ${top_all#v} $ver | sort -V | tail -1) != $ver ]] && latest=false

body=$(<$notes)
[[ -n $prev && $body != *"/compare/"* ]] && body+=$'\n\n'"**Full changes:** https://github.com/$repo/compare/$prev...$tag"
git rev-parse -q --verify refs/tags/$tag >/dev/null || git tag -a $tag -m "$tag: $title"
git push -q origin $tag
gh release view $tag >/dev/null 2>&1 && echo "Release $tag already published, keeping it" \
  || gh release create $tag --verify-tag --latest=$latest --title "$tag — $title" --notes "$body"
git tag -f $major $tag >/dev/null
git push -q -f origin $major
echo "$major → $tag. Every app repo picks it up on its next run."
