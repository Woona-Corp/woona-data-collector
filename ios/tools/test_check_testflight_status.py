import hashlib
import json
import unittest
from check_testflight_status import target_group_match, target_access


class TesterAccessTest(unittest.TestCase):
    def test_exact_normalized_email_match_does_not_return_private_fields(self):
        digest = hashlib.sha256(b'tester@example.invalid').hexdigest()
        self.assertTrue(target_group_match({'data': [{'attributes': {'email': ' TESTER@example.invalid '}}]}, digest))
        report = target_access([{'id': 'internal', 'is_internal': True, 'target_match': True}], {'internal'})
        self.assertEqual(report, {'matched': True, 'internal': True, 'external': False, 'assignedBuild': True})
        self.assertNotIn('example.invalid', json.dumps(report))

    def test_external_member_cannot_claim_assignment_to_internal_build(self):
        report = target_access([{'id': 'internal', 'is_internal': True, 'target_match': False},
                                {'id': 'external', 'is_internal': False, 'target_match': True}], {'internal'})
        self.assertEqual(report, {'matched': True, 'internal': False, 'external': True, 'assignedBuild': False})

    def test_absent_member_is_not_reported_as_assigned(self):
        self.assertEqual(target_access([], {'internal'}),
                         {'matched': False, 'internal': False, 'external': False, 'assignedBuild': False})

    def test_hidden_email_or_incomplete_listing_cannot_prove_absence(self):
        target = '0' * 64
        for body in [{'data': [{'attributes': {'email': None}}]}, {'data': [], 'meta': {'paging': {'total': 1}}},
                     {'data': [], 'links': {'next': 'not-fetched'}}]:
            with self.assertRaises(RuntimeError):target_group_match(body, target)
        with self.assertRaises(ValueError):target_group_match({'data': []}, 'invalid')
