import unittest
from server.tests.tools.isolated_load_fuzz import PROJECT, SafetyError, validate_target


class IsolatedLoadSafetyTest(unittest.TestCase):
    def test_only_explicit_exact_loopback_project_is_allowed(self):
        self.assertEqual(validate_target('http://127.0.0.1:18088', PROJECT, '1').port, 18088)
        for base,project,enabled in [
            ('https://cool-trams.digital', PROJECT, '1'),
            ('http://127.0.0.1:8080', PROJECT, '1'),
            ('http://localhost:18088', PROJECT, '1'),
            ('http://127.0.0.1:18088@cool-trams.digital', PROJECT, '1'),
            ('http://127.0.0.1:18088/path', PROJECT, '1'),
            ('http://127.0.0.1:18088', 'shared', '1'),
            ('http://127.0.0.1:18088', PROJECT, ''),
        ]:
            with self.subTest(base=base,project=project,enabled=enabled):
                with self.assertRaises((SafetyError, ValueError)):
                    validate_target(base, project, enabled)
