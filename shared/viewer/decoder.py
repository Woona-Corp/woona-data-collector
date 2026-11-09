from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import struct
from typing import Iterable

PACKET_MAGIC = b"\x33\x99\xaa\x55"
TIMELINE_MAGIC = b"BLETIME1"
MIN_PACKET_SIZE = 16
MAX_PACKET_SIZE = 16_384
MAX_MEASUREMENT_COUNT = 4
MAX_SENSOR_BLOCK_TRAILER_BYTES = 4
TIMELINE_ROW = struct.Struct(">qqqqqi")

# Canonical V2 sensor types written by the mobile clients.
# The on-disk packet format does not carry sample rate, so the viewer uses the
# protocol's current fixed stream profile. Unknown/legacy types retain a safe
# 1 kHz fallback instead of inventing a physical label.
STREAM_SAMPLE_RATES_HZ = {
    2: 1000,  # accelerometer
    3: 1000,  # gyroscope
    4: 8000,  # contact microphone
    5: 8000,  # ambient microphone
    6: 1000,  # piezo
    7: 1,     # main-board temperature
    8: 1,     # ribbon temperature
}


class DecodeError(ValueError):
    pass


@dataclass(frozen=True)
class TimelineEntry:
    sequence: int
    counter: int
    device_timer_ms: int
    host_wall_clock_ms: int
    host_monotonic_ns: int
    packet_bytes: int


@dataclass(frozen=True)
class PacketEntry:
    offset: int
    length: int
    counter: int
    device_timer_ms: int
    unwrapped_device_timer_ms: int
    host_wall_clock_ms: int | None
    host_monotonic_ns: int | None
    start_ms: float
    end_ms: float


@dataclass(frozen=True)
class RecordingIndex:
    packet_path: Path
    timeline_path: Path | None
    packet_size: int
    packet_mtime_ns: int
    timeline_size: int | None
    timeline_mtime_ns: int | None
    entries: tuple[PacketEntry, ...]
    streams: tuple[tuple[int, int], ...]
    duration_ms: float
    time_base: str
    gaps: tuple[dict, ...]


def stream_sample_rate_hz(sensor_type: int) -> int:
    return STREAM_SAMPLE_RATES_HZ.get(sensor_type, 1000)


def stream_label(sensor_type: int, channel: int) -> str:
    if sensor_type == 1:
        return f"Legacy temperature {channel}"
    if sensor_type == 2:
        axis = {1: "X", 2: "Y", 3: "Z"}.get(channel, str(channel))
        return f"Accel {axis}"
    if sensor_type == 3:
        axis = {1: "X", 2: "Y", 3: "Z"}.get(channel, str(channel))
        return f"Gyro {axis}"
    if sensor_type == 4:
        return "Contact microphone" if channel == 1 else f"Contact microphone {channel}"
    if sensor_type == 5:
        return "Ambient microphone" if channel == 1 else f"Ambient microphone {channel}"
    if sensor_type == 6:
        return "Piezo" if channel == 1 else f"Piezo {channel}"
    if sensor_type == 7:
        return "Main-board temperature" if channel == 1 else f"Main-board temperature {channel}"
    if sensor_type == 8:
        return "Ribbon temperature" if channel == 1 else f"Ribbon temperature {channel}"
    return f"Sensor {sensor_type} / ch {channel}"


def _u32_le(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset:offset + 4], "little", signed=False)


def _validate_packet(packet: bytes) -> tuple[int, int, dict[tuple[int, int], list[float]]]:
    if len(packet) < MIN_PACKET_SIZE:
        raise DecodeError("packet is shorter than the 16-byte header")
    if packet[:4] != PACKET_MAGIC:
        raise DecodeError("invalid packet start marker")
    declared = int.from_bytes(packet[4:6], "little", signed=False)
    if declared != len(packet) or not MIN_PACKET_SIZE <= declared <= MAX_PACKET_SIZE:
        raise DecodeError("invalid packet length")
    measurement_count = packet[6]
    if not 1 <= measurement_count <= MAX_MEASUREMENT_COUNT:
        raise DecodeError("invalid measurement count")

    offset = MIN_PACKET_SIZE
    streams: dict[tuple[int, int], list[float]] = {}
    parsed = 0
    for _ in range(measurement_count):
        if offset + 6 > len(packet):
            raise DecodeError("truncated sensor block header")
        sensor_type = packet[offset]
        channel_count = packet[offset + 1]
        samples_per_channel = int.from_bytes(packet[offset + 2:offset + 4], "little")
        if channel_count == 0:
            raise DecodeError("sensor block has no channels")
        payload_size = channel_count * samples_per_channel * 2
        next_offset = offset + 6 + payload_size
        if next_offset > len(packet):
            raise DecodeError("truncated sensor block payload")

        sample_offset = offset + 6
        for channel_index in range(channel_count):
            key = (sensor_type, channel_index + 1)
            values = streams.setdefault(key, [])
            for _ in range(samples_per_channel):
                raw = int.from_bytes(packet[sample_offset:sample_offset + 2], "little", signed=True)
                values.append(float(raw))
                sample_offset += 2
        offset = next_offset
        parsed += 1

    if parsed != measurement_count:
        raise DecodeError("sensor block count does not match packet header")
    trailer = len(packet) - offset
    if not 0 <= trailer <= MAX_SENSOR_BLOCK_TRAILER_BYTES:
        raise DecodeError("invalid sensor block trailer")
    return _u32_le(packet, 7), _u32_le(packet, 11), streams


