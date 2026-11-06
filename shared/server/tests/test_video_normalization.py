import json
import shutil
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from server.video_normalization import normalize_one, packet_grid, probe, sha256, prepare


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'Host media tools required')
class NormalizationTest(unittest.TestCase):
    def test_non_integer_source_becomes_cfr_without_stretch_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);source=root/'source.mp4'
            subprocess.run(['ffmpeg','-v','error','-y','-f','lavfi','-i','testsrc2=size=160x96:rate=25',
                            '-f','lavfi','-i','sine=frequency=1000:sample_rate=48000','-t','1.16',
                            '-c:v','libx264','-threads','1','-c:a','aac',str(source)],check=True)
            row=dict(id=str(uuid.uuid4()),recording_id=str(uuid.uuid4()),server_relative_path='source.mp4',sha256=sha256(source),expected_size_bytes=source.stat().st_size)
            result=normalize_one(root,row,{},threads=1)
            self.assertEqual(result['frame_rate'],30)
            self.assertLessEqual(result['duration_seconds']-result['source_duration_seconds'],1/30+1e-6)
            self.assertEqual(result['audio_streams'],1)
            self.assertTrue(packet_grid(root/result['relative_path'])['cfr30'])
            self.assertEqual(sha256(source),row['sha256'])
            with patch('server.video_normalization.subprocess.run',side_effect=AssertionError('should reuse verified file')):
                self.assertEqual(normalize_one(root,row,{'entries':{row['recording_id']:result}}),result)
            # A missing cached derivative must be rebuilt rather than permanently block the queue.
            (root/result['relative_path']).unlink()
            rebuilt=normalize_one(root,row,{'entries':{row['recording_id']:result}},threads=1)
            self.assertTrue(packet_grid(root/rebuilt['relative_path'])['cfr30'])
            self.assertEqual(rebuilt['source_relative_path'],'source.mp4')

    def test_bad_original_sha_is_rejected_before_overwriting_media(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'source.mp4';p.write_bytes(b'not video')
            with self.assertRaisesRegex(ValueError,'checksum'):
                normalize_one(d,dict(id=str(uuid.uuid4()),recording_id=str(uuid.uuid4()),server_relative_path='source.mp4',sha256='0'*64,expected_size_bytes=9),{})

    def test_bad_recording_does_not_block_other_uploads(self):
        with tempfile.TemporaryDirectory() as d:
            rows=[{'recording_id':str(uuid.uuid4())} for _ in range(2)]
            item={'frame_count':30,'processing_seconds':1,'size_bytes':100}
            registry=Path(d)/'derived/registry.json'
            with patch('server.video_normalization.prepared',return_value=False), \
                 patch('server.video_normalization.normalize_one',side_effect=[ValueError('bad video'),item]):
                with self.assertRaisesRegex(ValueError,'1 recordings'):
                    prepare(d,rows,registry)
            self.assertEqual(json.loads(registry.read_text())['entries'],{rows[1]['recording_id']:item})


class NormalizationSafetyTest(unittest.TestCase):
    """Real offline media, generated once or supplied by the sealed private runner."""
    @staticmethod
    def make_fixtures(root):
        for name, rate, duration, selection in [('regular', 25, '0.64', None),
                ('vfr', 60, '0.64', 'not(mod(n,2))+not(mod(n,5))'),
                ('gap', 30, '0.64', 'eq(n,0)+gte(n,12)'), ('short', 50, '0.02', None)]:
            command = ['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', f'testsrc2=size=160x96:rate={rate}', '-t', duration]
            if selection:
                command += ['-vf', 'select=' + selection.replace(',', r'\,'), '-fps_mode', 'vfr']
            subprocess.run(command + ['-c:v', 'libx264', '-threads', '1', '-movflags', '+faststart', str(root/(name+'.mp4'))], check=True)
        source = root/'regular.mp4'
        packets = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
            '-show_packets', '-of', 'json', str(source)]))['packets']
        data = bytearray(source.read_bytes())
        packet = packets[len(packets)//2]
        start, size = int(packet['pos']), int(packet['size'])
        data[start:start+size] = b'\0'*size
        (root/'damaged.mp4').write_bytes(data)
        (root/'truncated.mp4').write_bytes(source.read_bytes()[:-size])

    @classmethod
    def setUpClass(cls):
        import os
        if not shutil.which('ffmpeg') or not shutil.which('ffprobe'):
            raise RuntimeError('Mandatory offline media tools unavailable')
        cls.fixtures = Path(os.environ.get('WOONA_FPS30_FIXTURES', ''))
        if not os.environ.get('WOONA_FPS30_FIXTURES'):
            cls.directory = tempfile.TemporaryDirectory()
            cls.addClassCleanup(cls.directory.cleanup)
            cls.fixtures = Path(cls.directory.name)
            cls.make_fixtures(cls.fixtures)

    def source(self, root, name):
        source = root/'source.mp4'
        shutil.copyfile(self.fixtures/(name+'.mp4'), source)
        return dict(id='10000000-0000-0000-0000-000000000001',
            recording_id='20000000-0000-0000-0000-000000000001', server_relative_path='source.mp4',
            sha256=sha256(source), expected_size_bytes=source.stat().st_size)

    def test_vfr_and_short_source_verified_without_inventing_sampling_bound(self):
        from fractions import Fraction
        for name in ('vfr', 'short'):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                row = self.source(root, name)
                if name == 'vfr':
                    packets = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_packets',
                        '-select_streams', 'v:0', '-of', 'json', str(root/'source.mp4')]))['packets']
                    pts = sorted(Fraction(p['pts_time']) for p in packets)
                    self.assertGreater(len(set(b-a for a,b in zip(pts, pts[1:]))), 1)
                item = normalize_one(root, row, {}, threads=1)
                grid = packet_grid(root/item['relative_path'])
                self.assertTrue(grid['cfr30'])
                self.assertEqual(grid['frames'], item['frame_count'])
                self.assertLessEqual(item['time_mapping']['max_error_seconds'], 1/30+1e-9)
                self.assertEqual(sha256(root/'source.mp4'), row['sha256'])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            row = self.source(root, 'gap')
            with self.assertRaisesRegex(ValueError, 'sampling|timing'):
                normalize_one(root, row, {}, threads=1)

    def test_decoder_damaged_and_truncated_input_fail_closed(self):
        for name in ('damaged', 'truncated'):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                row = self.source(root, name)
                probe(root/'source.mp4')  # Must reach strict decoding, not fail fixture setup.
                with self.assertRaises((ValueError, subprocess.SubprocessError)):
                    normalize_one(root, row, {}, threads=1)
                self.assertEqual(sha256(root/'source.mp4'), row['sha256'])
                self.assertFalse(list((root/'derived').glob('**/*.mp4')))

    def test_corrupt_cache_is_not_reused(self):
        from server.video_normalization import prepared
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            row = self.source(root, 'regular')
            registry = prepare(root, [row], root/'derived/registry.json', threads=1)
            item = registry['entries'][row['recording_id']]
            path = root/item['relative_path']
            data = path.read_bytes()
            path.write_bytes(bytes([data[0]^1])+data[1:])
            self.assertFalse(prepared(root, row, item, 'ultrafast', 18))

    def test_publication_failure_preserves_old_reference_and_success_flushes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            row = self.source(root, 'regular')
            registry_path = root/'derived/video-presentations.json'
            first = prepare(root, [row], registry_path, threads=1)
            item = first['entries'][row['recording_id']]
            old = root/item['relative_path']
            data = old.read_bytes()
            frozen = registry_path.read_bytes()
            with patch('server.video_normalization.atomic_json', side_effect=OSError('injected registry failure')):
                with self.assertRaises(OSError):
                    prepare(root, [row], registry_path, threads=1, crf=19)
            self.assertEqual(registry_path.read_bytes(), frozen)
            self.assertEqual(old.read_bytes(), data)
            with patch('server.video_normalization.os.fsync', wraps=__import__('os').fsync) as fsync:
                second = prepare(root, [row], registry_path, threads=1, crf=19)
            changed = second['entries'][row['recording_id']]
            self.assertNotEqual(changed['relative_path'], item['relative_path'])
            self.assertEqual(sha256(root/changed['relative_path']), changed['sha256'])
            self.assertGreaterEqual(fsync.call_count, 4)
