#!/usr/bin/env python3
"""Prepare and submit an App Store version for review via the App Store Connect API.

  asc-release.py status --bundle-id com.example.app [--version 1.2.0]
  asc-release.py submit --bundle-id com.example.app --version 1.2.0 [options]

submit options:
  --build N|latest        build number to attach (default: latest VALID build of that version)
  --wait-build MIN        wait up to MIN minutes for the build to finish processing (default 0)
  --notes-dir DIR         read "What's New" from DIR/<locale>/release_notes.txt (fastlane deliver layout)
  --whats-new LOCALE=TEXT  set "What's New" for one locale (repeatable; wins over --notes-dir)
  --locales a,b,c         locales to fill (default: every locale the version already has — new versions
                          inherit the previous version's locales). A locale not on the version yet is added;
                          it then also needs description.txt and keywords.txt in --notes-dir/<locale>/
  --drop-unlisted         remove the version's locales that are not in --locales (deletes their description too)
  --release after-approval|manual   (default: keep current)
  --phased / --no-phased  7-day phased release on/off (default: keep current)
  --screenshots-dir DIR   replace screenshots from DIR/<locale>/*.png|jpg (fastlane layout, sorted by file name);
                          the device is detected from the pixel size, only the devices you provide are replaced
  --review-notes TEXT     notes for App Review
  --dry-run               show every step, change nothing

Uses the API key from ~/.appstoreconnect/ci.env (scripts/ci-signing-setup.sh asc). Needs the App Manager or Admin role.
"""
import argparse, hashlib, json, os, struct, sys, time, urllib.request
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


# Pixel size (portrait) → App Store Connect screenshot display type.
DISPLAY_TYPES = {
    (1320, 2868): 'APP_IPHONE_67', (1290, 2796): 'APP_IPHONE_67', (1284, 2778): 'APP_IPHONE_67',
    (1242, 2688): 'APP_IPHONE_65', (1206, 2622): 'APP_IPHONE_61', (1179, 2556): 'APP_IPHONE_61',
    (1170, 2532): 'APP_IPHONE_61', (1242, 2208): 'APP_IPHONE_55',
    (2064, 2752): 'APP_IPAD_PRO_3GEN_129', (2048, 2732): 'APP_IPAD_PRO_3GEN_129',
    (1668, 2388): 'APP_IPAD_PRO_3GEN_11', (1640, 2360): 'APP_IPAD_PRO_3GEN_11',
    (416, 496): 'APP_WATCH_SERIES_10', (410, 502): 'APP_WATCH_ULTRA', (396, 484): 'APP_WATCH_SERIES_7',
}


def image_size(path):
    with open(path, 'rb') as f:
        head = f.read(32)
        if head[:8] == b'\x89PNG\r\n\x1a\n':
            return struct.unpack('>II', head[16:24])
        f.seek(0); data = f.read()
    i = 2  # JPEG: walk the segments to the SOF marker
    while i < len(data):
        if data[i] != 0xFF: i += 1; continue
        marker = data[i + 1]
        if marker in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack('>HH', data[i + 5:i + 9]); return w, h
        i += 2 + struct.unpack('>H', data[i + 2:i + 4])[0]
    raise ValueError(f'unsupported image {path}')


def plan_screenshots(dirpath, locales):
    plan = {}  # locale -> display type -> [files]
    for loc in locales:
        d = os.path.join(dirpath, loc)
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.lower().endswith(('.png', '.jpg', '.jpeg')):
                continue
            path = os.path.join(d, fn); w, h = image_size(path)
            dt = DISPLAY_TYPES.get((min(w, h), max(w, h)))
            if not dt:
                fail(f'{path}: {w}×{h} is not an App Store screenshot size')
            plan.setdefault(loc, {}).setdefault(dt, []).append(path)
    for loc, types in plan.items():
        for dt, files in types.items():
            if len(files) > 10:
                fail(f'{loc} {dt}: {len(files)} screenshots, App Store allows at most 10')
    return plan