def iter_packets(path: Path) -> Iterable[tuple[int, bytes]]:
    offset = 0
    with path.open("rb") as source:
        while True:
            header = source.read(MIN_PACKET_SIZE)
            if not header:
                return
            if len(header) != MIN_PACKET_SIZE:
                raise DecodeError(f"truncated packet header at offset {offset}")
            if header[:4] != PACKET_MAGIC:
                raise DecodeError(f"invalid packet start marker at offset {offset}")
            length = int.from_bytes(header[4:6], "little")
            if not MIN_PACKET_SIZE <= length <= MAX_PACKET_SIZE:
                raise DecodeError(f"invalid packet length {length} at offset {offset}")
            body = source.read(length - MIN_PACKET_SIZE)
            if len(body) != length - MIN_PACKET_SIZE:
                raise DecodeError(f"truncated packet body at offset {offset}")
            packet = header + body
            yield offset, packet
            offset += length


def read_timeline(path: Path) -> list[TimelineEntry]:
    result: list[TimelineEntry] = []
    with path.open("rb") as source:
        if source.read(len(TIMELINE_MAGIC)) != TIMELINE_MAGIC:
            raise DecodeError("invalid packet timeline header")
        while True:
            row = source.read(TIMELINE_ROW.size)
            if not row:
                break
            if len(row) != TIMELINE_ROW.size:
                raise DecodeError("truncated packet timeline row")
            result.append(TimelineEntry(*TIMELINE_ROW.unpack(row)))
    return result


def _packet_duration_ms(values: dict[tuple[int, int], list[float]]) -> float:
    duration = 0.0
    for (sensor_type, _), samples in values.items():
        if len(samples) <= 1:
            continue
        duration = max(
            duration,
            (len(samples) - 1) * 1000.0 / stream_sample_rate_hz(sensor_type),
        )
    return duration


def build_index(packet_path: Path, timeline_path: Path | None = None) -> RecordingIndex:
    packet_path = packet_path.resolve()
    if not packet_path.is_file():
        raise DecodeError("packets.bin is missing")
    timeline_path = timeline_path.resolve() if timeline_path and timeline_path.is_file() else None
    timeline = read_timeline(timeline_path) if timeline_path else []

    entries: list[PacketEntry] = []
    streams: set[tuple[int, int]] = set()
    gaps: list[dict] = []
    previous_counter: int | None = None
    previous_raw_timer: int | None = None
    timer_epoch = 0
    first_unwrapped_timer: int | None = None
    first_host_ns: int | None = None

    for packet_index, (offset, packet) in enumerate(iter_packets(packet_path)):
        counter, device_timer_ms, values = _validate_packet(packet)
        timeline_entry = timeline[packet_index] if packet_index < len(timeline) else None
        if timeline_path is not None:
            if timeline_entry is None:
                raise DecodeError("packet timeline has fewer rows than packets.bin")
            if (
                timeline_entry.counter != counter
                or timeline_entry.device_timer_ms != device_timer_ms
                or timeline_entry.packet_bytes != len(packet)
            ):
                raise DecodeError("packet timeline does not match packets.bin")

        if previous_raw_timer is not None and device_timer_ms < previous_raw_timer:
            backwards = previous_raw_timer - device_timer_ms
            if backwards > 0x8000_0000:
                timer_epoch += 1 << 32
            else:
                raise DecodeError("device timer regressed without uint32 rollover")
        previous_raw_timer = device_timer_ms
        unwrapped_timer = timer_epoch + device_timer_ms
        if first_unwrapped_timer is None:
            first_unwrapped_timer = unwrapped_timer

        streams.update(values)
        packet_duration = _packet_duration_ms(values)

        if timeline_entry is not None:
            if first_host_ns is None:
                first_host_ns = timeline_entry.host_monotonic_ns
            start_ms = (timeline_entry.host_monotonic_ns - first_host_ns) / 1_000_000.0
            host_wall = timeline_entry.host_wall_clock_ms
            host_mono = timeline_entry.host_monotonic_ns
        else:
            start_ms = float(unwrapped_timer - first_unwrapped_timer)
            host_wall = None
            host_mono = None
        end_ms = start_ms + packet_duration

        if previous_counter is not None:
            delta = (counter - previous_counter) & 0xFFFFFFFF
            if 1 < delta < 0x8000_0000:
                gaps.append({
                    "afterCounter": previous_counter,
                    "beforeCounter": counter,
                    "lostPackets": delta - 1,
                    "atMs": start_ms,
                })
        previous_counter = counter

        entries.append(PacketEntry(
            offset=offset,
            length=len(packet),
            counter=counter,
            device_timer_ms=device_timer_ms,
            unwrapped_device_timer_ms=unwrapped_timer,
            host_wall_clock_ms=host_wall,
            host_monotonic_ns=host_mono,
            start_ms=start_ms,
            end_ms=end_ms,
        ))

    if timeline_path is not None and len(timeline) != len(entries):
        raise DecodeError("packet timeline has extra rows")

    packet_stat = packet_path.stat()
    timeline_stat = timeline_path.stat() if timeline_path else None
    duration = max((entry.end_ms for entry in entries), default=0.0)
    return RecordingIndex(
        packet_path=packet_path,
        timeline_path=timeline_path,
        packet_size=packet_stat.st_size,
        packet_mtime_ns=packet_stat.st_mtime_ns,
        timeline_size=timeline_stat.st_size if timeline_stat else None,
        timeline_mtime_ns=timeline_stat.st_mtime_ns if timeline_stat else None,
        entries=tuple(entries),
        streams=tuple(sorted(streams)),
        duration_ms=max(0.0, duration),
        time_base="host_monotonic+stream_rate" if timeline_path else "device_timer+stream_rate",
        gaps=tuple(gaps),
    )


