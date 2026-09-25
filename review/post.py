#!/usr/bin/env python3
"""Post review.json as one GitHub PR review: inline comments where the line is in the diff, the rest in the summary.

usage: post.py <review.json> <provider label>   (env: GITHUB_REPOSITORY, PR, GH_TOKEN)
"""
import json, os, re, subprocess, sys

SEV = {'high': '🔴', 'medium': '🟠', 'low': '🟡'}


def gh(*args, data=None):
    r = subprocess.run(['gh', 'api', *args] + (['--input', '-'] if data is not None else []),
                       input=json.dumps(data) if data is not None else None, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f'::error::gh api {args[0]} failed: {r.stderr.strip()[:500]}')
    return json.loads(r.stdout) if r.stdout.strip() else None


def commentable_lines(repo, pr):
    """{path: set(new-file line numbers that appear in the diff)} — GitHub only accepts comments on those."""
    lines, page = {}, 1
    while True:
        files = gh(f'repos/{repo}/pulls/{pr}/files?per_page=100&page={page}')
        for f in files:
            n, ok = 0, set()
            for l in (f.get('patch') or '').splitlines():
                m = re.match(r'@@ -\d+(?:,\d+)? \+(\d+)', l)
                if m:
                    n = int(m.group(1)); continue
                if l.startswith('-'):
                    continue
                ok.add(n); n += 1
            lines[f['filename']] = ok
        if len(files) < 100:
            return lines
        page += 1


def main():
    review, label = json.load(open(sys.argv[1])), sys.argv[2]
    repo, pr = os.environ['GITHUB_REPOSITORY'], os.environ['PR']
    ok = commentable_lines(repo, pr)
    inline, rest = [], []
    for i in review['issues']:
        text = f"{SEV.get(i.get('severity'), '•')} **{i['title']}**\n\n{i['body']}"
        if i.get('line') in ok.get(i.get('path'), ()):
            inline.append({'path': i['path'], 'line': i['line'], 'side': 'RIGHT', 'body': text})
        else:
            rest.append(f"- {SEV.get(i.get('severity'), '•')} `{i.get('path')}:{i.get('line')}` **{i['title']}** — {i['body']}")
    body = f"## AI review ({label})\n\n{review['summary']}\n"
    if rest:
        body += '\n### Other findings\n' + '\n'.join(rest) + '\n'
    if not review['issues']:
        body += '\n✅ No issues found.\n'
    head = os.environ.get('HEAD_SHA') or subprocess.run(['git', 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
    gh(f'repos/{repo}/pulls/{pr}/reviews', '-X', 'POST',
       data={'commit_id': head, 'event': 'COMMENT', 'body': body, 'comments': inline})
    print(f'posted: {len(inline)} inline, {len(rest)} in summary')


if __name__ == '__main__':
    main()
