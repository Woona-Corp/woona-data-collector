import unittest

from viewer.http_range import parse_byte_range


class VideoRangeTests(unittest.TestCase):
    def test_closed_range(self):
        self.assertEqual(parse_byte_range("bytes=10-19", 100), (10, 19))

    def test_open_ended_range(self):
        self.assertEqual(parse_byte_range("bytes=90-", 100), (90, 99))

    def test_invalid_range_is_rejected(self):
        for value in ("bytes=100-", "bytes=20-10", "items=0-1", "bytes=-10"):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    parse_byte_range(value, 100)


if __name__ == "__main__":
    unittest.main()
