import hashlib
import json
import unittest
import uuid

from sqlalchemy import text
from server.app import engine, canonical_json
from server.tests.test_api import request, expect_http, profile_payload


class DeletionsTest(unittest.TestCase):
    def test_hashed_retirement_blocks_recreation_and_hides_identity(self):
        identity = str(uuid.uuid4())
        digest = hashlib.sha256(identity.encode()).hexdigest()
        with engine.begin() as connection:
            connection.execute(text("INSERT INTO retired_entities(kind,id_sha256) VALUES('dog',:hash)"), {"hash":digest})
        try:
            expect_http(401, 'GET', '/v1/deletions', token='wrong')
            _,_,body=request('GET','/v1/deletions')
            self.assertNotIn(identity,body.decode())
            self.assertIn({'kind':'dog','id_sha256':digest},json.loads(body)['entities'])
            payload=profile_payload('Retired',profile_id=str(uuid.uuid4()))
            payload['dog']['id']=identity
            error=expect_http(410,'PUT',f"/v1/dogs/{identity}/profile-versions/{payload['profileVersion']['id']}",payload)
            self.assertEqual(error['code'],'entity_retired')
            with engine.connect() as connection:
                self.assertEqual(connection.execute(text('SELECT count(*) FROM dogs WHERE id=:id'),{'id':identity}).scalar_one(),0)
        finally:
            with engine.begin() as connection:
                connection.execute(text("DELETE FROM retired_entities WHERE kind='dog' AND id_sha256=:hash"),{'hash':digest})

    def test_marker_pages_are_bounded_complete_and_reject_bad_cursors(self):
        markers = [('dog', hashlib.sha256(f'page-{index}'.encode()).hexdigest()) for index in range(7)]
        with engine.begin() as connection:
            for kind, digest in markers:
                connection.execute(text('INSERT INTO retired_entities(kind,id_sha256) VALUES(:kind,:hash)'),
                                   {'kind': kind, 'hash': digest})
        try:
            seen, cursor, pages = [], None, 0
            while True:
                query = 'GET', f'/v1/deletions?limit=3' + (f'&cursor={cursor}' if cursor else '')
                _, _, body = request(*query)
                page = json.loads(body)
                self.assertEqual(3, page['limit'])
                self.assertLessEqual(len(page['entities']), 3)
                seen += [(item['kind'], item['id_sha256']) for item in page['entities']]
                cursor, pages = page['nextCursor'], pages + 1
                if cursor is None:
                    break
                self.assertLess(pages, 200, 'pagination must terminate')
            self.assertEqual(len(seen), len(set(seen)), 'pages must not repeat markers')
            self.assertEqual(sorted(markers), sorted(marker for marker in seen if marker in markers))
            for bad in ('dog:not-a-hash', 'unknown:' + 'a' * 64, 'dog', 'dog:' + 'A' * 64):
                self.assertEqual('invalid_deletion_cursor', expect_http(422, 'GET', f'/v1/deletions?cursor={bad}')['code'])
            for bad_limit in (0, -1, 5001):
                self.assertEqual('invalid_deletion_limit', expect_http(422, 'GET', f'/v1/deletions?limit={bad_limit}')['code'])
        finally:
            with engine.begin() as connection:
                for kind, digest in markers:
                    connection.execute(text('DELETE FROM retired_entities WHERE kind=:kind AND id_sha256=:hash'),
                                       {'kind': kind, 'hash': digest})

    def test_server_returns_its_canonical_questionnaire_hash(self):
        identity=str(uuid.uuid4()); payload=profile_payload('Canonical',profile_id=str(uuid.uuid4()))
        payload['dog']['id']=identity;payload['profileVersion']['contentSha256']='0'*64
        _,_,body=request('PUT',f"/v1/dogs/{identity}/profile-versions/{payload['profileVersion']['id']}",payload)
        accepted=json.loads(body)['profileVersion']
        self.assertEqual(accepted['questionnaire'],payload['profileVersion']['questionnaire'])
        self.assertEqual(accepted['contentSha256'],hashlib.sha256(canonical_json(accepted['questionnaire'])).hexdigest())
