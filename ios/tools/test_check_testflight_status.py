import hashlib
import json
import unittest
from check_testflight_status import tester_identities, target_access

TARGET = hashlib.sha256(b'tester@example.invalid').hexdigest()

def person(id, email=None, first=None, last=None):
    return {'id': id, 'attributes': {'email': email, 'firstName': first, 'lastName': last}}

def group(id, internal, people, name_hash=''):
    return {'id': id, 'is_internal': internal, '_identities': tester_identities({'data': people}, TARGET, name_hash)}

class TesterAccessTest(unittest.TestCase):
    def test_exact_normalized_email_and_same_id_join_without_email_in_internal_roster(self):
        rows = [group('internal', True, [person('target')]),
                group('external', False, [person('target', ' TESTER@example.invalid ')])]
        result = target_access(rows, {'internal'})
        self.assertTrue(all(result[k] for k in ['matched','internal','external','assignedBuild']))
        self.assertNotIn('example.invalid', json.dumps(result))

    def test_unknown_other_testers_do_not_hide_a_proven_external_identity(self):
        rows = [group('internal', True, [person('other')]),
                group('external', False, [person('target', 'tester@example.invalid'), person('anonymous')])]
        result = target_access(rows, {'internal'})
        self.assertTrue(result['matched']);self.assertFalse(result['internal']);self.assertTrue(result['external']);self.assertFalse(result['assignedBuild'])

    def test_multiple_target_ids_or_hidden_unidentified_target_remain_unknown(self):
        for people in [[person('anonymous')], [person('one', 'tester@example.invalid'), person('two', 'tester@example.invalid')]]:
            result = target_access([group('internal', True, people)], {'internal'})
            self.assertIsNone(result['matched']);self.assertIsNone(result['internal'])

    def test_unique_exact_name_digest_can_identify_an_email_hidden_target(self):
        digest = hashlib.sha256(b'synthetic person').hexdigest()
        result = target_access([group('internal', True, [person('target', first='Synthetic', last='Person')], digest)], {'internal'})
        self.assertTrue(result['matched']);self.assertTrue(result['internal']);self.assertEqual(result['identityEvidence'], 'unique_exact_name_digest')
        self.assertNotIn('Synthetic', json.dumps(result))

    def test_complete_visible_roster_can_prove_absence(self):
        result = target_access([group('internal', True, [person('other', 'other@example.invalid')])], {'internal'})
        self.assertFalse(result['matched']);self.assertFalse(result['assignedBuild'])

    def test_incomplete_listing_cannot_prove_absence(self):
        for body in [{'data': [], 'meta': {'paging': {'total': 1}}}, {'data': [], 'links': {'next': 'not-fetched'}}]:
            with self.assertRaises(RuntimeError):tester_identities(body, TARGET)
        with self.assertRaises(ValueError):tester_identities({'data': []}, 'invalid')
