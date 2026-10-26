import unittest
import copy
import json
from unittest.mock import patch
from server.tests.tools.isolated_load_fuzz import PROJECT, SafetyError, inspect_guard, validate_target


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

    def test_service_labels_storage_and_database_must_all_be_isolated(self):
        def container(service):
            return {'Id': service, 'Image':'synthetic-image',
                'Config':{'Labels':{'com.docker.compose.project':PROJECT,
                                   'com.docker.compose.service':service}, 'Env':[]},
                'NetworkSettings':{'Networks':{PROJECT+'_default':{}}, 'Ports':{}}, 'Mounts':[]}
        api, db = container('api'), container('postgres')
        api['Config']['Env'] = ['WOONA_DEBUG_TOKEN=synthetic-token', 'WOONA_STORAGE_ROOT=/srv/woona',
            'DATABASE_URL=postgresql+psycopg://synthetic:synthetic@postgres:5432/synthetic']
        api['NetworkSettings']['Ports']['8080/tcp'] = [{'HostIp':'127.0.0.1','HostPort':'18088'}]
        api['Mounts'] = [{'Type':'bind','Destination':'/srv/woona',
                         'Source':'/opt/woona-incident-e2e-20261026/storage'}]
        db['Config']['Env'] = ['POSTGRES_DB=synthetic','POSTGRES_USER=synthetic','POSTGRES_PASSWORD=synthetic']
        db['Mounts'] = [{'Type':'volume','Name':PROJECT+'_postgres_data'}]
        def guard(containers):
            with patch.dict('os.environ', {'WOONA_ISOLATED_LOAD_TEST':'1'}), patch(
                'subprocess.check_output', side_effect=['api db',json.dumps(containers)]):
                return inspect_guard('http://127.0.0.1:18088', PROJECT, 'synthetic-token')
        self.assertTrue(guard([api,db])['guards_passed'])
        mutations = [
            lambda a,d: a['Config']['Env'].__setitem__(2,'DATABASE_URL=postgresql+psycopg://synthetic:synthetic@external.invalid:5432/synthetic'),
            lambda a,d: a['Mounts'][0].__setitem__('Source','/srv/woona'),
            lambda a,d: d['Mounts'][0].__setitem__('Name','shared_postgres_data'),
            lambda a,d: a['NetworkSettings'].__setitem__('Networks',{'shared_default':{}}),
            lambda a,d: a['NetworkSettings']['Ports']['8080/tcp'][0].__setitem__('HostIp','0.0.0.0'),
        ]
        for mutate in mutations:
            a,d = copy.deepcopy([api,db]);mutate(a,d)
            with self.assertRaises(SafetyError):guard([a,d])
