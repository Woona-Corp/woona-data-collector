"""Read App Store Connect build processing and tester-group status. Never writes to Apple."""
import base64
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from urllib.error import HTTPError


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


def jose_signature(der):
    if len(der) < 6 or der[0] != 48 or der[1] != len(der) - 2:
        raise ValueError('Invalid ES256 signature sequence')
    parts = []
    pos = 2
    for _ in range(2):
        if pos + 2 > len(der) or der[pos] != 2:
            raise ValueError('Invalid ES256 signature integer')
        length = der[pos + 1]
        value = der[pos + 2:pos + 2 + length]
        if len(value) != length or not value or value[0] & 128:
            raise ValueError('Invalid ES256 signature integer value')
        value = value.lstrip(b'\0')
        if len(value) > 32:
            raise ValueError('Invalid ES256 component size')
        parts.append(value.rjust(32, b'\0'))
        pos += 2 + length
    if pos != len(der):
        raise ValueError('Trailing ES256 signature data')
    return b''.join(parts)


def token(key_path, key_id, issuer, now=None):
    now = int(time.time()) if now is None else now
    header = b64(json.dumps({'alg': 'ES256', 'kid': key_id, 'typ': 'JWT'}).encode())
    payload = b64(json.dumps({'iss': issuer, 'iat': now, 'exp': now + 600, 'aud': 'appstoreconnect-v1'}).encode())
    signing = (header + '.' + payload).encode()
    signed = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(key_path)],
        input=signing, capture_output=True, check=True).stdout
    return signing.decode() + '.' + b64(jose_signature(signed))


def main():
    version = os.environ['CHECK_VERSION']
    build_number = os.environ['CHECK_BUILD']
    with tempfile.TemporaryDirectory() as directory:
        key = Path(directory) / 'key.p8'
        key.write_text(os.environ['ASC_PRIVATE_KEY'])
        key.chmod(0o600)
        def get(path, query=None):
            url = 'https://api.appstoreconnect.apple.com' + path
            if query:
                url += '?' + urlencode(query)
            request = Request(url, headers={'Authorization': 'Bearer ' + token(key, os.environ['ASC_KEY_ID'], os.environ['ASC_ISSUER_ID'])})
            with urlopen(request, timeout=30) as response:
                return json.load(response)
        apps = get('/v1/apps', {'filter[bundleId]': 'com.woona.apps'})['data']
        if len(apps) != 1:
            raise RuntimeError('Expected one Woona app')
        available_groups = []
        for group in get('/v1/apps/' + apps[0]['id'] + '/betaGroups', {'limit': 200})['data']:
            attributes = group['attributes']
            testers = get('/v1/betaGroups/' + group['id'] + '/betaTesters', {'limit': 200})
            available_groups.append({'id': group['id'], 'name': attributes.get('name'),
                'is_internal': attributes.get('isInternalGroup'),
                'tester_count': testers.get('meta', {}).get('paging', {}).get('total', len(testers['data']))})
        for attempt in range(45):
            result = get('/v1/builds', {'filter[app]': apps[0]['id'], 'filter[version]': build_number,
                'filter[preReleaseVersion.version]': version, 'include': 'buildBetaDetail,betaGroups,preReleaseVersion'})
            if result['data']:
                if len(result['data']) != 1:
                    raise RuntimeError('Build filter is ambiguous')
                build = result['data'][0]
                attrs = build['attributes']
                included = {item['type'] + ':' + item['id']: item for item in result.get('included', [])}
                detail_ref = build.get('relationships', {}).get('buildBetaDetail', {}).get('data')
                detail = included.get('buildBetaDetails:' + detail_ref['id'], {}).get('attributes', {}) if detail_ref else {}
                group_refs = build.get('relationships', {}).get('betaGroups', {}).get('data', [])
                groups = []
                for ref in group_refs:
                    group = included.get('betaGroups:' + ref['id'], {}).get('attributes', {})
                    groups.append({'id': ref['id'], 'name': group.get('name'), 'isInternalGroup': group.get('isInternalGroup')})
                report = {'version': version, 'build_number': build_number, 'build_id': build['id'],
                    'processing_state': attrs.get('processingState'), 'expired': attrs.get('expired'),
                    'internal_build_state': detail.get('internalBuildState'),
                    'external_build_state': detail.get('externalBuildState'), 'groups': groups,
                    'available_groups': available_groups, 'physical_installation_verified': False}
                print(json.dumps(report), flush=True)
                if attrs.get('processingState') == 'VALID':
                    Path('testflight-status.json').write_text(json.dumps(report, indent=2) + '\n')
                    return
                if attrs.get('processingState') in ('FAILED', 'INVALID'):
                    raise RuntimeError('Apple processing failed')
            else:
                print('Build not listed yet', flush=True)
            time.sleep(20)
        raise TimeoutError('Apple processing did not finish within this check')


if __name__ == '__main__':
    try:
        main()
    except HTTPError as error:
        raise SystemExit('App Store Connect HTTP ' + str(error.code)) from None