def upload_screenshot(set_id, path):
    data = open(path, 'rb').read()
    r = call('POST', '/v1/appScreenshots', {'data': {'type': 'appScreenshots',
             'attributes': {'fileName': os.path.basename(path), 'fileSize': len(data)},
             'relationships': {'appScreenshotSet': rel('appScreenshotSets', set_id)}}})['data']
    for op in r['attributes']['uploadOperations']:
        chunk = data[op['offset']:op['offset'] + op['length']]
        req = urllib.request.Request(op['url'], data=chunk, method=op['method'],
                                     headers={h['name']: h['value'] for h in op.get('requestHeaders', [])})
        urllib.request.urlopen(req, timeout=300).read()
    call('PATCH', f"/v1/appScreenshots/{r['id']}", {'data': {'type': 'appScreenshots', 'id': r['id'],
         'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})
    return r['id']


def replace_screenshots(loc_id, loc, types):
    sets = {s['attributes']['screenshotDisplayType']: s['id'] for s in
            call('GET', f'/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets')['data']}
    ids = []
    for dt, files in types.items():
        if DRY:
            step(f"[dry run] would replace {loc} {dt} with {len(files)} screenshots: {', '.join(os.path.basename(f) for f in files)}")
            continue
        sid = sets.get(dt) or call('POST', '/v1/appScreenshotSets', {'data': {'type': 'appScreenshotSets',
              'attributes': {'screenshotDisplayType': dt},
              'relationships': {'appStoreVersionLocalization': rel('appStoreVersionLocalizations', loc_id)}}})['data']['id']
        for old in call('GET', f'/v1/appScreenshotSets/{sid}/appScreenshots')['data']:
            call('DELETE', f"/v1/appScreenshots/{old['id']}")
        new = [upload_screenshot(sid, f) for f in files]
        call('PATCH', f'/v1/appScreenshotSets/{sid}/relationships/appScreenshots',
             {'data': [{'type': 'appScreenshots', 'id': i} for i in new]})
        step(f'Screenshots {loc} {dt}: {len(new)} uploaded')
        ids += new
    return ids


def wait_screenshots(ids, minutes=15):
    deadline = time.time() + minutes * 60
    while ids and time.time() < deadline:
        states = {i: call('GET', f'/v1/appScreenshots/{i}?fields[appScreenshots]=assetDeliveryState')['data']
                  ['attributes']['assetDeliveryState']['state'] for i in ids}
        bad = [i for i, st in states.items() if st == 'FAILED']
        if bad:
            fail(f'App Store Connect rejected {len(bad)} screenshot(s) — check sizes/format')
        if all(st == 'COMPLETE' for st in states.values()):
            step('Screenshots processed'); return
        time.sleep(10)
    if ids:
        fail('Screenshots are still processing — rerun the command in a few minutes')


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


def localizations(vid):
    return call('GET', f'/v1/appStoreVersions/{vid}/appStoreVersionLocalizations?limit=50'
                       '&fields[appStoreVersionLocalizations]=locale,whatsNew,description,keywords')['data']


def cmd_status(a):
    app, name = find_app(a.bundle_id)
    print(f'{name} ({a.bundle_id}) app id {app}')
    versions_list = versions(app)
    for v in versions_list:
        at = v['attributes']
        if a.version and at['versionString'] != a.version:
            continue
        b = call('GET', f"/v1/appStoreVersions/{v['id']}/build?fields[builds]=version").get('data')
        print(f"  {at['versionString']:10} {at['appStoreState']:26} release={at['releaseType']:15} build={b['attributes']['version'] if b else '-'}")
        if a.version or v is versions_list[0]:
            for l in localizations(v['id']):
                wn = (l['attributes']['whatsNew'] or '').strip()
                print(f"      {l['attributes']['locale']:8} What's New: {('✓ ' + wn.splitlines()[0][:50]) if wn else '(empty)'}")
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
    locs = localizations(vid) if vid != 'NEW' else []
    if vid == 'NEW':  # a new version inherits the latest version's locales
        prev = next((x for x in vs if x['id'] != vid), None)
        locs_for_plan = [l['attributes']['locale'] for l in localizations(prev['id'])] if prev else []
    else:
        locs_for_plan = [l['attributes']['locale'] for l in locs]
    wanted = [x.strip() for x in a.locales.split(',')] if a.locales else locs_for_plan
    step(f"Locales on the version: {', '.join(locs_for_plan) or '(none)'}; filling: {', '.join(wanted)}")
    first_release = not any(x['attributes']['appStoreState'] == 'READY_FOR_SALE' or x['attributes']['appStoreState'].startswith('REPLACED') for x in vs)
    missing = []
    by_loc = {l['attributes']['locale']: l for l in locs}
    for loc in wanted:
        text = notes.get(loc)
        if loc in by_loc:
            current = (by_loc[loc]['attributes']['whatsNew'] or '').strip()
            if text and text != current:
                step(f"What's New [{loc}]: updating ({len(text)} chars)")
                write('PATCH', f"/v1/appStoreVersionLocalizations/{by_loc[loc]['id']}", {'data': {'type': 'appStoreVersionLocalizations',
                      'id': by_loc[loc]['id'], 'attributes': {'whatsNew': text}}}, f"set What's New [{loc}]")
            elif current or text:
                step(f"What's New [{loc}]: ok (keeping the existing text)")
            elif not first_release:
                missing.append(loc)
        elif vid == 'NEW' and loc in locs_for_plan:
            if text:
                step(f"What's New [{loc}]: will be set on the new version")
            elif not first_release:
                missing.append(loc)
        else:  # a locale the version doesn't have yet
            d = os.path.join(a.notes_dir or '', loc)
            desc = os.path.join(d, 'description.txt'); kw = os.path.join(d, 'keywords.txt')
            if not (a.notes_dir and os.path.isfile(desc) and os.path.isfile(kw)):
                fail(f"Adding {loc} needs its description and keywords too: put description.txt and keywords.txt "
                     f"(and release_notes.txt) in {a.notes_dir or '<notes-dir>'}/{loc}/. The app name for {loc} is set on the website (App Information).")
            attrs = {'locale': loc, 'description': open(desc, encoding='utf-8').read().strip(),
                     'keywords': open(kw, encoding='utf-8').read().strip()}
            if text:
                attrs['whatsNew'] = text
            step(f'Adding locale {loc}')
            write('POST', '/v1/appStoreVersionLocalizations', {'data': {'type': 'appStoreVersionLocalizations', 'attributes': attrs,
                  'relationships': {'appStoreVersion': rel('appStoreVersions', vid)}}}, f'add locale {loc}')
    for loc in [x for x in locs_for_plan if x not in wanted]:
        if a.drop_unlisted:
            step(f'Removing locale {loc} from this version')
            if loc in by_loc:
                write('DELETE', f"/v1/appStoreVersionLocalizations/{by_loc[loc]['id']}", what=f'remove locale {loc}')
        elif not first_release and not ((by_loc.get(loc) or {}).get('attributes', {}).get('whatsNew') or '').strip():
            fail(f"{loc} is on the version but not in --locales and its What's New is empty. Fill it too, or pass --drop-unlisted to remove {loc} from this version.")
        else:
            step(f"What's New [{loc}]: not selected, keeping as is")
    for loc in set(notes) - set(wanted):
        step(f"⚠️ notes for {loc} ignored (not in --locales)")
    if missing:
        fail(f"What's New is empty for: {', '.join(missing)} (use --whats-new {missing[0]}=… or {a.notes_dir or 'fastlane/metadata'}/<locale>/release_notes.txt)")
    # 3b. Screenshots (only the devices provided are replaced; a new version already inherits the previous ones).
    if a.screenshots_dir:
        shots = plan_screenshots(a.screenshots_dir, wanted)
        if not shots:
            fail(f'No screenshots found under {a.screenshots_dir}/<locale>/ for {", ".join(wanted)}')
        if vid == 'NEW':
            for loc, types in shots.items():
                for dt, files in types.items():
                    step(f"[dry run] would replace {loc} {dt} with {len(files)} screenshots")
        else:
            by_loc_now = {l['attributes']['locale']: l['id'] for l in localizations(vid)}
            uploaded = []
            for loc, types in shots.items():
                uploaded += replace_screenshots(by_loc_now[loc], loc, types)
            if not DRY:
                wait_screenshots(uploaded)

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
    m.add_argument('--locales'); m.add_argument('--drop-unlisted', action='store_true')
    m.add_argument('--screenshots-dir')
    a = p.parse_args()
    (cmd_status if a.cmd == 'status' else cmd_submit)(a)


if __name__ == '__main__':
    main()
