#!/usr/bin/env python3
"""Inspect installed provisioning profiles for manual (non-cloud) signing.

  profiles.py list [--team T]                       App Store profiles usable for manual signing
  profiles.py match --team T BUNDLE [BUNDLE ...]    print "bundle<TAB>profile name<TAB>cert sha1" per bundle; exit 1 if any is missing
  profiles.py plan --team T                         pick ONE signing identity and print "IDENTITY <sha1>" then
                                                    "PROFILE <bundle id> <build-setting key> <profile name>" for every
                                                    exact-bundle App Store profile that uses it (all targets, no scheme needed)
  profiles.py install FILE.mobileprovision ...      copy into Xcode's profile folders (by UUID) after checking them
"""
import datetime, fnmatch, glob, hashlib, os, plistlib, shutil, subprocess, sys

DIRS = [os.path.expanduser('~/Library/Developer/Xcode/UserData/Provisioning Profiles'),   # Xcode 16+
        os.path.expanduser('~/Library/MobileDevice/Provisioning Profiles')]               # older Xcode
KEYCHAIN = os.path.expanduser('~/Library/Keychains/ci.keychain-db')


def load(path):
    raw = subprocess.run(['security', 'cms', '-D', '-i', path], capture_output=True).stdout
    p = plistlib.loads(raw)
    e = p.get('Entitlements', {})
    p['_kind'] = 'development' if e.get('get-task-allow') else ('ad-hoc' if p.get('ProvisionedDevices') else
                  ('enterprise' if p.get('ProvisionsAllDevices') else 'app-store'))
    p['_appid'] = e.get('application-identifier', '')
    p['_certs'] = [hashlib.sha1(c).hexdigest().upper() for c in p.get('DeveloperCertificates', [])]
    p['_path'] = path
    return p


def keychain_identities():
    out = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning', KEYCHAIN], capture_output=True, text=True).stdout
    return {line.split()[1]: line.split('"')[1] for line in out.splitlines() if '"' in line}


def usable(team=None):
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    seen = {}
    for d in DIRS:
        for f in glob.glob(d + '/*.mobileprovision'):
            try:
                p = load(f)
            except Exception:
                continue
            if p['_kind'] != 'app-store' or p.get('IsXcodeManaged') or p['ExpirationDate'] < now:
                continue
            if team and team not in p.get('TeamIdentifier', []):
                continue
            seen.setdefault(p['UUID'], p)
    return list(seen.values())


def matches(p, team, bundle):
    prefix, _, pattern = p['_appid'].partition('.')
    return prefix == team and fnmatch.fnmatchcase(bundle, pattern)


def c99(s):
    """Xcode's :c99extidentifier: every non-identifier character becomes '_' (a leading digit is replaced too)."""
    out = ''.join(ch if (ch.isalnum() or ch == '_') else '_' for ch in s)
    return ('_' + out[1:]) if out[:1].isdigit() else out


def cmd_plan(args):
    team = args[args.index('--team') + 1]
    ids = keychain_identities()
    profs = [p for p in usable(team) if not p['_appid'].endswith('*')]
    # One identity for the whole archive: the keychain certificate referenced by the most profiles
    # (during a certificate rotation, profiles may point at different certificates).
    counts = {}
    for p in profs:
        for c in p['_certs']:
            if c in ids:
                counts[c] = counts.get(c, 0) + 1
    if not counts:
        print(f"::error::No App Store profile for team {team} matches a Distribution identity in ci.keychain "
              "(ci-signing-setup.sh p12 … / profile …)", file=sys.stderr)
        sys.exit(1)
    cert = max(counts, key=counts.get)
    print(f'IDENTITY {cert} {ids[cert]}')
    best = {}
    for p in profs:
        if cert not in p['_certs']:
            continue
        b = p['_appid'].split('.', 1)[1]
        if b not in best or p['ExpirationDate'] > best[b]['ExpirationDate']:
            best[b] = p
    for b, p in sorted(best.items()):
        days = (p['ExpirationDate'] - datetime.datetime.utcnow()).days
        if days < 30:
            print(f'::warning::Profile "{p["Name"]}" for {b} expires in {days} days', file=sys.stderr)
        print(f'PROFILE {b} {c99(b)} {p["Name"]}')


def cmd_list(args):
    team = args[args.index('--team') + 1] if '--team' in args else None
    ids = keychain_identities()
    for p in sorted(usable(team), key=lambda p: p['_appid']):
        cert = next((c for c in p['_certs'] if c in ids), None)
        days = (p['ExpirationDate'] - datetime.datetime.utcnow()).days
        print(f"{p['_appid']:50} {p['Name']:40} expires in {days:3}d  cert {'✓ ' + ids[cert] if cert else '✗ not in ci.keychain'}")


def cmd_match(args):
    team = args[args.index('--team') + 1]
    bundles = [a for a in args if a not in ('--team', team)]
    ids = keychain_identities()
    profs = usable(team)
    missing = []
    for b in bundles:
        cands = [p for p in profs if matches(p, team, b) and any(c in ids for c in p['_certs'])]
        # exact bundle ID beats a wildcard; then the one that expires last
        cands.sort(key=lambda p: (p['_appid'].endswith('*'), -p['ExpirationDate'].timestamp()))
        if not cands:
            missing.append(b); continue
        p = cands[0]
        days = (p['ExpirationDate'] - datetime.datetime.utcnow()).days
        if days < 30:
            print(f'::warning::Profile "{p["Name"]}" for {b} expires in {days} days', file=sys.stderr)
        print(f"{b}\t{p['Name']}\t{next(c for c in p['_certs'] if c in ids)}")
    if missing:
        print(f"::error::No usable App Store profile (team {team}, certificate in ci.keychain, not expired) for: {', '.join(missing)}. "
              "Install one with scripts/ci-signing-setup.sh profile <file.mobileprovision>", file=sys.stderr)
        sys.exit(1)


def cmd_install(files):
    ids = keychain_identities()
    for f in files:
        p = load(f)
        if p['_kind'] != 'app-store':
            sys.exit(f'✗ {f}: {p["_kind"]} profile — manual signing for TestFlight/App Store needs an App Store profile')
        if p['ExpirationDate'] < datetime.datetime.utcnow():
            sys.exit(f'✗ {f}: expired on {p["ExpirationDate"]:%Y-%m-%d}')
        cert = next((c for c in p['_certs'] if c in ids), None)
        for d in DIRS:
            os.makedirs(d, exist_ok=True)
            shutil.copy(f, os.path.join(d, p['UUID'] + '.mobileprovision'))
        print(f"✓ {p['Name']} ({p['_appid']}, expires {p['ExpirationDate']:%Y-%m-%d})"
              + ('' if cert else "  ⚠️ its certificate is not in ci.keychain yet — run: ci-signing-setup.sh p12 <file.p12>"))


if __name__ == '__main__':
    cmd, rest = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ('', [])
    {'list': cmd_list, 'match': cmd_match, 'plan': cmd_plan, 'install': cmd_install}.get(cmd, lambda _: sys.exit(__doc__))(rest)
