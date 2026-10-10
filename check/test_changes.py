"""python3 -m unittest discover -s check   (no dependencies)"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from changes import compile_patterns, matches, patterns, relevant  # noqa: E402

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "changes.py")


def write(path, text):
    with open(path, "w") as fh:
        fh.write(text)


def read(path):
    with open(path) as fh:
        return fh.read()


def m(path, *pats):
    return matches(path, compile_patterns(list(pats)))


class PatternTests(unittest.TestCase):
    def test_star_stays_in_one_directory(self):
        self.assertTrue(m("docs/a.md", "docs/*"))
        self.assertFalse(m("docs/sub/a.md", "docs/*"))
        self.assertTrue(m("README.md", "*.md"))
        self.assertFalse(m("docs/README.md", "*.md"))

    def test_double_star_crosses_directories(self):
        self.assertTrue(m("web/src/app/page.tsx", "web/**"))
        self.assertFalse(m("webkit/a.swift", "web/**"))
        self.assertTrue(m("README.md", "**/*.md"))
        self.assertTrue(m("a/b/c/NOTES.md", "**/*.md"))
        self.assertTrue(m("App/Views/Main.swift", "**.swift"))
        self.assertTrue(m("src/x/docs/y", "**/docs/**"))

    def test_question_and_plus_are_quantifiers_like_github(self):
        self.assertTrue(m("file.js", "*.jsx?"))
        self.assertTrue(m("file.jsx", "*.jsx?"))
        self.assertTrue(m("v11/a", "v1+/*"))
        self.assertFalse(m("v/a", "v1+/*"))

    def test_brackets_and_escapes(self):
        self.assertTrue(m("v2/a", "v[0-9]/a"))
        self.assertFalse(m("vx/a", "v[0-9]/a"))
        self.assertTrue(m("a+b.txt", r"a\+b.txt"))
        self.assertFalse(m("aab.txt", r"a\+b.txt"))
        self.assertFalse(m("aXmd", "a.md"))

    def test_last_match_wins_and_bang_excludes(self):
        pats = ["web/**", "!web/shared/**"]
        self.assertTrue(m("web/app.ts", *pats))
        self.assertFalse(m("web/shared/model.ts", *pats))
        self.assertTrue(m("web/shared/model.ts", *pats, "web/shared/model.ts"))

    def test_pattern_list_parsing(self):
        self.assertEqual(patterns("web/**\n\n  # comment\n android/** \n"), ["web/**", "android/**"])


class RelevantTests(unittest.TestCase):
    files = ["web/src/page.tsx", "android/app/build.gradle.kts", "README.md"]

    def test_paths_ignore_skips_when_everything_is_ignored(self):
        self.assertEqual(relevant(self.files, [], ["web/**", "android/**", "**/*.md"]), [])
        self.assertEqual(relevant(self.files + ["App/Main.swift"], [], ["web/**", "android/**"]), ["README.md", "App/Main.swift"])

    def test_paths_requires_a_match(self):
        self.assertEqual(relevant(self.files, ["App/**", "*.xcodeproj/**"], []), [])
        self.assertEqual(relevant(self.files + ["App.xcodeproj/project.pbxproj"], ["App/**", "*.xcodeproj/**"], []), ["App.xcodeproj/project.pbxproj"])

    def test_paths_and_paths_ignore_together(self):
        self.assertEqual(relevant(["App/a.swift", "App/README.md"], ["App/**"], ["**/*.md"]), ["App/a.swift"])


class EndToEndTests(unittest.TestCase):
    """Runs changes.py against a real shallow checkout of a pull request merge commit."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        origin, work = os.path.join(self.dir, "origin"), os.path.join(self.dir, "work")

        def g(*a, cwd):
            subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *a], cwd=cwd, check=True, capture_output=True)

        os.makedirs(os.path.join(origin, "App"))
        g("init", "-q", "-b", "main", cwd=origin)
        write(os.path.join(origin, "App", "a.swift"), "1")
        g("add", ".", cwd=origin)
        g("commit", "-q", "-m", "base", cwd=origin)
        g("checkout", "-q", "-b", "feature", cwd=origin)
        os.makedirs(os.path.join(origin, "web"))
        write(os.path.join(origin, "web", "page.tsx"), "x")
        g("add", ".", cwd=origin)
        g("commit", "-q", "-m", "web only", cwd=origin)
        g("checkout", "-q", "main", cwd=origin)
        write(os.path.join(origin, "App", "b.swift"), "2")  # main moved on after the branch point
        g("add", ".", cwd=origin)
        g("commit", "-q", "-m", "main moves", cwd=origin)
        g("checkout", "-q", "-b", "merge", cwd=origin)
        g("merge", "-q", "--no-ff", "-m", "merge", "feature", cwd=origin)
        g("checkout", "-q", "main", cwd=origin)
        # like actions/checkout: a depth-1 fetch of the merge ref
        os.makedirs(work)
        g("init", "-q", cwd=work)
        g("remote", "add", "origin", "file://" + origin, cwd=work)
        g("fetch", "-q", "--depth=1", "origin", "+refs/heads/merge:refs/remotes/pull/1/merge", cwd=work)
        g("checkout", "-q", "refs/remotes/pull/1/merge", cwd=work)
        self.work = work

    def run_filter(self, event="pull_request", **env):
        out = os.path.join(self.dir, "out")
        write(out, "")
        e = {**os.environ, "GITHUB_EVENT_NAME": event, "GITHUB_OUTPUT": out, "GITHUB_STEP_SUMMARY": os.devnull, **env}
        r = subprocess.run([sys.executable, SCRIPT], cwd=self.work, env=e, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return read(out).strip()

    def test_skips_a_pr_that_only_touches_ignored_paths(self):
        # main's own new file (App/b.swift) is not part of the PR and must not count
        self.assertEqual(self.run_filter(PATHS_IGNORE="web/**"), "build=false")

    def test_builds_when_an_app_file_changed(self):
        self.assertEqual(self.run_filter(PATHS="web/**"), "build=true")
        self.assertEqual(self.run_filter(PATHS="App/**"), "build=false")

    def test_always_builds_without_filters_or_outside_pull_requests(self):
        self.assertEqual(self.run_filter(), "build=true")
        self.assertEqual(self.run_filter(event="workflow_dispatch", PATHS_IGNORE="web/**"), "build=true")

    def test_builds_when_the_changed_files_cannot_be_determined(self):
        subprocess.run(["git", "remote", "set-url", "origin", "file:///nonexistent"], cwd=self.work, check=True)
        self.assertEqual(self.run_filter(PATHS_IGNORE="web/**"), "build=true")


if __name__ == "__main__":
    unittest.main()
