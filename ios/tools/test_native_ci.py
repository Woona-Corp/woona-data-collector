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

    def test_ui_inventory_cannot_replace_missing_unit_suite(self):
        ui_files = list(Path('ios', 'WoonaUITests').rglob('*.swift'))
        with patch.object(ci.Path, 'rglob', side_effect=[[], ui_files]), self.assertRaises(ValueError):
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
        with self.assertRaises(ValueError):
            ci.require_pass([], [])

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

    def test_prepare_full_producer_never_boots_and_consumers_do(self):
        good = {'xcode': 'Xcode 26.6\nBuild version reviewed', 'sdk': '26.5',
                'architecture': 'arm64', 'model': 'iPhone 17 Pro'}
        devices = {'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [
            {'name': 'iPhone 17 Pro', 'udid': 'reviewed-device', 'isAvailable': True}]}}
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(ci, 'ROOT', Path(directory)), patch.object(ci, 'identity', return_value=good), \
                    patch.object(ci, 'inventory', return_value=['fixture']), \
                    patch.object(ci, 'output', return_value=json.dumps(devices)) as output, \
                    patch.object(ci, 'call') as call:
                ci.prepare(boot=False)
                call.assert_not_called()
                self.assertEqual(1, output.call_count)
            for mode, role, boot in (('full', 'producer', False), ('full', 'consumer', True),
                                     ('unit', 'producer', True), ('diagnostic', 'producer', True)):
                with self.subTest(mode=mode, role=role), patch.object(ci, 'ROOT', Path(directory)), \
                        patch.object(ci, 'prepare') as prepare, \
                        patch.dict(ci.os.environ, {'WOONA_CI_ROLE': role}), \
                        patch('sys.argv', ['native_ci.py', 'prepare', '--mode', mode]):
                    ci.main()
                    prepare.assert_called_once_with(boot=boot)

    def test_full_first_consumer_one_combined_invocation_and_export_check(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'test') as test, \
                    patch.object(ci, 'call') as call, patch.object(ci, 'identity', return_value={'source': 'sha'}), \
                    patch('sys.argv', ['native_ci.py', 'ui-1']):
                ci.main()
            test.assert_called_once_with('unit-ui-1', ['WoonaTests'] + [
                'WoonaUITests/OverviewParityTests/' + method for method in ci.SHARDS[0]])
            call.assert_called_once_with(['python3', 'ios/tools/check-recording-export.py',
                                          str(root / 'unit-ui-1-attachments')])
            self.assertEqual({'source': 'sha'}, json.loads((root / 'export-proof.json').read_text()))

    def test_second_consumer_has_only_nine_ui_methods_and_no_export_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'test') as test, \
                    patch.object(ci, 'call') as call, patch('sys.argv', ['native_ci.py', 'ui-2']):
                ci.main()
            test.assert_called_once_with('ui-2', [
                'WoonaUITests/OverviewParityTests/' + method for method in ci.SHARDS[1]])
            call.assert_not_called()
            self.assertFalse((root / 'export-proof.json').exists())

    def test_unit_and_focused_diagnostic_paths_remain_single_invocations(self):
        for mode, selector in (('unit', 'WoonaTests'), ('diagnostic',
                              'WoonaUITests/OverviewParityTests/testFiveTabsPreserveSelectionAndSeparateFunctions')):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                argv = ['native_ci.py', 'unit', '--mode', mode]
                if mode == 'diagnostic':
                    argv += ['--test-filter', selector]
                with patch.object(ci, 'ROOT', root), patch.object(ci, 'test') as test, \
                        patch.object(ci, 'call') as call, patch.object(ci, 'identity', return_value={'source': 'sha'}), \
                        patch('sys.argv', argv):
                    ci.main()
                test.assert_called_once_with('unit', [selector], 'none')
                self.assertEqual(mode == 'unit', (root / 'export-proof.json').exists())
                self.assertEqual(1 if mode == 'unit' else 0, call.call_count)

    def test_failed_combined_test_or_session_export_cannot_write_export_proof(self):
        for failed_operation in ('test', 'call'):
            with self.subTest(failed_operation=failed_operation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                error = subprocess.CalledProcessError(65, failed_operation)
                ci.write(root / 'export-proof.json', {'source': 'stale'})
                with patch.object(ci, 'ROOT', root), \
                        patch.object(ci, 'test', side_effect=error if failed_operation == 'test' else None) as test, \
                        patch.object(ci, 'call', side_effect=error if failed_operation == 'call' else None) as call, \
                        patch('sys.argv', ['native_ci.py', 'ui-1']), self.assertRaises(subprocess.CalledProcessError):
                    ci.main()
                test.assert_called_once()
                self.assertEqual(0 if failed_operation == 'test' else 1, call.call_count)
                self.assertFalse((root / 'export-proof.json').exists())

    def test_workflow_full_producer_has_no_test_or_boot_and_consumers_depend_on_it(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / '.github/workflows/ios-native.yml').read_text()
        producer, consumers = workflow.split('  ui:\n', 1)
        self.assertIn('WOONA_CI_ROLE: producer', producer)
        self.assertIn('prepare --mode "$MODE"', producer)
        self.assertIn("- name: Serial native units and independent session export proof\n        if: inputs.mode != 'full'", producer)
        self.assertEqual(1, workflow.count('native_ci.py archive'))
        self.assertEqual(1, workflow.count('native_ci.py build'))
        self.assertIn('needs: native-build-unit', consumers)
        self.assertIn('WOONA_CI_ROLE: consumer', consumers)
        self.assertIn('label: unit-ui-1', consumers)
        self.assertIn('label: ui-2', consumers)
        self.assertIn('"ui-$SHARD"', consumers)
        self.assertIn('ios-native-unit-ui-1-evidence', consumers)
        self.assertIn('retention-days: 1', producer)
        scheme = (root / 'ios/Woona.xcodeproj/xcshareddata/xcschemes/Woona.xcscheme').read_text()
        self.assertLess(scheme.index('BlueprintName = "WoonaTests"'), scheme.index('BlueprintName="WoonaUITests"'))

    def test_aggregate_combined_exact_union_rejects_incomplete_or_bad_proofs(self):
        identities = {'source': 'sha', 'run': 'run', 'attempt': '1', 'inputs_sha256': 'inputs'}
        expected = ci.inventory()
        units = [i for i in expected if i.startswith('WoonaTests/')]
        reports = {
            'unit-ui-1': units + ['WoonaUITests/OverviewParityTests/' + m for m in ci.SHARDS[0]],
            'ui-2': ['WoonaUITests/OverviewParityTests/' + m for m in ci.SHARDS[1]],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            valid = {label: {'identity': identities, 'xcresult_sha256': label,
                            'tests': [{'id': identity, 'status': 'Passed'} for identity in cases]}
                     for label, cases in reports.items()}
            def reset():
                for label, data in valid.items():
                    ci.write(root / f'{label}.json', data)
                ci.write(root / 'export-proof.json', identities)
                ci.write(root / 'archive-proof.json', {'identity': identities, 'zip64_large': True})
            with patch.object(ci, 'input_digest', return_value='inputs'), \
                    patch.dict(ci.os.environ, {'GITHUB_SHA': 'sha', 'GITHUB_RUN_ID': 'run', 'GITHUB_RUN_ATTEMPT': '1'}):
                reset()
                ci.aggregate(root, 'full')
                proof = json.loads((root / 'native-proof.json').read_text())
                self.assertTrue(proof['fullproof'])
                self.assertTrue(proof['zip64_large'])
                self.assertEqual(len(expected), len(proof['passed']))
                self.assertEqual(len(units), proof['counts']['unit']['executed'])
                self.assertEqual(18, proof['counts']['ui']['passed'])
                self.assertEqual({'unit-ui-1', 'ui-2'}, set(proof['result_hashes']))
                for bad_case in ('missing-unit', 'missing-ui1', 'missing-ui2', 'duplicate', 'unknown-unit',
                                 'unknown-ui', 'failed', 'skipped', 'expected-failure', 'wrong-source',
                                 'wrong-run', 'wrong-toolchain', 'wrong-shard', 'missing-export',
                                 'missing-archive', 'wrong-export-source', 'wrong-archive-source', 'missing-combined'):
                    with self.subTest(bad_case=bad_case):
                        reset()
                        # A prior successful proof must not survive failed verification.
                        ci.write(root / 'native-proof.json', {'fullproof': True})
                        label = 'ui-2' if bad_case == 'missing-ui2' else 'unit-ui-1'
                        data = copy.deepcopy(valid[label])
                        if bad_case == 'missing-unit' or bad_case == 'missing-ui2':
                            data['tests'].pop(0)
                        elif bad_case == 'missing-ui1':
                            data['tests'].pop()
                        elif bad_case == 'duplicate':
                            data['tests'].append(data['tests'][0])
                        elif bad_case.startswith('unknown-'):
                            target = 'WoonaTests' if bad_case == 'unknown-unit' else 'WoonaUITests'
                            data['tests'].append({'id': target + '/Unknown/testUnexpected', 'status': 'Passed'})
                        elif bad_case in ('failed', 'skipped', 'expected-failure'):
                            data['tests'][0]['status'] = {'failed': 'Failed', 'skipped': 'Skipped',
                                                        'expected-failure': 'Expected Failure'}[bad_case]
                        elif bad_case in ('wrong-source', 'wrong-run', 'wrong-toolchain'):
                            data['identity'][{'wrong-source': 'source', 'wrong-run': 'run',
                                              'wrong-toolchain': 'xcode'}[bad_case]] = 'other'
                        elif bad_case == 'wrong-shard':
                            other = copy.deepcopy(valid['ui-2'])
                            data['tests'][-1], other['tests'][0] = other['tests'][0], data['tests'][-1]
                            ci.write(root / 'ui-2.json', other)
                        ci.write(root / f'{label}.json', data)
                        if bad_case in ('missing-export', 'missing-archive', 'missing-combined'):
                            name = {'missing-export': 'export-proof', 'missing-archive': 'archive-proof',
                                    'missing-combined': 'unit-ui-1'}[bad_case]
                            (root / f'{name}.json').unlink()
                        elif bad_case == 'wrong-export-source':
                            ci.write(root / 'export-proof.json', {**identities, 'source': 'other'})
                        elif bad_case == 'wrong-archive-source':
                            ci.write(root / 'archive-proof.json', {'identity': {**identities, 'source': 'other'},
                                                                 'zip64_large': True})
                        with self.assertRaises((ValueError, FileNotFoundError)):
                            ci.aggregate(root, 'full')
                        self.assertFalse((root / 'native-proof.json').exists())

    def test_aggregate_unit_mode_does_not_require_combined_or_ui_reports(self):
        identities = {'source': 'sha', 'run': 'run', 'attempt': '1', 'inputs_sha256': 'inputs'}
        units = [i for i in ci.inventory() if i.startswith('WoonaTests/')]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ci.write(root / 'unit.json', {'identity': identities, 'xcresult_sha256': 'unit',
                     'tests': [{'id': identity, 'status': 'Passed'} for identity in units]})
            ci.write(root / 'archive-proof.json', {'identity': identities, 'zip64_large': False})
            ci.write(root / 'export-proof.json', identities)
            with patch.object(ci, 'input_digest', return_value='inputs'), \
                    patch.dict(ci.os.environ, {'GITHUB_SHA': 'sha', 'GITHUB_RUN_ID': 'run', 'GITHUB_RUN_ATTEMPT': '1'}):
                ci.aggregate(root, 'unit')
            proof = json.loads((root / 'native-proof.json').read_text())
            self.assertFalse(proof['fullproof'])
            self.assertEqual(0, proof['counts']['ui']['executed'])
            self.assertEqual(len(units), proof['counts']['unit']['passed'])


if __name__ == '__main__':
    unittest.main()
