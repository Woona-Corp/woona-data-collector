#!/usr/bin/env python3
"""Unsigned, same-run native CI. Unknown Xcode result schemas fail closed."""
import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import tempfile
import time
from collections import Counter
from pathlib import Path

ROOT = Path(os.environ.get('RUNNER_TEMP', tempfile.gettempdir())) / 'woona-native-ci'
DERIVED = ROOT / 'Derived'
UI_METHODS = (
    'testEnglishLongDogFormPresentsTranslatedOptionsAndRetainsCanonicalAnswersAcrossLanguageChange',
    'testV2PreviewKeepsTheSameChartSelectionWindowPanZoomAndFullscreenControls',
    'testSelectingDogDoesNotAutomaticallyOpenPreexistingHeartQuestionnaire',
    'testHistoryExplainsCaptureFailureSeparatelyAndRemovalCanBeCancelled',
    'testProfileSaveFailureKeepsEditorAndDraftUntilSuccessfulRetry',
    'testAccountPrecedesDogsAndStaysOnOverview',
    'testNewSavesSeparateDogAndKeepsExistingProfile',
    'testFiveTabsPreserveSelectionAndSeparateFunctions',
    'testIdleDiscoveryActionsAppearTogether',
    'testIdentityAndRecordingGroupsReflowWithLargeTextInLandscape',
    'testServerEditorLandscapeKeyboardKeepsDraftAndReachableActions',
    'testNewHeartCaptureOpensOneQuestionnaireAndDismissalDoesNotReopenHistory',
    'testFirstEditNewAndReselectionUseCorrectProfile',
    'testV2PickerIsExplicitAndReturnsToRecordAfterClosingWithoutConnecting',
    'testRussianDarkOverviewHasSameActions',
    'testFullscreenKeepsChartSelection',
    'testServerConnectionRequiresTokenAndCancelDoesNotConfigure',
    'testLanguageChangeUpdatesNavigationAndThemeLabels')


def call(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def output(args):
    return call(args, capture_output=True).stdout.strip()


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + '\n')


def parse_json(text):
    try:
        return json.loads(text)
    except (ValueError, TypeError) as error:
        raise ValueError("Malformed CI JSON; refusing proof") from error


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def inventory():
    # Current suite is XCTest, without parameterized/inherited tests. Multiple
    # classes per file are supported; dynamic additions must update discovery.
    found = []
    for target in ('WoonaTests', 'WoonaUITests'):
        for path in sorted(Path('ios', target).rglob('*.swift')):
            cls = None
            for token in re.finditer(r'class\s+(\w+)\s*:\s*XCTestCase|\bfunc\s+(test\w+)\s*\(', path.read_text()):
                if token[1]:
                    cls = token[1]
                else:
                    if cls is None:
                        raise ValueError(f'Unowned test in {path}')
                    found.append(f'{target}/{cls}/{token[2]}')
    if not found or len(found) != len(set(found)) or not any(i.startswith('WoonaTests/') for i in found):
        raise ValueError('Empty unit suite, empty inventory or duplicate discovered test')
    assigned = [f'WoonaUITests/OverviewParityTests/{m}' for m in UI_METHODS]
    if Counter(assigned) != Counter(i for i in found if i.startswith('WoonaUITests/')):
        raise ValueError('UI inventory differs from explicit reviewed methods')
    return sorted(found)


def input_digest():
    files = output(['git', 'ls-files', 'ios', 'shared', '.github/workflows', '.github/ci']).splitlines()
    h = hashlib.sha256()
    for name in files:
        p = Path(name)
        if p.is_file():
            h.update(name.encode() + b'\0' + p.read_bytes())
    return h.hexdigest()


def identity():
    info = {'source': os.environ['GITHUB_SHA'], 'run': os.environ['GITHUB_RUN_ID'],
            'attempt': os.environ['GITHUB_RUN_ATTEMPT'], 'inputs_sha256': input_digest(),
            'xcode': output(['xcodebuild', '-version']),
            'sdk': output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version']),
            'architecture': platform.machine(), 'runtime': '26.5', 'model': 'iPhone 17 Pro',
            'products_root': str(DERIVED / 'Build/Products')}
    toolchain = {key: info[key] for key in ('xcode', 'sdk', 'architecture', 'runtime', 'model')}
    info['toolchain_sha256'] = hashlib.sha256(json.dumps(toolchain, sort_keys=True).encode()).hexdigest()
    return info


