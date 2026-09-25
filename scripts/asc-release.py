#!/usr/bin/env python3
"""Prepare and submit an App Store version for review via the App Store Connect API.

  asc-release.py status --bundle-id com.example.app [--version 1.2.0]
  asc-release.py submit --bundle-id com.example.app --version 1.2.0 [options]

submit options:
  --build N|latest        build number to attach (default: latest VALID build of that version)
  --wait-build MIN        wait up to MIN minutes for the build to finish processing (default 0)
  --notes-dir DIR         read "What's New" from DIR/<locale>/release_notes.txt (fastlane deliver layout)
  --whats-new LOCALE=TEXT  set "What's New" for one locale (repeatable; wins over --notes-dir)
  --release after-approval|manual   (default: keep current)
  --phased / --no-phased  7-day phased release on/off (default: keep current)
  --review-notes TEXT     notes for App Review
  --dry-run               show every step, change nothing

Uses the API key from ~/.appstoreconnect/ci.env (scripts/ci-signing-setup.sh asc). Needs the App Manager or Admin role.
"""
import argparse, json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc import call  # noqa: E402

EDITABLE = {'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY'}
DRY = False


def step(msg):
    print(f'• {msg}', flush=True)


def write(method, path, body=None, what=''):
    if DRY:
        step(f'[dry run] would {what or method + " " + path}')
        return {}
    return call(method, path, body)


def fail(msg):
    print(f'::error::{msg}' if os.environ.get('GITHUB_ACTIONS') else f'✗ {msg}', file=sys.stderr)
    sys.exit(1)


def rel(type_, id_):
    return {'data': {'type': type_, 'id': id_}}


def find_app(bundle_id):
    d = call('GET', f'/v1/apps?filter[bundleId]={bundle_id}&fields[apps]=name,bundleId')['data']
    if not d:
        fail(f'No app with bundle ID {bundle_id} in App Store Connect (create the app record on the website first)')
    return d[0]['id'], d[0]['attributes']['name']


def versions(app):
    return call('GET', f'/v1/apps/{app}/appStoreVersions?filter[platform]=IOS&limit=10'
                       '&fields[appStoreVersions]=versionString,appStoreState,releaseType')['data']


def find_build(app, version, number):
    q = f'/v1/builds?filter[app]={app}&filter[preReleaseVersion.version]={version}&sort=-uploadedDate&limit=20' \
        '&fields[builds]=version,processingState,expired,usesNonExemptEncryption,uploadedDate'
    if number and number != 'latest':
        q += f'&filter[version]={number}'
    return [b for b in call('GET', q)['data'] if not b['attributes']['expired']]


def cmd_status(a):
    app, name = find_app(a.bundle_id)
    print(f'{name} ({a.bundle_id}) app id {app}')
    for v in versions(app):
        at = v['attributes']
        if a.version and at['versionString'] != a.version:
            continue
        b = call('GET', f"/v1/appStoreVersions/{v['id']}/build?fields[builds]=version").get('data')
        print(f"  {at['versionString']:10} {at['appStoreState']:26} release={at['releaseType']:15} build={b['attributes']['version'] if b else '-'}")
    if a.version:
        for b in find_build(app, a.version, None)[:5]:
            at = b['attributes']
            print(f"  build {at['version']:12} {at['processingState']:11} uploaded {at['uploadedDate'][:16]}")


