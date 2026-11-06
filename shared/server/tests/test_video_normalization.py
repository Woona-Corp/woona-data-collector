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
