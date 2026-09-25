#!/usr/bin/env python3
# Usage: scripts/asc.py GET "/v1/apps?filter[bundleId]=com.example.app"   (key from ~/.appstoreconnect/ci.env)
# Minimal App Store Connect API client: ES256 JWT via openssl (no third-party modules).
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error
env = dict(l.strip().split('=', 1) for l in open(os.path.expanduser('~/.appstoreconnect/ci.env')) if '=' in l)
KID, ISS = env['ASC_KEY_ID'], env['ASC_ISSUER_ID']
KEY = os.path.expanduser(f'~/.appstoreconnect/private_keys/AuthKey_{KID}.p8')
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def token():
    h = b64(json.dumps({'alg': 'ES256', 'kid': KID, 'typ': 'JWT'}).encode())
    now = int(time.time())
    p = b64(json.dumps({'iss': ISS, 'iat': now, 'exp': now + 1200, 'aud': 'appstoreconnect-v1'}).encode())
    der = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', KEY], input=f'{h}.{p}'.encode(), capture_output=True, check=True).stdout
    # DER ECDSA signature → raw r||s (32 bytes each)
    i = 2 + (1 if der[1] & 0x80 else 0)
    rl = der[i + 1]; r = der[i + 2:i + 2 + rl]; i = i + 2 + rl
    sl = der[i + 1]; s = der[i + 2:i + 2 + sl]
    raw = r[-32:].rjust(32, b'\0') + s[-32:].rjust(32, b'\0')
    return f'{h}.{p}.{b64(raw)}'
def call(method, path, body=None):
    url = path if path.startswith('http') else 'https://api.appstoreconnect.apple.com' + path
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={'Authorization': 'Bearer ' + token(), 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            t = r.read(); return json.loads(t) if t else {}
    except urllib.error.HTTPError as e:
        print(f'HTTP {e.code}: {e.read().decode()[:1500]}', file=sys.stderr); sys.exit(1)
if __name__ == '__main__':
    method, path = sys.argv[1], sys.argv[2]
    body = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    print(json.dumps(call(method, path, body), ensure_ascii=False, indent=1))
