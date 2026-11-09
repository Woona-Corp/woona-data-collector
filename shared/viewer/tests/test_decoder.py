from __future__ import annotations

from pathlib import Path
import struct
import tempfile
import unittest

from viewer.decoder import DecodeError, build_index, query_signals


def sensor_block(sensor_type: int, channels: list[list[int]]) -> bytes:
    samples = len(channels[0]) if channels else 0
    payload = bytearray([sensor_type, len(channels), samples & 0xFF, (samples >> 8) & 0xFF, 0, 0])
    for channel in channels:
        if len(channel) != samples:
            raise ValueError("channels must have equal sample counts")
        for value in channel:
            payload += int(value).to_bytes(2, "little", signed=(sensor_type != 6))
    return bytes(payload)


def packet(counter: int, timer_ms: int, blocks: list[bytes]) -> bytes:
    payload = b"".join(blocks)
    length = 16 + len(payload)
    header = bytearray(16)
    header[:4] = b"\x33\x99\xaa\x55"
    header[4:6] = length.to_bytes(2, "little")
    header[6] = len(blocks)
    header[7:11] = counter.to_bytes(4, "little")
    header[11:15] = timer_ms.to_bytes(4, "little")
    return bytes(header) + payload


def write_timeline(path: Path, rows: list[tuple[int, int, int, int, int, int]]) -> None:
    with path.open("wb") as output:
        output.write(b"BLETIME1")
        for row in rows:
            output.write(struct.pack(">qqqqqi", *row))


class DecoderTests(unittest.TestCase):
    def test_index_and_query_use_device_timer_with_host_anchor(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            p1 = packet(9, 50, [sensor_block(2, [[10, 20], [30, 40]])])
            p2 = packet(10, 52, [sensor_block(2, [[50, 60], [70, 80]])])
            (root / "packets.bin").write_bytes(p1 + p2)
            write_timeline(root / "packet_timeline.bin", [
                (0, 9, 50, 2000, 9_000_000_000, len(p1)),
                (1, 10, 52, 2100, 9_100_000_000, len(p2)),
            ])

            index = build_index(root / "packets.bin", root / "packet_timeline.bin")
            self.assertEqual(index.time_base, "device_timer+stream_rate (host anchored)")
            self.assertEqual(index.streams, ((2, 1), (2, 2)))
            result = query_signals(
                index, start_ms=0, end_ms=index.duration_ms,
                selected_streams={(2, 1)}, max_points=100,
            )
            self.assertEqual(result["signals"][0]["points"], [
                [0.0, 10.0], [1.0, 20.0], [2.0, 50.0], [3.0, 60.0],
            ])

    def test_microphone_samples_use_8khz_timing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            p1 = packet(1, 1000, [sensor_block(4, [[10, 20, 30, 40]])])
            (root / "packets.bin").write_bytes(p1)
            index = build_index(root / "packets.bin")
            result = query_signals(
                index, start_ms=0, end_ms=index.duration_ms,
                selected_streams={(4, 1)}, max_points=100,
            )
            self.assertEqual(result["signals"][0]["sampleRateHz"], 8000)
            self.assertEqual(result["signals"][0]["points"], [
                [0.0, 10.0], [0.125, 20.0], [0.25, 30.0], [0.375, 40.0],
            ])

    def test_piezo_is_unsigned_and_temperature_is_celsius(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            p1 = packet(1, 0, [
                sensor_block(6, [[0, 65535]]),
                sensor_block(7, [[2525]]),
            ])
            (root / "packets.bin").write_bytes(p1)
            index = build_index(root / "packets.bin")
            result = query_signals(
                index, start_ms=0, end_ms=index.duration_ms,
                selected_streams={(6, 1), (7, 1)}, max_points=100,
            )
            by_key = {signal["key"]: signal for signal in result["signals"]}
            self.assertEqual(by_key["6:1"]["points"], [[0.0, 0.0], [1.0, 65535.0]])
            self.assertEqual(by_key["6:1"]["unit"], "raw U16")
            self.assertEqual(by_key["7:1"]["points"], [[0.0, 25.25]])
            self.assertEqual(by_key["7:1"]["unit"], "°C")

    def test_counter_gap_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            p1 = packet(1, 10, [sensor_block(4, [[1]])])
            p2 = packet(4, 20, [sensor_block(4, [[2]])])
            (root / "packets.bin").write_bytes(p1 + p2)
            index = build_index(root / "packets.bin")
            self.assertEqual(len(index.gaps), 1)
            self.assertEqual(index.gaps[0]["lostPackets"], 2)

    def test_timeline_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            p1 = packet(9, 50, [sensor_block(2, [[10]])])
            (root / "packets.bin").write_bytes(p1)
            write_timeline(root / "packet_timeline.bin", [
                (0, 999, 50, 2000, 9_000_000_000, len(p1)),
            ])
            with self.assertRaises(DecodeError):
                build_index(root / "packets.bin", root / "packet_timeline.bin")

    def test_downsampling_keeps_extrema(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            values = list(range(2000))
            values[999] = -30000
            values[1000] = 30000
            p1 = packet(1, 0, [sensor_block(4, [values])])
            (root / "packets.bin").write_bytes(p1)
            index = build_index(root / "packets.bin")
            result = query_signals(
                index, start_ms=0, end_ms=index.duration_ms,
                selected_streams={(4, 1)}, max_points=100,
            )
            points = result["signals"][0]["points"]
            plotted = [point[1] for point in points]
            self.assertLessEqual(len(points), 100)
            self.assertIn(-30000.0, plotted)
            self.assertIn(30000.0, plotted)


if __name__ == "__main__":
    unittest.main()
