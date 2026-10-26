import unittest
from server.identity_review import build_review


class IdentityReviewTest(unittest.TestCase):
    def test_mixed_profile_history_maps_recordings_without_assigning_new_owners(self):
        dogs = [{'id': 'shared', 'number_or_name': 'Мартин', 'account_id': None},
                {'id': 'candidate', 'number_or_name': 'Кася', 'account_id': 'another'}]
        versions = [{'id': 'v1', 'dog_id': 'shared', 'animal_id': 'Кася', 'name_at_version': 'Кася'},
                    {'id': 'v2', 'dog_id': 'shared', 'animal_id': 'Мартин', 'name_at_version': 'Мартин'}]
        report = build_review(dogs, versions, [{'id': 'r1', 'dog_profile_version_id': 'v1'}],
                              [{'dog_id': 'shared', 'external_id': 'кася'}])
        self.assertFalse(report['apply_supported'])
        group = report['review_groups'][0]
        self.assertTrue(group['requires_operator_confirmation'])
        kasya = next(x for x in group['identities'] if x['animal_id'] == 'кася')
        self.assertEqual(kasya['recording_ids'], ['r1'])
        self.assertEqual(kasya['same_name_candidates_for_review_only'], ['candidate'])
        self.assertIsNone(group['account_id'])
        self.assertEqual(dogs[0]['id'], 'shared')

    def test_case_and_whitespace_changes_are_not_treated_as_different_animals(self):
        versions = [{'id': str(i), 'dog_id': 'one', 'animal_id': value, 'name_at_version': 'Кася'}
                    for i, value in enumerate([' Кася ', 'кася', 'КАСЯ'])]
        report = build_review([{'id': 'one', 'number_or_name': 'Кася'}], versions, [], [])
        self.assertEqual(report['review_groups'], [])