def prepare():
    ROOT.mkdir(parents=True, exist_ok=True)
    info = identity()
    if (not info['xcode'].startswith('Xcode 26.6\n') or info['sdk'] != '26.5'
            or info['architecture'] != 'arm64'):
        raise ValueError(f'Unreviewed toolchain: {info}')
    devices = parse_json(output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
    matches = [d['udid'] for runtime, ds in devices.items() if runtime.endswith('iOS-26-5')
               for d in ds if d['name'] == info['model'] and d.get('isAvailable') is True]
    if len(matches) != 1:
        raise ValueError('Pinned iPhone 17 Pro / iOS 26.5 unavailable or ambiguous')
    (ROOT / 'simulator').write_text(matches[0])
    write(ROOT / 'identity.json', info)
    write(ROOT / 'inventory.json', inventory())
    # Every mode compiles before booting Simulator; execution owns boot.


def result_rows(tree):
    """Xcode 16+/26 `get test-results tests`: Test Case leaves, not suite counters."""
    rows = []
    def visit(node, target=None):
        if not isinstance(node, dict):
            raise ValueError('Malformed test node')
        kind = node.get('nodeType')
        if kind in ('Unit test bundle', 'UI test bundle'):
            target = node.get('name', '').removesuffix('.xctest')
        if kind in ('Repetition', 'Arguments'):
            raise ValueError('Retries/parameterized execution cannot replace exact once proof')
        if kind == 'Test Case Run' and node.get('result') != 'Passed':
            raise ValueError('Failed or skipped underlying test run')
        if kind == 'Test Case':
            test_id = node.get('nodeIdentifier')
            if isinstance(test_id, str) and re.fullmatch(r'\w+/test\w+\(\)', test_id):
                test_id = f'{target}/{test_id}'
            if not isinstance(test_id, str) or not re.fullmatch(r'Woona(?:UI)?Tests/\w+/test\w+\(\)', test_id):
                raise ValueError(f'Unknown test identity schema: {test_id}')
            rows.append({'id': test_id.removesuffix('()'), 'status': node.get('result'),
                         'duration': node.get('duration'), 'durationInSeconds': node.get('durationInSeconds')})
            runs = [c for c in node.get('children') or [] if c.get('nodeType') == 'Test Case Run']
            if len(runs) > 1:
                raise ValueError('Repeated or multi-device test execution')
        for child in node.get('children') or []:
            visit(child, target)
    for node in tree.get('testNodes', []):
        visit(node)
    if not rows:
        raise ValueError('No XCTest case identities found')
    return rows


def require_pass(rows, expected):
    actual = Counter(row['id'] for row in rows)
    if not rows or not expected or actual != Counter(expected) or any(row['status'] != 'Passed' for row in rows):
        raise ValueError(f'Incomplete/duplicate/failed/skipped tests: expected {len(expected)}, actual {actual}')


def tree_digest(directory):
    h = hashlib.sha256()
    for path in sorted(directory.rglob('*')):
        h.update(str(path.relative_to(directory)).encode() + b'\0')
        if path.is_symlink():
            h.update(os.readlink(path).encode())
        elif path.is_file():
            h.update(digest(path).encode())
    return h.hexdigest()


def collect(label):
    bundle = ROOT / f'{label}.xcresult'
    summary = parse_json(output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(bundle), '--compact']))
    write(ROOT / f'{label}-summary.json', summary)
    tree = parse_json(output(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(bundle), '--compact']))
    write(ROOT / f'{label}-raw.json', tree)
    rows = result_rows(tree)
    write(ROOT / f'{label}.json', {'identity': identity(), 'tests': rows,
          'executed': [r['id'] for r in rows],
          'passed': [r['id'] for r in rows if r['status'] == 'Passed'],
          'skipped': [r['id'] for r in rows if r['status'] == 'Skipped'],
          'failed': [r['id'] for r in rows if r['status'] not in ('Passed', 'Skipped')],
          'xcresult_sha256': tree_digest(bundle),
          'products_sha256': tree_digest(DERIVED / 'Build/Products')})
    call(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(bundle),
          '--output-path', str(ROOT / f'{label}-attachments')])
    return rows


def test(label, selectors, sanitizer='none'):
    simulator = (ROOT / 'simulator').read_text()
    state = output(['xcrun', 'simctl', 'list', 'devices', 'booted', '-j'])
    if simulator not in state:
        call(['xcrun', 'simctl', 'boot', simulator], timeout=180)
    call(['xcrun', 'simctl', 'bootstatus', simulator, '-b'], timeout=180)
    products = list((DERIVED / 'Build/Products').glob('*.xctestrun'))
    if len(products) != 1:
        raise ValueError('Expected exactly one xctestrun')
    args = ['xcodebuild', 'test-without-building', '-xctestrun', str(products[0]),
            '-destination', f'platform=iOS Simulator,id={simulator}',
            '-parallel-testing-enabled', 'NO', '-maximum-concurrent-test-simulator-destinations', '1',
            '-resultBundlePath', str(ROOT / f'{label}.xcresult')]
    args += ['-only-testing:' + selector for selector in selectors]
    if sanitizer != 'none':
        args += ['-enable' + sanitizer.title() + 'Sanitizer', 'YES']
    try:
        call(args, timeout=1800)
    finally:
        collect(label)