class _SeriesCollector:
    def __init__(self, start_ms: float, end_ms: float, max_points: int):
        self.start_ms = start_ms
        self.end_ms = end_ms
        self.max_points = max_points
        self.raw: list[tuple[float, float]] | None = []
        self.bins: dict[int, tuple[tuple[float, float], tuple[float, float]]] | None = None
        self.count = 0
        self.bucket_count = max(1, max_points // 2)
        span = max(end_ms - start_ms, 1e-9)
        self.bucket_width = span / self.bucket_count

    def add(self, t_ms: float, value: float) -> None:
        self.count += 1
        if self.raw is not None:
            self.raw.append((t_ms, value))
            if len(self.raw) <= self.max_points:
                return
            old = self.raw
            self.raw = None
            self.bins = {}
            for point in old:
                self._add_bin(*point)
            return
        self._add_bin(t_ms, value)

    def _add_bin(self, t_ms: float, value: float) -> None:
        assert self.bins is not None
        index = min(self.bucket_count - 1, max(0, int((t_ms - self.start_ms) / self.bucket_width)))
        current = self.bins.get(index)
        point = (t_ms, value)
        if current is None:
            self.bins[index] = (point, point)
            return
        low, high = current
        if value < low[1]:
            low = point
        if value > high[1]:
            high = point
        self.bins[index] = (low, high)

    def points(self) -> list[list[float]]:
        if self.raw is not None:
            return [[round(t, 6), v] for t, v in self.raw]
        assert self.bins is not None
        result: list[tuple[float, float]] = []
        for index in sorted(self.bins):
            low, high = self.bins[index]
            if low == high:
                result.append(low)
            else:
                result.extend(sorted((low, high), key=lambda item: item[0]))
        return [[round(t, 6), v] for t, v in result]


def query_signals(
    index: RecordingIndex,
    *,
    start_ms: float,
    end_ms: float,
    selected_streams: set[tuple[int, int]] | None,
    max_points: int,
) -> dict:
    start_ms = max(0.0, float(start_ms))
    end_ms = min(index.duration_ms, float(end_ms))
    if end_ms < start_ms:
        raise DecodeError("end_ms must be greater than or equal to start_ms")

    selected = set(index.streams) if selected_streams is None else set(selected_streams) & set(index.streams)
    collectors = {key: _SeriesCollector(start_ms, end_ms, max_points) for key in selected}

    with index.packet_path.open("rb") as source:
        for entry in index.entries:
            if entry.end_ms < start_ms or entry.start_ms > end_ms:
                continue
            source.seek(entry.offset)
            packet = source.read(entry.length)
            counter, timer_ms, values = _validate_packet(packet)
            if counter != entry.counter or timer_ms != entry.device_timer_ms:
                raise DecodeError("packets.bin changed after index creation")

            for key in selected:
                series = values.get(key)
                if not series:
                    continue
                collector = collectors[key]
                rate_hz = stream_sample_rate_hz(key[0])
                step_ms = 1000.0 / rate_hz
                for sample_index, value in enumerate(series):
                    t_ms = entry.start_ms + sample_index * step_ms
                    if start_ms <= t_ms <= end_ms:
                        collector.add(t_ms, value)

    signals = []
    for sensor_type, channel in sorted(selected):
        collector = collectors[(sensor_type, channel)]
        signals.append({
            "key": f"{sensor_type}:{channel}",
            "sensorType": sensor_type,
            "channel": channel,
            "label": stream_label(sensor_type, channel),
            "sampleRateHz": stream_sample_rate_hz(sensor_type),
            "rawCount": collector.count,
            "points": collector.points(),
        })

    gaps = [gap for gap in index.gaps if start_ms <= float(gap["atMs"]) <= end_ms]
    return {
        "fromMs": start_ms,
        "toMs": end_ms,
        "durationMs": index.duration_ms,
        "timeBase": index.time_base,
        "signals": signals,
        "gaps": gaps,
    }
