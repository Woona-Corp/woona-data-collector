"""Hermetic native orchestration policy/schema tests; no simulator claims."""
import copy
import json
import re
import subprocess
import sys
import tempfile
import textwrap
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
    def test_current_source_inventory_and_exact_reviewed_ui(self):
        items = ci.inventory()
        self.assertEqual(359, len([i for i in items if i.startswith('WoonaTests/')]))
        self.assertEqual(377, len(items))
        self.assertIn('WoonaTests/BleControlWriteQueueTests/testQueueBoundsFourFramesAndDisconnectFailsEveryPendingCommandOnce', items)
        self.assertIn('WoonaTests/V2PreviewTests/testCoarseningKeepsEndpointsAndPropagatesSegmentBreaks', items)
        self.assertEqual(18, len([i for i in items if i.startswith('WoonaUITests/')]))
        self.assertEqual(18, len(ci.UI_METHODS))
        self.assertEqual(18, len(set(ci.UI_METHODS)))

    def test_added_or_duplicated_ui_case_is_not_silently_omitted(self):
        for methods in (ci.UI_METHODS[:-1], ci.UI_METHODS + (ci.UI_METHODS[0],)):
            with patch.object(ci, 'UI_METHODS', methods), self.assertRaises(ValueError):
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
                    patch.object(ci, 'output', return_value='device-id'), \
                    patch.object(ci, 'call') as call, patch.object(ci, 'collect'):
                ci.test('full', ['WoonaTests', 'WoonaUITests'])
            boot, test = call.call_args_list
            self.assertEqual(180, boot.kwargs['timeout'])
            args = test.args[0]
            self.assertIn('test-without-building', args)
            self.assertNotIn('build-for-testing', args)
            self.assertEqual('NO', args[args.index('-parallel-testing-enabled') + 1])
            self.assertEqual('1', args[args.index('-maximum-concurrent-test-simulator-destinations') + 1])
            self.assertEqual(['-only-testing:WoonaTests', '-only-testing:WoonaUITests'],
                             [a for a in args if a.startswith('-only-testing:')])
            self.assertEqual(['xcrun', 'simctl', 'bootstatus', 'device-id', '-b'], boot.args[0])

    def test_failed_xcode_still_collects_results_and_does_not_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'simulator').write_text('device-id')
            (root / 'Build/Products').mkdir(parents=True)
            (root / 'Build/Products/run.xctestrun').touch()
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'DERIVED', root), \
                    patch.object(ci, 'output', return_value='device-id'), \
                    patch.object(ci, 'call', side_effect=[None, subprocess.CalledProcessError(65, 'xcodebuild')]) as call, \
                    patch.object(ci, 'collect') as collect, self.assertRaises(subprocess.CalledProcessError):
                ci.test('unit', ['WoonaTests'])
            self.assertEqual(2, call.call_count)
            collect.assert_called_once_with('unit')

    def test_pinned_prepare_rejects_toolchain_and_missing_model(self):
        good = {'xcode': 'Xcode 26.6\nBuild version reviewed', 'sdk': '26.5',
                'architecture': 'arm64', 'model': 'iPhone 17 Pro'}
        devices = {'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [
            {'name': 'iPhone 17 Pro', 'udid': 'reviewed-device', 'isAvailable': True}]}}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'identity', return_value=good), \
                    patch.object(ci, 'inventory', return_value=['fixture']), \
                    patch.object(ci, 'output', return_value=json.dumps(devices)), \
                    patch.object(ci, 'call') as call:
                ci.prepare()
                self.assertEqual('reviewed-device', (root / 'simulator').read_text())
                call.assert_not_called()
            for changed in ({**good, 'sdk': '26.6'}, {**good, 'architecture': 'x86_64'},
                            {**good, 'xcode': 'Xcode 26.7\nBuild version newer'}):
                with patch.object(ci, 'ROOT', root), patch.object(ci, 'identity', return_value=changed), \
                        self.assertRaises(ValueError):
                    ci.prepare()
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'identity', return_value=good), \
                    patch.object(ci, 'output', return_value='{"devices": {}}'), self.assertRaises(ValueError):
                ci.prepare()


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

    def test_unit_and_focused_diagnostic_paths_remain_single_invocations(self):
        for mode, selector in (('unit', 'WoonaTests'), ('diagnostic',
                              'WoonaUITests/OverviewParityTests/testFiveTabsPreserveSelectionAndSeparateFunctions')):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                argv = ['native_ci.py', 'test', '--mode', mode]
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
                        patch('sys.argv', ['native_ci.py', 'test']), self.assertRaises(subprocess.CalledProcessError):
                    ci.main()
                test.assert_called_once()
                self.assertEqual(0 if failed_operation == 'test' else 1, call.call_count)
                self.assertFalse((root / 'export-proof.json').exists())

    def test_all_modes_prepare_without_boot_before_single_build_and_test(self):
        for mode in ('full', 'unit', 'diagnostic'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                with patch.object(ci, 'ROOT', Path(directory)), patch.object(ci, 'prepare') as prepare, \
                        patch('sys.argv', ['native_ci.py', 'prepare', '--mode', mode]):
                    ci.main()
                    prepare.assert_called_once_with()
        root = Path(__file__).resolve().parents[2]
        workflow = (root / '.github/workflows/ios-native.yml').read_text()
        self.assertEqual(1, workflow.count('runs-on: macos-26'))
        self.assertEqual(1, workflow.count('runs-on: ubuntu-latest'))
        for obsolete in ('matrix:', 'WOONA_CI_ROLE', 'ios-test-products', 'native_ci.py pack',
                         'native_ci.py verify', 'ui-1', 'ui-2'):
            self.assertNotIn(obsolete, workflow)
        self.assertEqual(1, workflow.count('native_ci.py build'))
        self.assertEqual(1, workflow.count('native_ci.py test '))
        self.assertEqual(1, workflow.count('native_ci.py archive'))
        self.assertLess(workflow.index('native_ci.py prepare'), workflow.index('native_ci.py build'))
        self.assertLess(workflow.index('native_ci.py build'), workflow.index('native_ci.py test '))
        self.assertIn('needs: native-build-unit', workflow)
        self.assertIn('ios-native-full-evidence', workflow)
        self.assertIn("retention-days: ${{ job.status == 'success' && 7 || 14 }}", workflow)
        scheme = (root / 'ios/Woona.xcodeproj/xcshareddata/xcschemes/Woona.xcscheme').read_text()
        self.assertLess(scheme.index('BlueprintName = "WoonaTests"'), scheme.index('BlueprintName="WoonaUITests"'))

    def test_full_single_invocation_and_export_check(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'test') as test, \
                    patch.object(ci, 'call') as call, patch.object(ci, 'identity', return_value={'source': 'sha'}), \
                    patch('sys.argv', ['native_ci.py', 'test']):
                ci.main()
            test.assert_called_once_with('full', ['WoonaTests', 'WoonaUITests'], 'none')
            call.assert_called_once_with(['python3', 'ios/tools/check-recording-export.py',
                                          str(root / 'full-attachments')])
            self.assertEqual({'source': 'sha'}, json.loads((root / 'export-proof.json').read_text()))

    def test_execution_boots_only_when_needed_and_waits_before_xcode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'simulator').write_text('device-id')
            (root / 'Build/Products').mkdir(parents=True)
            (root / 'Build/Products/run.xctestrun').touch()
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'DERIVED', root), \
                    patch.object(ci, 'output', return_value='{}'), patch.object(ci, 'call') as call, \
                    patch.object(ci, 'collect'):
                ci.test('full', ['WoonaTests', 'WoonaUITests'])
            boot, wait, test = call.call_args_list
            self.assertEqual(['xcrun', 'simctl', 'boot', 'device-id'], boot.args[0])
            self.assertEqual(['xcrun', 'simctl', 'bootstatus', 'device-id', '-b'], wait.args[0])
            self.assertEqual('test-without-building', test.args[0][1])
            self.assertEqual(1800, test.kwargs['timeout'])

    def test_full_aggregate_exact_physical_report_and_fail_closed(self):
        identity = {'source': 'sha', 'run': 'run', 'attempt': '1', 'inputs_sha256': 'inputs',
                    'toolchain_sha256': 'toolchain'}
        expected = ci.inventory()
        valid = {'identity': identity, 'xcresult_sha256': 'result', 'products_sha256': 'products',
                 'tests': [{'id': case, 'status': 'Passed'} for case in expected]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def reset():
                ci.write(root / 'full.json', valid)
                ci.write(root / 'export-proof.json', identity)
                ci.write(root / 'archive-proof.json', {'identity': identity, 'zip64_large': True})
            with patch.object(ci, 'input_digest', return_value='inputs'), \
                    patch.dict(ci.os.environ, {'GITHUB_SHA': 'sha', 'GITHUB_RUN_ID': 'run', 'GITHUB_RUN_ATTEMPT': '1'}):
                reset()
                ci.aggregate(root, 'full')
                proof = json.loads((root / 'native-proof.json').read_text())
                self.assertTrue(proof['fullproof'])
                self.assertTrue(proof['zip64_large'])
                self.assertEqual(377, len(proof['passed']))
                self.assertEqual(359, proof['counts']['unit']['passed'])
                self.assertEqual(18, proof['counts']['ui']['passed'])
                self.assertEqual({'full': 'result'}, proof['result_hashes'])
                self.assertEqual('products', proof['products_sha256'])
                for bad in ('empty', 'missing-unit', 'missing-ui', 'duplicate', 'unknown', 'failed',
                            'skipped', 'expected-failure', 'source', 'run', 'attempt', 'inputs_sha256',
                            'toolchain_sha256', 'missing-full', 'missing-export', 'missing-archive',
                            'wrong-export', 'wrong-archive'):
                    with self.subTest(bad=bad):
                        reset()
                        ci.write(root / 'native-proof.json', {'fullproof': True})
                        data = copy.deepcopy(valid)
                        if bad == 'empty':
                            data['tests'] = []
                        elif bad in ('missing-unit', 'missing-ui'):
                            target = 'WoonaTests/' if bad == 'missing-unit' else 'WoonaUITests/'
                            data['tests'].remove(next(r for r in data['tests'] if r['id'].startswith(target)))
                        elif bad == 'duplicate':
                            data['tests'].append(data['tests'][0])
                        elif bad == 'unknown':
                            data['tests'][0]['id'] = 'WoonaTests/Unknown/testUnknown'
                        elif bad in ('failed', 'skipped', 'expected-failure'):
                            data['tests'][0]['status'] = bad
                        elif bad in identity:
                            data['identity'][bad] = 'other'
                        ci.write(root / 'full.json', data)
                        if bad.startswith('missing-') and bad not in ('missing-unit', 'missing-ui'):
                            name = {'missing-full': 'full', 'missing-export': 'export-proof',
                                    'missing-archive': 'archive-proof'}[bad]
                            (root / f'{name}.json').unlink()
                        elif bad == 'wrong-export':
                            ci.write(root / 'export-proof.json', {**identity, 'source': 'other'})
                        elif bad == 'wrong-archive':
                            ci.write(root / 'archive-proof.json', {'identity': {**identity, 'source': 'other'}})
                        with self.assertRaises((ValueError, FileNotFoundError)):
                            ci.aggregate(root, 'full')
                        self.assertFalse((root / 'native-proof.json').exists())

    def test_artifact_binding_rejects_empty_or_invalid_service_metadata(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / '.github/workflows/ios-native.yml').read_text()
        match = re.search(r'          import json, os, re\n.*?          PY', workflow, re.S)
        assert match is not None
        script = textwrap.dedent(match[0].removesuffix('          PY'))
        valid = {'id': 123, 'name': 'ios-native-full-evidence', 'expired': False,
                 'created_at': '2026-11-12T11:35:33Z',
                 'digest': 'sha256:' + 'a' * 64, 'size_in_bytes': 100}
        previous = {**valid, 'id': 122, 'created_at': '2026-11-12T11:04:32Z',
                    'digest': 'sha256:' + 'b' * 64}
        variants = [('valid', [valid]), ('missing', []), ('duplicate', [valid, valid]),
                    ('rerun_latest', [previous, valid]), ('rerun_latest_reordered', [valid, previous])]
        variants += [(key, [{**valid, key: value}]) for key, value in (
            ('expired', True), ('id', 0), ('id', True), ('size_in_bytes', 0),
            ('digest', None), ('digest', ''), ('digest', 'sha256:invalid'))]
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / 'native-evidence'
            evidence.mkdir()
            for name, artifacts in variants:
                accepted = name in ('valid', 'rerun_latest', 'rerun_latest_reordered')
                with self.subTest(name=name, artifacts=artifacts):
                    ci.write(evidence / 'artifacts.json', {'artifacts': artifacts})
                    ci.write(evidence / 'native-proof.json', {'mode': 'full', 'fullproof': True})
                    result = subprocess.run([sys.executable, '-c', script], cwd=directory,
                                            env={**ci.os.environ, 'MODE': 'full'},
                                            capture_output=True, text=True)
                    self.assertEqual(accepted, result.returncode == 0, result.stderr)
                    proof = json.loads((evidence / 'native-proof.json').read_text())
                    self.assertEqual(accepted, 'artifacts' in proof)
                    if accepted:
                        self.assertEqual([123], [a['id'] for a in proof['artifacts']])

    def test_aggregate_unit_mode_does_not_require_full_or_ui_reports(self):
        identities = {'source': 'sha', 'run': 'run', 'attempt': '1', 'inputs_sha256': 'inputs'}
        units = [i for i in ci.inventory() if i.startswith('WoonaTests/')]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ci.write(root / 'unit.json', {'identity': identities, 'xcresult_sha256': 'unit', 'products_sha256': 'products',
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