def aggregate(directory, mode):
    # A failed re-verification must never leave an older successful proof behind.
    (directory / 'native-proof.json').unlink(missing_ok=True)
    expected = inventory()
    if mode != 'full':
        expected = [i for i in expected if i.startswith('WoonaTests/')]
    label = 'full' if mode == 'full' else 'unit'
    data = parse_json((directory / f'{label}.json').read_text())
    rows, info = data['tests'], data['identity']
    require_pass(rows, expected)
    current = {'source': os.environ['GITHUB_SHA'], 'run': os.environ['GITHUB_RUN_ID'],
               'attempt': os.environ['GITHUB_RUN_ATTEMPT'], 'inputs_sha256': input_digest()}
    if any(info.get(key) != value for key, value in current.items()):
        raise ValueError('Evidence does not belong to current run/source/inputs')
    archive = parse_json((directory / 'archive-proof.json').read_text())
    if archive['identity'] != info:
        raise ValueError('Independent archive oracle identity/policy mismatch')
    proof = parse_json((directory / 'export-proof.json').read_text())
    if proof != info:
        raise ValueError('Missing independent export proof binding')
    write(directory / 'native-proof.json', {'mode': mode, 'fullproof': mode == 'full',
          'identity': info, 'tests': rows,
          'expected': expected,
          'executed': [r['id'] for r in rows], 'passed': [r['id'] for r in rows],
          'skipped': [], 'failed': [],
          'counts': {target: {'expected': sum(i.startswith(prefix) for i in expected),
                              'executed': sum(r['id'].startswith(prefix) for r in rows),
                              'passed': sum(r['id'].startswith(prefix) for r in rows),
                              'skipped': 0, 'failed': 0}
                     for target, prefix in (('unit', 'WoonaTests/'), ('ui', 'WoonaUITests/'))},
          'phase_timings': [parse_json(p.read_text()) for p in sorted(directory.glob('*-timing.json'))], 'independent_export_verified': True, 'zip64_large': archive['zip64_large'],
          'products_sha256': data['products_sha256'],
          'result_hashes': {label: data['xcresult_sha256']}})


def main():
    p = argparse.ArgumentParser()
    p.add_argument('command', choices=['prepare', 'build', 'test', 'aggregate', 'archive'])
    p.add_argument('--mode', choices=['full', 'unit', 'diagnostic'], default='full')
    p.add_argument('--test-filter', default='')
    p.add_argument('--sanitizer', choices=['none', 'address', 'thread'], default='none')
    p.add_argument('--directory', type=Path, default=ROOT)
    a = p.parse_args()
    if a.mode != 'diagnostic' and (a.test_filter or a.sanitizer != 'none'):
        p.error('Focused/sanitized execution is diagnostic only')
    started = time.monotonic()
    try:
        if a.command == 'prepare':
            prepare()
        elif a.command == 'build':
            args = ['xcodebuild', 'build-for-testing', '-project', 'ios/Woona.xcodeproj', '-scheme', 'Woona',
                    '-derivedDataPath', str(DERIVED), '-sdk', 'iphonesimulator26.5',
                    '-destination', 'generic/platform=iOS Simulator', 'ARCHS=arm64', 'CODE_SIGNING_ALLOWED=NO']
            if a.sanitizer != 'none':
                args += ['-enable' + a.sanitizer.title() + 'Sanitizer', 'YES']
            call(args, timeout=1200)
        elif a.command == 'test':
            selector = a.test_filter or 'WoonaTests'
            if not re.fullmatch(r'Woona(?:UI)?Tests(?:/\w+){0,2}', selector):
                p.error('Invalid test selector')
            if a.sanitizer != 'none' and selector.startswith('WoonaUITests'):
                p.error('Sanitizers require unit tests')
            (ROOT / 'export-proof.json').unlink(missing_ok=True)
            label = 'full' if a.mode == 'full' else 'unit'
            selectors = ['WoonaTests', 'WoonaUITests'] if a.mode == 'full' else [selector]
            # One invocation uses the original scheme target order, units then UI.
            test(label, selectors, a.sanitizer)
            if a.mode != 'diagnostic':
                call(['python3', 'ios/tools/check-recording-export.py', str(ROOT / f'{label}-attachments')])
                write(ROOT / 'export-proof.json', identity())
        elif a.command == 'archive':
            if platform.system() != 'Darwin' or not shutil.which('swiftc'):
                raise ValueError('Independent archive oracle requires native macOS Swift, not a skipped suite')
            call(['python3', 'ios/tools/test_complete_archive.py'], timeout=600)
            write(ROOT / 'archive-proof.json', {'identity': identity(),
                  'zip64_large': os.environ.get('WOONA_SKIP_ZIP64_LARGE', '0') == '0'})
        elif a.command == 'aggregate':
            if a.mode == 'diagnostic':
                write(a.directory / 'native-proof.json', {'mode': 'diagnostic', 'fullproof': False})
            else:
                aggregate(a.directory, a.mode)
    finally:
        scope = os.environ.get('CI_PHASE_SCOPE', 'native')
        write(ROOT / f'{scope}-{a.command}-timing.json', {'phase': a.command, 'seconds': time.monotonic() - started})


if __name__ == '__main__':
    main()
