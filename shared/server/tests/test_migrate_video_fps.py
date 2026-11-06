from copy import deepcopy
from fractions import Fraction
import unittest

from server.migrate_video_fps import config30, convert_result


class FpsMigrationTest(unittest.TestCase):
    def test_ranges_preserve_wall_time_labels_ids_and_nested_snapshots(self):
        region = {'id': 'keep', 'type': 'timelinelabels', 'from_name': 'labels', 'to_name': 'video',
                  'value': {'timelinelabels': ['Шаг', 'Нюхает'], 'ranges': [{'start': 25, 'end': 48}]}}
        original = {'result': [region], 'prediction': {'result': [deepcopy(region)]}, 'score': .3}
        converted = convert_result(original, 24, 'labels', 'video')
        self.assertEqual(converted['result'][0]['value']['ranges'], [{'start': 31, 'end': 60}])
        self.assertEqual(converted['prediction']['result'], converted['result'])
        self.assertEqual(converted['result'][0]['id'], 'keep')
        self.assertEqual(converted['result'][0]['value']['timelinelabels'], ['Шаг', 'Нюхает'])
        self.assertEqual(original['result'][0]['value']['ranges'][0]['start'], 25)
        self.assertEqual(convert_result(converted, 30, 'labels', 'video'), converted)

    def test_quantization_bound_and_adjacency_including_one_frame_intervals(self):
        spans = [{'start': i, 'end': i} for i in range(1, 2401)]
        region = {'type': 'timelinelabels', 'from_name': 'labels', 'to_name': 'video',
                  'value': {'ranges': spans}}
        converted = convert_result([region], 24, 'labels', 'video')[0]['value']['ranges']
        for i, (old, new) in enumerate(zip(spans, converted)):
            self.assertLessEqual(abs(Fraction(old['start'] - 1, 24) - Fraction(new['start'] - 1, 30)), Fraction(1, 60))
            self.assertLessEqual(abs(Fraction(old['end'], 24) - Fraction(new['end'], 30)), Fraction(1, 60))
            self.assertLessEqual(new['start'], new['end'])
            if i:
                self.assertEqual(converted[i-1]['end'] + 1, new['start'])

    def test_config_preserves_other_bytes_and_invalid_intervals_fail_closed(self):
        old = '<View><!-- keep --><Video name="video" frameRate="24" value="$video"/><TimelineLabels name="labels" toName="video"/></View>'
        new, fps, timeline, video = config30(old)
        self.assertEqual(new, old.replace('frameRate="24"', 'frameRate="30"'))
        self.assertEqual((fps, timeline, video), (24, 'labels', 'video'))
        self.assertEqual(config30(new), (new, 30, 'labels', 'video'))
        self.assertEqual(config30(old.replace(' frameRate="24"', ''))[1], 24)
        with self.assertRaises(ValueError):
            config30(old.replace('24', '$fps'))
        for start, end in [(0, 3), (4, 3), (True, 3), (1.5, 3)]:
            with self.assertRaises(ValueError):
                convert_result([{'type': 'timelinelabels', 'from_name': 'labels', 'to_name': 'video',
                                 'value': {'ranges': [{'start': start, 'end': end}]}}], 24, 'labels', 'video')