def cmd_submit(a):
    global DRY
    DRY = a.dry_run
    app, name = find_app(a.bundle_id)
    step(f'App: {name} ({app})')

    # 1. Version: reuse the editable one (renaming it if needed) or create it.
    vs = versions(app)
    v = next((x for x in vs if x['attributes']['versionString'] == a.version), None)
    if v and v['attributes']['appStoreState'] not in EDITABLE:
        fail(f"{a.version} is {v['attributes']['appStoreState']} — nothing to submit")
    if not v:
        editable = next((x for x in vs if x['attributes']['appStoreState'] in EDITABLE), None)
        if editable:
            step(f"Renaming editable version {editable['attributes']['versionString']} → {a.version}")
            write('PATCH', f"/v1/appStoreVersions/{editable['id']}", {'data': {'type': 'appStoreVersions', 'id': editable['id'],
                  'attributes': {'versionString': a.version}}}, f'rename version to {a.version}')
            v = editable
        else:
            step(f'Creating version {a.version}')
            r = write('POST', '/v1/appStoreVersions', {'data': {'type': 'appStoreVersions',
                      'attributes': {'platform': 'IOS', 'versionString': a.version},
                      'relationships': {'app': rel('apps', app)}}}, f'create version {a.version}')
            v = r.get('data') or {'id': 'NEW', 'attributes': {'appStoreState': 'PREPARE_FOR_SUBMISSION'}}
    vid = v['id']
    step(f"Version {a.version}: {v['attributes']['appStoreState']}")

    # 2. Build: wait for processing, check export compliance, attach.
    deadline = time.time() + a.wait_build * 60
    while True:
        builds = find_build(app, a.version, a.build)
        valid = [b for b in builds if b['attributes']['processingState'] == 'VALID']
        if valid or time.time() >= deadline:
            break
        step(f"Waiting for build {a.build or 'latest'} of {a.version} to finish processing…")
        time.sleep(30)
    if not valid:
        fail(f"No processed build{(" " + a.build) if a.build else ""} for {a.version} (found: {[b['attributes']['version'] + ':' + b['attributes']['processingState'] for b in builds] or 'none'})")
    build = valid[0]
    if build['attributes']['usesNonExemptEncryption'] is None:
        fail(f"Build {build['attributes']['version']} has no export-compliance answer. Set ITSAppUsesNonExemptEncryption in Info.plist (or answer it once in App Store Connect).")
    cur = call('GET', f'/v1/appStoreVersions/{vid}/build?fields[builds]=version').get('data') if vid != 'NEW' else None
    if cur and cur['id'] == build['id']:
        step(f"Build {build['attributes']['version']} already attached")
    else:
        step(f"Attaching build {build['attributes']['version']}" + (f" (replacing {cur['attributes']['version']})" if cur else ''))
        write('PATCH', f'/v1/appStoreVersions/{vid}/relationships/build', rel('builds', build['id']),
              f"attach build {build['attributes']['version']}")

    # 3. What's New per locale.
    notes = {}
    if a.notes_dir and os.path.isdir(a.notes_dir):
        for loc in sorted(os.listdir(a.notes_dir)):
            f = os.path.join(a.notes_dir, loc, 'release_notes.txt')
            if os.path.isfile(f):
                notes[loc] = open(f, encoding='utf-8').read().strip()
    for kv in a.whats_new or []:
        loc, _, text = kv.partition('=')
        notes[loc] = text.strip().replace('\\n', '\n')
    locs = call('GET', f'/v1/appStoreVersions/{vid}/appStoreVersionLocalizations?fields[appStoreVersionLocalizations]=locale,whatsNew')['data'] if vid != 'NEW' else []
    first_release = not any(x['attributes']['appStoreState'] == 'READY_FOR_SALE' or x['attributes']['appStoreState'].startswith('REPLACED') for x in vs)
    missing = []
    for l in locs:
        loc, current = l['attributes']['locale'], (l['attributes']['whatsNew'] or '').strip()
        if loc in notes and notes[loc] != current:
            step(f"What's New [{loc}]: updating ({len(notes[loc])} chars)")
            write('PATCH', f"/v1/appStoreVersionLocalizations/{l['id']}", {'data': {'type': 'appStoreVersionLocalizations',
                  'id': l['id'], 'attributes': {'whatsNew': notes[loc]}}}, f"set What's New [{loc}]")
        elif current or loc in notes:
            step(f"What's New [{loc}]: ok")
        elif not first_release:
            missing.append(loc)
    for loc in set(notes) - {l['attributes']['locale'] for l in locs}:
        step(f"⚠️ {loc} has notes but the app has no {loc} localization — skipped")
    if missing:
        fail(f"What's New is empty for: {', '.join(missing)} (use --whats-new {missing[0]}=… or {a.notes_dir or 'fastlane/metadata'}/<locale>/release_notes.txt)")

    # 4. Release type, phased release, review notes.
    if a.release:
        rt = {'after-approval': 'AFTER_APPROVAL', 'manual': 'MANUAL'}[a.release]
        if v['attributes'].get('releaseType') != rt:
            step(f'Release: {rt}')
            write('PATCH', f'/v1/appStoreVersions/{vid}', {'data': {'type': 'appStoreVersions', 'id': vid,
                  'attributes': {'releaseType': rt}}}, f'set release type {rt}')
    if a.phased is not None and vid != 'NEW':
        pr = call('GET', f'/v1/appStoreVersions/{vid}/appStoreVersionPhasedRelease').get('data')
        if a.phased and not pr:
            step('Phased release: on (7 days)')
            write('POST', '/v1/appStoreVersionPhasedReleases', {'data': {'type': 'appStoreVersionPhasedReleases',
                  'attributes': {'phasedReleaseState': 'INACTIVE'}, 'relationships': {'appStoreVersion': rel('appStoreVersions', vid)}}},
                  'turn phased release on')
        elif not a.phased and pr:
            step('Phased release: off (100% on release)')
            write('DELETE', f"/v1/appStoreVersionPhasedReleases/{pr['id']}", what='turn phased release off')
        else:
            step(f"Phased release: {'on' if pr else 'off'} (unchanged)")
    if a.review_notes is not None and vid != 'NEW':
        rd = call('GET', f'/v1/appStoreVersions/{vid}/appStoreReviewDetail').get('data')
        if rd:
            write('PATCH', f"/v1/appStoreReviewDetails/{rd['id']}", {'data': {'type': 'appStoreReviewDetails', 'id': rd['id'],
                  'attributes': {'notes': a.review_notes}}}, 'set review notes')
        else:
            write('POST', '/v1/appStoreReviewDetails', {'data': {'type': 'appStoreReviewDetails', 'attributes': {'notes': a.review_notes},
                  'relationships': {'appStoreVersion': rel('appStoreVersions', vid)}}}, 'set review notes')
        step('Review notes set')

    # 5. Submit: reuse an open review submission (incl. one with unresolved issues after a rejection).
    subs = call('GET', f'/v1/reviewSubmissions?filter[app]={app}&filter[platform]=IOS&filter[state]=READY_FOR_REVIEW,UNRESOLVED_ISSUES')['data']
    if subs:
        rs = subs[0]['id']; step(f"Using open review submission ({subs[0]['attributes']['state']})")
    else:
        r = write('POST', '/v1/reviewSubmissions', {'data': {'type': 'reviewSubmissions', 'attributes': {'platform': 'IOS'},
                  'relationships': {'app': rel('apps', app)}}}, 'create review submission')
        rs = (r.get('data') or {}).get('id', 'NEW')
    items = call('GET', f'/v1/reviewSubmissions/{rs}/items?include=appStoreVersion')['data'] if rs != 'NEW' else []
    if not any(((i.get('relationships') or {}).get('appStoreVersion') or {}).get('data', {}) and
               i['relationships']['appStoreVersion']['data']['id'] == vid for i in items):
        write('POST', '/v1/reviewSubmissionItems', {'data': {'type': 'reviewSubmissionItems', 'relationships': {
              'reviewSubmission': rel('reviewSubmissions', rs), 'appStoreVersion': rel('appStoreVersions', vid)}}},
              f'add version {a.version} to the submission')
    r = write('PATCH', f'/v1/reviewSubmissions/{rs}', {'data': {'type': 'reviewSubmissions', 'id': rs,
              'attributes': {'submitted': True}}}, 'SUBMIT FOR REVIEW')
    if DRY:
        print(f'\n✓ Dry run OK: {name} {a.version} (build {build["attributes"]["version"]}) is ready to submit.')
        return
    state = call('GET', f'/v1/appStoreVersions/{vid}?fields[appStoreVersions]=appStoreState')['data']['attributes']['appStoreState']
    print(f'\n✅ Submitted {name} {a.version} (build {build["attributes"]["version"]}): {state}')
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as f:
            f.write(f'### ✅ {name} {a.version} submitted for review\n- Build {build["attributes"]["version"]}\n- State: {state}\n')


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('status'); s.add_argument('--bundle-id', required=True); s.add_argument('--version')
    m = sub.add_parser('submit')
    m.add_argument('--bundle-id', required=True); m.add_argument('--version', required=True)
    m.add_argument('--build'); m.add_argument('--wait-build', type=int, default=0)
    m.add_argument('--notes-dir'); m.add_argument('--whats-new', action='append')
    m.add_argument('--release', choices=['after-approval', 'manual'])
    g = m.add_mutually_exclusive_group(); g.add_argument('--phased', dest='phased', action='store_true', default=None)
    g.add_argument('--no-phased', dest='phased', action='store_false')
    m.add_argument('--review-notes'); m.add_argument('--dry-run', action='store_true')
    a = p.parse_args()
    (cmd_status if a.cmd == 'status' else cmd_submit)(a)


if __name__ == '__main__':
    main()
