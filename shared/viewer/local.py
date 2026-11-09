from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import mimetypes
from pathlib import Path
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
from urllib.parse import parse_qs, urlsplit
import webbrowser

from viewer.decoder import (
    DecodeError,
    PACKET_MAGIC,
    TIMELINE_MAGIC,
    RecordingIndex,
    build_index,
    query_signals,
    stream_label,
    stream_sample_rate_hz,
    stream_unit,
)

STATIC_ROOT = Path(__file__).resolve().parent
RECORDING_ID = "local"


def _file_magic(path: Path, size: int = 8) -> bytes:
    try:
        with path.open("rb") as source:
            return source.read(size)
    except OSError:
        return b""


def _binary_candidates(root: Path) -> list[Path]:
    if root.is_file():
        return [root.resolve()]
    if not root.is_dir():
        return []
    return sorted(
        (path.resolve() for path in root.rglob("*.bin") if path.is_file()),
        key=lambda path: (len(path.parts), str(path).casefold()),
    )


def discover_recording_files(
    source: Path,
    *,
    packets: Path | None = None,
    timeline: Path | None = None,
) -> tuple[Path, Path | None]:
    source = source.expanduser().resolve()
    packet_path = packets.expanduser().resolve() if packets else None
    timeline_path = timeline.expanduser().resolve() if timeline else None

    if packet_path is not None:
        if not packet_path.is_file():
            raise FileNotFoundError(f"Packet file not found: {packet_path}")
        if _file_magic(packet_path, len(PACKET_MAGIC)) != PACKET_MAGIC:
            raise DecodeError(f"Not a packets.bin-compatible file: {packet_path}")
    else:
        candidates = _binary_candidates(source)
        packet_candidates = [
            path for path in candidates
            if _file_magic(path, len(PACKET_MAGIC)) == PACKET_MAGIC
        ]
        if not packet_candidates:
            raise FileNotFoundError(
                f"No packet binary found under {source}. "
                "Expected packets.bin or a content*.bin starting with 33 99 AA 55."
            )
        exact = [path for path in packet_candidates if path.name.casefold() == "packets.bin"]
        packet_path = (exact or sorted(packet_candidates, key=lambda path: path.stat().st_size, reverse=True))[0]

    if timeline_path is not None:
        if not timeline_path.is_file():
            raise FileNotFoundError(f"Timeline file not found: {timeline_path}")
        if _file_magic(timeline_path, len(TIMELINE_MAGIC)) != TIMELINE_MAGIC:
            raise DecodeError(f"Not a packet_timeline.bin-compatible file: {timeline_path}")
    else:
        roots = [source] if source.is_dir() else [packet_path.parent]
        candidates: list[Path] = []
        seen: set[Path] = set()
        for root in roots:
            for path in _binary_candidates(root):
                if path in seen:
                    continue
                seen.add(path)
                if _file_magic(path, len(TIMELINE_MAGIC)) == TIMELINE_MAGIC:
                    candidates.append(path)
        if candidates:
            exact = [path for path in candidates if path.name.casefold() == "packet_timeline.bin"]
            if exact:
                timeline_path = exact[0]
            else:
                # Prefer a downloaded sibling of the packet file, then shortest path.
                candidates.sort(
                    key=lambda path: (
                        path.parent != packet_path.parent,
                        len(path.parts),
                        str(path).casefold(),
                    )
                )
                timeline_path = candidates[0]

    return packet_path, timeline_path


def _parse_streams(value: str | None) -> set[tuple[int, int]] | None:
    if value is None or not value.strip():
        return None
    result: set[tuple[int, int]] = set()
    for item in value.split(","):
        parts = item.strip().split(":")
        if len(parts) != 2:
            raise ValueError(f"Invalid stream key: {item}")
        sensor_type, channel = (int(part) for part in parts)
        if not 0 <= sensor_type <= 255 or not 1 <= channel <= 255:
            raise ValueError(f"Invalid stream key: {item}")
        result.add((sensor_type, channel))
    return result


def _recording_label(packet_path: Path, source: Path) -> str:
    if source.is_dir() and source.name:
        return source.name
    if packet_path.parent.name:
        return packet_path.parent.name
    return packet_path.stem


class LocalViewerState:
    def __init__(self, source: Path, packet_path: Path, timeline_path: Path | None):
        self.source = source
        self.packet_path = packet_path
        self.timeline_path = timeline_path
        self.index = build_index(packet_path, timeline_path)
        self.label = _recording_label(packet_path, source)
        self.started_at = datetime.fromtimestamp(
            packet_path.stat().st_mtime,
            tz=timezone.utc,
        ).isoformat()

    def recording_list(self) -> dict:
        return {
            "recordings": [{
                "id": RECORDING_ID,
                "dog": "Local",
                "sessionLabel": self.label,
                "startedAtUtc": self.started_at,
                "captureStatus": "local",
                "ingestStatus": "local",
                "hasTimeline": self.timeline_path is not None,
                "hasVideo": False,
            }]
        }

    def meta(self) -> dict:
        index = self.index
        return {
            "id": RECORDING_ID,
            "dog": "Local",
            "sessionLabel": self.label,
            "startedAtUtc": self.started_at,
            "captureStatus": "local",
            "ingestStatus": "local",
            "durationMs": index.duration_ms,
            "timeBase": index.time_base,
            "packetCount": len(index.entries),
            "gapCount": len(index.gaps),
            "video": {"available": False},
            "streams": [
                {
                    "key": f"{sensor_type}:{channel}",
                    "sensorType": sensor_type,
                    "channel": channel,
                    "label": stream_label(sensor_type, channel),
                    "sampleRateHz": stream_sample_rate_hz(sensor_type),
                    "unit": stream_unit(sensor_type),
                }
                for sensor_type, channel in index.streams
            ],
        }


class LocalViewerServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], state: LocalViewerState):
        self.state = state
        super().__init__(address, LocalViewerHandler)


class LocalViewerHandler(BaseHTTPRequestHandler):
    server: LocalViewerServer

    def log_message(self, format: str, *args) -> None:
        # Keep the terminal useful: report failures, not every graph refresh.
        if args and str(args[1]).startswith(("4", "5")):
            super().log_message(format, *args)

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_static(self, name: str) -> None:
        path = STATIC_ROOT / name
        if not path.is_file():
            self._send_json(404, {"detail": "Not found"})
            return
        body = path.read_bytes()
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        request = urlsplit(self.path)
        path = request.path
        try:
            if path in ("/", "/index.html"):
                self._send_static("index.html")
                return
            if path == "/viewer.css":
                self._send_static("viewer.css")
                return
            if path == "/viewer.js":
                self._send_static("viewer.js")
                return
            if path == "/favicon.ico":
                self.send_response(204)
                self.end_headers()
                return
            if path == "/api/recordings":
                self._send_json(200, self.server.state.recording_list())
                return
            if path == f"/api/recordings/{RECORDING_ID}/meta":
                self._send_json(200, self.server.state.meta())
                return
            if path == f"/api/recordings/{RECORDING_ID}/signals":
                query = parse_qs(request.query)
                start_ms = float(query.get("from_ms", ["0"])[0])
                end_raw = query.get("to_ms", [None])[0]
                end_ms = (
                    self.server.state.index.duration_ms
                    if end_raw in (None, "")
                    else float(end_raw)
                )
                max_points = int(query.get("max_points", ["3000"])[0])
                if not 200 <= max_points <= 10_000:
                    raise ValueError("max_points must be between 200 and 10000")
                selected = _parse_streams(query.get("streams", [None])[0])
                result = query_signals(
                    self.server.state.index,
                    start_ms=start_ms,
                    end_ms=end_ms,
                    selected_streams=selected,
                    max_points=max_points,
                )
                self._send_json(200, result)
                return
            self._send_json(404, {"detail": "Not found"})
        except (ValueError, OverflowError) as error:
            self._send_json(422, {"detail": str(error)})
        except DecodeError as error:
            self._send_json(409, {"detail": str(error)})
        except OSError as error:
            self._send_json(500, {"detail": f"File read failed: {error}"})


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Local read-only Woona signal viewer. No Docker/FastAPI/database required.",
    )
    parser.add_argument(
        "source",
        nargs="?",
        default=".",
        help="Recording/download directory to scan recursively (default: current directory).",
    )
    parser.add_argument("--packets", type=Path, help="Explicit packets.bin/content*.bin path.")
    parser.add_argument("--timeline", type=Path, help="Explicit packet_timeline.bin/content*.bin path.")
    parser.add_argument("--host", default="127.0.0.1", help="Listen address (default: 127.0.0.1).")
    parser.add_argument("--port", type=int, default=8090, help="Listen port (default: 8090).")
    parser.add_argument("--no-browser", action="store_true", help="Do not open the browser automatically.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_argument_parser().parse_args(argv)
    source = Path(args.source).expanduser().resolve()

    try:
        packet_path, timeline_path = discover_recording_files(
            source,
            packets=args.packets,
            timeline=args.timeline,
        )
        print(f"[viewer] packets : {packet_path}")
        print(f"[viewer] timeline: {timeline_path if timeline_path else '(not found; optional)'}")
        print("[viewer] indexing recording...")
        state = LocalViewerState(source, packet_path, timeline_path)
    except (OSError, DecodeError, ValueError) as error:
        print(f"[viewer] ERROR: {error}")
        return 2

    try:
        server = LocalViewerServer((args.host, args.port), state)
    except OSError as error:
        print(f"[viewer] ERROR: cannot listen on {args.host}:{args.port}: {error}")
        return 3

    url = f"http://{args.host}:{server.server_address[1]}/"
    print(
        f"[viewer] ready: {len(state.index.entries)} packets, "
        f"{len(state.index.streams)} streams, {state.index.duration_ms / 1000.0:.3f} s"
    )
    print(f"[viewer] open: {url}")
    print("[viewer] Ctrl+C to stop")

    if not args.no_browser:
        threading.Timer(0.25, lambda: webbrowser.open(url)).start()

    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        print("\n[viewer] stopped")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
