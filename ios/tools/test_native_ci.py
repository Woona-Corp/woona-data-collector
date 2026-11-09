"""Hermetic native orchestration policy/schema tests; no simulator claims."""
import copy
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import native_ci as ci


def fixture(identifier='ExampleTests/testExample()', status='Passed'):
    # Modern xcresulttool tests schema: target on bundle, class/method on case.
    return {'testNodes': [{'name': 'WoonaTests', 'nodeType': 'Unit test bundle',
                          'children': [{'nodeType': 'Test Suite', 'name': 'ExampleTests',
                                        'children': [{'nodeType': 'Test Case',
                                                      'nodeIdentifier': identifier,
                                                      'result': status,
                                                      'durationInSeconds': 0.125}]}]}]}


class NativeCITests(unittest.TestCase):
    def test_current_source_inventory_and_exact_audited_shards(self):
        items = ci.inventory()
        self.assertGreater(len([i for i in items if i.startswith('WoonaTests/')]), 0)
        self.assertIn('WoonaTests/BleControlWriteQueueTests/testQueueBoundsFourFramesAndDisconnectFailsEveryPendingCommandOnce', items)
        self.assertIn('WoonaTests/V2PreviewTests/testCoarseningKeepsEndpointsAndPropagatesSegmentBreaks', items)
        self.assertEqual(18, len([i for i in items if i.startswith('WoonaUITests/')]))
        self.assertEqual([9, 9], [len(s) for s in ci.SHARDS])
        self.assertEqual(18, len(set(sum(ci.SHARDS, ()))))

    def test_added_or_duplicated_ui_case_is_not_silently_omitted(self):
        for shards in ((ci.SHARDS[0][:-1], ci.SHARDS[1]),
                       (ci.SHARDS[0] + (ci.SHARDS[0][0],), ci.SHARDS[1])):
            with patch.object(ci, 'SHARDS', shards), self.assertRaises(ValueError):
                ci.inventory()

    def test_modern_result_schema_target_context_and_full_id(self):
        rows = ci.result_rows(fixture())
        self.assertEqual('WoonaTests/ExampleTests/testExample', rows[0]['id'])
        self.assertEqual(0.125, rows[0]['durationInSeconds'])
        ci.require_pass(rows, ['WoonaTests/ExampleTests/testExample'])
        self.assertEqual(rows, ci.result_rows(fixture('WoonaTests/ExampleTests/testExample()')))

    def test_unknown_empty_legacy_or_malformed_schema_fails_closed(self):
        for tree in ({}, {'_type': {'_name': 'ActionsInvocationRecord'}},
                     fixture('0'), fixture('testExample()')):
            with self.subTest(tree=tree), self.assertRaises(ValueError):
                ci.result_rows(tree)

    def test_missing_duplicate_failed_skipped_expected_failure_are_not_proof(self):
        rows = ci.result_rows(fixture())
        expected = [rows[0]['id']]
        for bad in ([], rows + rows, ci.result_rows(fixture(status='Failed')),
                    ci.result_rows(fixture(status='Skipped')),
                    ci.result_rows(fixture(status='Expected Failure'))):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                ci.require_pass(bad, expected)

    def test_passed_parent_cannot_hide_retries_or_multiple_devices(self):
        for children in ([{'nodeType': 'Repetition', 'result': 'Passed'}],
                         [{'nodeType': 'Test Case Run', 'result': 'Failed'}],
                         [{'nodeType': 'Test Case Run', 'result': 'Passed'}] * 2):
            tree = fixture()
            tree['testNodes'][0]['children'][0]['children'][0]['children'] = children
            with self.assertRaises(ValueError):
                ci.result_rows(tree)

    def test_serial_test_without_building_and_bounded_boot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'simulator').write_text('device-id')
            products = root / 'Derived/Build/Products'
            products.mkdir(parents=True)
            (products / 'Woona.xctestrun').write_text('fixture')
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'DERIVED', root / 'Derived'), \
                    patch.object(ci, 'call') as call, patch.object(ci, 'collect'):
                ci.test('ui-1', ['WoonaUITests/OverviewParityTests/testExample'])
            boot, test = call.call_args_list
            self.assertEqual(180, boot.kwargs['timeout'])
            args = test.args[0]
            self.assertIn('test-without-building', args)
            self.assertNotIn('build-for-testing', args)
            self.assertEqual('NO', args[args.index('-parallel-testing-enabled') + 1])
            self.assertEqual('1', args[args.index('-maximum-concurrent-test-simulator-destinations') + 1])
            self.assertIn('-only-testing:WoonaUITests/OverviewParityTests/testExample', args)

    def test_failed_xcode_still_collects_results_and_does_not_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'simulator').write_text('device-id')
            (root / 'Build/Products').mkdir(parents=True)
            (root / 'Build/Products/run.xctestrun').touch()
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'DERIVED', root), \
                    patch.object(ci, 'call', side_effect=[None, subprocess.CalledProcessError(65, 'xcodebuild')]) as call, \
                    patch.object(ci, 'collect') as collect, self.assertRaises(subprocess.CalledProcessError):
                ci.test('unit', ['WoonaTests'])
            self.assertEqual(2, call.call_count)
            collect.assert_called_once_with('unit')

    def test_tar_transfer_really_preserves_executable_and_symlink_on_linux(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, restored = root / 'source', root / 'restored'
            source.mkdir()
            restored.mkdir()
            (source / 'runner').write_text('unsigned fixture')
            (source / 'runner').chmod(0o755)
            (source / 'link').symlink_to('runner')
            ci.call(['tar', '-cf', str(root / 'products.tar'), '-C', str(source), '.'])
            ci.call(['tar', '-xf', str(root / 'products.tar'), '-C', str(restored)])
            self.assertEqual(0o755, (restored / 'runner').stat().st_mode & 0o777)
            self.assertTrue((restored / 'link').is_symlink())
            self.assertEqual('unsigned fixture', (restored / 'link').read_text())

    def test_pinned_prepare_rejects_toolchain_and_missing_model(self):
        good = {'xcode': 'Xcode 26.6\nBuild version reviewed', 'sdk': '26.5',
                'architecture': 'arm64', 'model': 'iPhone 17 Pro'}
        devices = {'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [
            {'name': 'iPhone 17 Pro', 'udid': 'reviewed-device', 'isAvailable': True}]}}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'identity', return_value=good), \
                    patch.object(ci, 'inventory', return_value=['fixture']), \
                    patch.object(ci, 'output', side_effect=[json.dumps(devices), '{"devices": {}}']), \
                    patch.object(ci, 'call') as call:
                ci.prepare()
                self.assertEqual('reviewed-device', (root / 'simulator').read_text())
                call.assert_called_once_with(['xcrun', 'simctl', 'boot', 'reviewed-device'], timeout=180)
            for changed in ({**good, 'sdk': '26.6'}, {**good, 'architecture': 'x86_64'},
                            {**good, 'xcode': 'Xcode 26.7\nBuild version newer'}):
                with patch.object(ci, 'ROOT', root), patch.object(ci, 'identity', return_value=changed), \
                        self.assertRaises(ValueError):
                    ci.prepare()
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'identity', return_value=good), \
                    patch.object(ci, 'output', return_value='{"devices": {}}'), self.assertRaises(ValueError):
                ci.prepare()

    def test_products_verifier_rejects_hash_and_source_tampering_before_extract(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'products.tar').write_bytes(b'tar fixture')
            for manifest in ({'identity': {'source': 'other'}, 'sha256': ci.digest(root / 'products.tar')},
                             {'identity': {'source': 'current'}, 'sha256': 'wrong'}):
                ci.write(root / 'products-manifest.json', manifest)
                with patch.object(ci, 'ROOT', root), \
                        patch.object(ci, 'identity', return_value={'source': 'current'}), \
                        patch('sys.argv', ['native_ci.py', 'verify']), \
                        patch.object(ci, 'call') as call, self.assertRaises(ValueError):
                    ci.main()
                call.assert_not_called()

    def test_tree_digest_detects_contents_and_symlink_target_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'binary').write_text('one')
            before = ci.tree_digest(root)
            (root / 'binary').write_text('two')
            self.assertNotEqual(before, ci.tree_digest(root))
            (root / 'link').symlink_to('binary')
            before = ci.tree_digest(root)
            (root / 'link').unlink()
            (root / 'link').symlink_to('other')
            self.assertNotEqual(before, ci.tree_digest(root))

    def test_distribution_checks_proof_and_tag_before_any_signing_assets(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / '.github/workflows/testflight.yml').read_text()
        signing = workflow.index('- name: Install distribution signing assets')
        self.assertLess(workflow.index('- name: Verify exact full native proof'), signing)
        self.assertLess(workflow.index('- name: Verify tag and Release marketing version'), signing)
        self.assertIn("proof['mode'] == 'full' and proof['fullproof'] is True", workflow)
        self.assertIn("proof['zip64_large'] is True", workflow)
        self.assertIn("tag[5:].split('-', 1)[0] == version", workflow)
        self.assertIn('default: false', workflow)
        self.assertIn('uses: ./.github/workflows/ios-native.yml', workflow)
        self.assertIn('cancel-in-progress: false\n  queue: max', workflow)
        self.assertNotIn('--clobber', workflow)

    def test_aggregate_exact_union_and_run_identity(self):
        identities = {'source': 'sha', 'run': 'run', 'attempt': '1', 'inputs_sha256': 'inputs'}
        tests = ['WoonaTests/ExampleTests/testExample', 'WoonaUITests/OverviewParityTests/testA',
                 'WoonaUITests/OverviewParityTests/testB']
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for label, identity in zip(('unit', 'ui-1', 'ui-2'), tests, strict=True):
                ci.write(root / f'{label}.json', {'identity': identities, 'xcresult_sha256': label,
                         'tests': [{'id': identity, 'status': 'Passed'}]})
            ci.write(root / 'export-proof.json', identities)
            ci.write(root / 'archive-proof.json', {'identity': identities, 'zip64_large': True})
            with patch.object(ci, 'inventory', return_value=tests), \
                    patch.object(ci, 'input_digest', return_value='inputs'), \
                    patch.dict(ci.os.environ, {'GITHUB_SHA': 'sha', 'GITHUB_RUN_ID': 'run', 'GITHUB_RUN_ATTEMPT': '1'}):
                ci.aggregate(root, 'full')
                proof = json.loads((root / 'native-proof.json').read_text())
                self.assertTrue(proof['fullproof'])
                self.assertTrue(proof['zip64_large'])
                bad = copy.deepcopy(json.loads((root / 'ui-2.json').read_text()))
                bad['identity']['source'] = 'other'
                ci.write(root / 'ui-2.json', bad)
                with self.assertRaises(ValueError):
                    ci.aggregate(root, 'full')


if __name__ == '__main__':
    unittest.main()
