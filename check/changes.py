#!/usr/bin/env python3
"""Called by check/action.yml before the build: does this pull request touch the app?

PATHS / PATHS_IGNORE hold newline-separated patterns in GitHub's `on.<pull_request>.paths` syntax
(`*` any characters except `/`, `**` any characters, `?` / `+` zero-or-one / one-or-more of the preceding
character, `[...]` one of, a leading `!` excludes; the last matching pattern decides). The build runs when
at least one changed file matches PATHS (or PATHS is empty) and is not matched by PATHS_IGNORE.

Writes build=true|false to $GITHUB_OUTPUT. It never fails the job: when the changed files can't be
determined (not a pull_request event, HEAD isn't this PR's merge commit, git error) it answers build=true. A skipped build
still ends the job successfully, so a required "PR check" never blocks a PR that doesn't touch the app.

The changed files come from the merge commit actions/checkout checks out for pull_request events
(refs/pull/N/merge): its parents are [base, PR head], so `git diff base HEAD` is exactly what the PR
changes. HEAD only counts as that commit when its second parent is the head SHA in the event payload —
a checkout of the PR head (which may itself be a "merge main into feature" commit) or of the base branch
builds. The base parent is fetched on its own (depth 1); objects already in the checkout aren't re-sent.
"""
import json
import os
import re
import subprocess
import sys

PR_EVENT = "pull_request"  # pull_request_target checks out the base branch: no merge commit to diff


def patterns(text):
    """Newline-separated patterns; blank lines and lines starting with # are ignored."""
    return [line.strip() for line in (text or "").splitlines() if line.strip() and not line.strip().startswith("#")]


def to_regex(pattern):
    """One filter pattern (without a leading !) as an anchored regex."""
    out, i, n = [], 0, len(pattern)
    while i < n:
        c = pattern[i]
        if c == "\\" and i + 1 < n:  # escaped special character
            out.append(re.escape(pattern[i + 1]))
            i += 2
            continue
        if pattern.startswith("**", i):
            i += 2
            if i < n and pattern[i] == "/":  # "**/" = zero or more directories
                out.append("(?:.*/)?")
                i += 1
            else:
                out.append(".*")
            continue
        if c == "*":
            out.append("[^/]*")
        elif c in "?+":
            out.append(c)  # quantifier on the preceding character, as in GitHub's filter syntax
        elif c == "[":
            end = pattern.find("]", i + 1)
            if end == -1:
                out.append(re.escape(c))
            else:
                out.append("[" + pattern[i + 1 : end].replace("\\", "\\\\") + "]")
                i = end
        else:
            out.append(re.escape(c))
        i += 1
    return re.compile("".join(out) + r"\Z")


def compile_patterns(lines):
    return [(line.startswith("!"), to_regex(line[1:] if line.startswith("!") else line)) for line in lines]


def matches(path, compiled):
    """GitHub semantics: the last pattern that matches decides; a ! pattern excludes."""
    result = False
    for negated, regex in compiled:
        if regex.match(path):
            result = not negated
    return result


def relevant(files, paths, ignore):
    """The changed files that should trigger the build."""
    inc, exc = compile_patterns(paths), compile_patterns(ignore)
    return [f for f in files if (not inc or matches(f, inc)) and not matches(f, exc)]


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True, timeout=120).stdout


def pr_head_sha():
    with open(os.environ["GITHUB_EVENT_PATH"]) as fh:
        return json.load(fh)["pull_request"]["head"]["sha"]


def changed_files():
    parents = [line.split()[1] for line in git("cat-file", "-p", "HEAD").splitlines() if line.startswith("parent ")]
    if len(parents) != 2 or parents[1] != pr_head_sha():
        raise RuntimeError("HEAD is not this pull request's merge commit (custom checkout ref?)")
    base = parents[0]
    git("fetch", "--quiet", "--no-tags", "--depth=1", "origin", base)
    out = git("diff", "--name-only", "--no-renames", "-z", base, "HEAD")
    return [f for f in out.split("\0") if f]


def emit(build, summary=None):
    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a") as fh:
        fh.write(f"build={'true' if build else 'false'}\n")
    if summary:
        with open(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull), "a") as fh:
            fh.write(summary + "\n")


def main():
    paths, ignore = patterns(os.environ.get("PATHS")), patterns(os.environ.get("PATHS_IGNORE"))
    if not paths and not ignore:
        return emit(True)
    event = os.environ.get("GITHUB_EVENT_NAME", "")
    if event != PR_EVENT:
        print(f"{event or 'this'} event: path filters only apply to pull requests — building")
        return emit(True)
    try:
        files = changed_files()
    except Exception as e:  # never block a PR on the filter itself
        print(f"::warning::Could not list the pull request's changed files ({e}); building anyway")
        return emit(True)
    if not files:
        print("No changed files found — building anyway")
        return emit(True)
    hits = relevant(files, paths, ignore)
    if hits:
        print(f"{len(hits)} of {len(files)} changed files need the build, e.g.:")
        for f in hits[:20]:
            print(f"  {f}")
        return emit(True)
    print(f"::notice::No app changes in this pull request ({len(files)} changed files, all outside the paths filter) — build and tests skipped")
    for f in files[:50]:
        print(f"  {f}")
    emit(False, f"### PR check skipped\nNone of the {len(files)} changed files match this repo's `paths` / `paths-ignore` filter, so the build and tests were skipped. The check still passes.")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # last resort: a broken filter must not fail or skip the check
        print(f"::warning::Path filter failed ({e}); building anyway")
        emit(True)
    sys.exit(0)
