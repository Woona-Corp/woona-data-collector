"""Distribute one explicitly selected VALID build to existing Woona groups.
Default is a read-only preview. Does not create testers or edit review contacts.
"""
import json
import os
import tempfile
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from check_testflight_status import token


def main():
    report = json.loads(Path('testflight-status.json').read_text())
    assert report['processing_state'] == 'VALID' and not report['expired']
    assert report['version'] == os.environ['CHECK_VERSION']
    assert report['build_number'] == os.environ['CHECK_BUILD']
    apply = os.environ.get('DISTRIBUTE', 'false') == 'true'
    with tempfile.TemporaryDirectory() as directory:
        key = Path(directory) / 'key.p8'
        key.write_text(os.environ['ASC_PRIVATE_KEY'])
        key.chmod(0o600)
        def request(path, method='GET', data=None):
            req = Request('https://api.appstoreconnect.apple.com' + path, method=method,
                data=json.dumps(data).encode() if data is not None else None,
                headers={'Authorization': 'Bearer ' + token(key, os.environ['ASC_KEY_ID'], os.environ['ASC_ISSUER_ID']),
                         'Content-Type': 'application/json'})
            with urlopen(req, timeout=30) as response:
                body = response.read()
                return json.loads(body) if body else {}
        app = request('/v1/builds/' + report['build_id'] + '/app')['data']
        localizations = request('/v1/apps/' + app['id'] + '/betaAppLocalizations')['data']
        descriptions = [{'locale': item['attributes'].get('locale'),
                         'has_description': bool(item['attributes'].get('description', '').strip())}
                        for item in localizations]
        groups = report['available_groups']
        expected = {'Internal Testing', 'External Testing'}
        selected = [group for group in groups if group['name'] in expected]
        if {group['name'] for group in selected} != expected:
            raise RuntimeError('Expected existing internal/external Woona groups')
        preview = {'build_number': report['build_number'], 'apply': apply,
                   'groups': selected, 'app_descriptions': descriptions}
        print(json.dumps(preview), flush=True)
        Path('testflight-distribution.json').write_text(json.dumps(preview, indent=2) + '\n')
        if not apply:
            return
        if not descriptions or not all(item['has_description'] for item in descriptions):
            raise RuntimeError('Existing beta app descriptions are incomplete; no metadata invented')
        build_id = report['build_id']
        notes = ('Account is now at the top of Overview. Dog selection and separate New dog / Edit actions '
                 'follow the Android workflow. Please check Edit immediately after launch, creating a new '
                 'dog without changing existing profiles, account selection, language, and fullscreen charts.')
        existing = request('/v1/builds/' + build_id + '/betaBuildLocalizations')['data']
        if not existing:
            request('/v1/betaBuildLocalizations', 'POST', {'data': {'type': 'betaBuildLocalizations',
                'attributes': {'locale': 'en-US', 'whatsNew': notes},
                'relationships': {'build': {'data': {'type': 'builds', 'id': build_id}}}}})
        assigned = {group['id'] for group in report['groups']}
        missing = [group for group in selected if group['id'] not in assigned]
        if missing:
            request('/v1/builds/' + build_id + '/relationships/betaGroups', 'POST',
                    {'data': [{'type': 'betaGroups', 'id': group['id']} for group in missing]})
        previous = request('/v1/betaAppReviewSubmissions?filter[build]=' + build_id)['data']
        submissions = previous[0] if previous else None
        if not submissions:
            submissions = request('/v1/betaAppReviewSubmissions', 'POST', {'data': {
                'type': 'betaAppReviewSubmissions',
                'relationships': {'build': {'data': {'type': 'builds', 'id': build_id}}}}})['data']
        preview['review_state'] = submissions['attributes']['betaReviewState']
        print(json.dumps(preview), flush=True)
        Path('testflight-distribution.json').write_text(json.dumps(preview, indent=2) + '\n')


if __name__ == '__main__':
    try:
        main()
    except HTTPError as error:
        body = json.loads(error.read())
        raise SystemExit(json.dumps({'http_status': error.code,
            'errors': [{'code': item.get('code'), 'title': item.get('title'), 'detail': item.get('detail')}
                       for item in body.get('errors', [])]})) from None
