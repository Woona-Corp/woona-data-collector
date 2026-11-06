"""Source-only no-backup policy checks. Never invoke backup or transfer."""
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

APP = Path(__file__).resolve().parent.parent / 'app' / 'src' / 'main'
ANDROID = '{http://schemas.android.com/apk/res/android}'
DOMAINS = {'root', 'file', 'database', 'sharedpref', 'external',
           'device_root', 'device_file', 'device_database', 'device_sharedpref'}


class BackupPolicyTest(unittest.TestCase):
    def assert_all_domains_excluded(self, rules):
        self.assertIsNotNone(rules)
        self.assertEqual(rules.findall('include'), [])
        self.assertEqual({rule.attrib['domain'] for rule in rules.findall('exclude')
                          if rule.attrib.get('path') == '.'}, DOMAINS)

    def test_manifest_disables_backup_without_a_custom_backup_agent(self):
        application = ET.parse(APP / 'AndroidManifest.xml').getroot().find('application')
        assert application is not None
        self.assertEqual(application.attrib.get(ANDROID + 'allowBackup'), 'false')
        self.assertNotIn(ANDROID + 'backupAgent', application.attrib)
        self.assertEqual(application.attrib[ANDROID + 'fullBackupContent'], '@xml/backup_rules')
        self.assertEqual(application.attrib[ANDROID + 'dataExtractionRules'], '@xml/data_extraction_rules')

    def test_legacy_backup_excludes_every_app_storage_domain(self):
        self.assert_all_domains_excluded(ET.parse(APP / 'res/xml/backup_rules.xml').getroot())

    def test_cloud_and_device_transfer_exclude_every_app_storage_domain(self):
        rules = ET.parse(APP / 'res/xml/data_extraction_rules.xml').getroot()
        for mode in ['cloud-backup', 'device-transfer']:
            with self.subTest(mode=mode):
                self.assert_all_domains_excluded(rules.find(mode))
        # There is no configured cross-platform transfer enrollment.
        self.assertEqual(rules.findall('cross-platform-transfer'), [])


if __name__ == '__main__':
    unittest.main()
