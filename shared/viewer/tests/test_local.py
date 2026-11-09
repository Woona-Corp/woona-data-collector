from pathlib import Path
import struct
import tempfile
import unittest

from viewer.local import discover_recording_files


def packet(counter: int = 1, timer_ms: int = 0) -> bytes:
    block = bytes([2, 1, 1, 0, 0, 0]) + (123).to_bytes(2, "little", signed=True)
    length = 16 + len(block)
    header = bytearray(16)
    header[:4] = b"\x33\x99\xaa\x55"
    header[4:6] = length.to_bytes(2, "little")
    header[6] = 1
    header[7:11] = counter.to_bytes(4, "little")
    header[11:15] = timer_ms.to_bytes(4, "little")
    return bytes(header) + block


def timeline(packet_bytes: int) -> bytes:
    return b"BLETIME1" + struct.pack(">qqqqqi", 0, 1, 0, 1000, 2_000_000_000, packet_bytes)


class LocalViewerDiscoveryTests(unittest.TestCase):
    def test_discovers_downloaded_content_bins_by_magic(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            packet_bytes = packet()
            packet_path = root / "content (2).bin"
            timeline_path = root / "content (1).bin"
            packet_path.write_bytes(packet_bytes)
            timeline_path.write_bytes(timeline(len(packet_bytes)))

            found_packet, found_timeline = discover_recording_files(root)

            self.assertEqual(found_packet, packet_path.resolve())
            self.assertEqual(found_timeline, timeline_path.resolve())

    def test_timeline_is_optional(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            packet_path = root / "packets.bin"
            packet_path.write_bytes(packet())

            found_packet, found_timeline = discover_recording_files(root)

            self.assertEqual(found_packet, packet_path.resolve())
            self.assertIsNone(found_timeline)


if __name__ == "__main__":
    unittest.main()
