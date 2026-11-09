from __future__ import annotations

from functools import lru_cache
import json
import os
from pathlib import Path
import stat
import uuid
from urllib.error import HTTPError, URLError
from urllib.request import Request as UrlRequest, urlopen

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse
from sqlalchemy import create_engine, text
from starlette.concurrency import run_in_threadpool

from viewer.http_range import parse_byte_range
from viewer.decoder import (
    DecodeError,
    RecordingIndex,
    build_index,
    query_signals,
    stream_label,
    stream_sample_rate_hz,
    stream_unit,
)

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql+psycopg://woona:woona-local-only@127.0.0.1:5432/woona",
)
STORAGE_ROOT = Path(os.getenv("WOONA_STORAGE_ROOT", "../var/storage")).resolve()
ENVIRONMENT = os.getenv("WOONA_ENVIRONMENT", "development").lower()
LABEL_STUDIO_URL = os.getenv("LABEL_STUDIO_URL", "")
LABEL_STUDIO_HOST_HEADER = os.getenv("LABEL_STUDIO_HOST_HEADER", "cool-trams.digital")
FILEBROWSER_URL = os.getenv("FILEBROWSER_URL", "")
FILEBROWSER_HOST_HEADER = os.getenv("FILEBROWSER_HOST_HEADER", "cool-trams.digital")
STATIC_ROOT = Path(__file__).resolve().parent

engine = create_engine(DATABASE_URL, pool_pre_ping=True)
app = FastAPI(title="Woona Signal Viewer", version="0.1.0")


def _label_studio_authorized(cookie: str) -> bool:
    if not LABEL_STUDIO_URL:
        return False
    check = UrlRequest(
        LABEL_STUDIO_URL.rstrip("/") + "/api/current-user/whoami",
        headers={"Cookie": cookie, "Host": LABEL_STUDIO_HOST_HEADER},
    )
    with urlopen(check, timeout=5) as response:
        user = json.load(response)
    return "projects.view" in user.get("permissions", [])


def _filebrowser_authorized(cookie: str) -> bool:
    if not FILEBROWSER_URL:
        return False
    check = UrlRequest(
        FILEBROWSER_URL.rstrip("/") + "/api/users?username=self",
        headers={"Cookie": cookie, "Host": FILEBROWSER_HOST_HEADER},
    )
    with urlopen(check, timeout=5) as response:
        body = json.load(response)
    # The endpoint may return either one user object or a collection depending
    # on FileBrowser version. A successful authenticated response with JSON is
    # sufficient; anonymous/expired sessions return 401/403 before this point.
    return isinstance(body, (dict, list))


def require_viewer_user(request: Request) -> None:
    if not LABEL_STUDIO_URL and not FILEBROWSER_URL:
        if ENVIRONMENT != "production":
            return
        raise HTTPException(503, "Viewer authentication is not configured")

    cookie = request.headers.get("cookie", "")
    if not cookie:
        raise HTTPException(401, "Sign in to Woona server tools first")

    unavailable = False
    for checker in (_filebrowser_authorized, _label_studio_authorized):
        try:
            if checker(cookie):
                return
        except HTTPError as error:
            if error.code not in (401, 403):
                unavailable = True
        except (URLError, ValueError, TimeoutError):
            unavailable = True

    if unavailable:
        raise HTTPException(503, "Viewer authentication service unavailable")
    raise HTTPException(401, "Viewer session is not authorized")


def _readonly_rows(query: str, parameters: dict | None = None):
    with engine.begin() as connection:
        connection.execute(text("SET TRANSACTION READ ONLY"))
        return connection.execute(text(query), parameters or {}).mappings().all()


def _safe_artifact_path(relative: str | None) -> Path | None:
    if not relative:
        return None
    candidate = (STORAGE_ROOT / relative).resolve()
    if candidate == STORAGE_ROOT or STORAGE_ROOT not in candidate.parents:
        raise HTTPException(409, "Artifact path escapes storage root")
    try:
        info = candidate.stat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode):
        return None
    return candidate


def _artifact_rows(recording_id: uuid.UUID, artifact_types: tuple[str, ...]):
    placeholders = ",".join(f":type_{index}" for index in range(len(artifact_types)))
    parameters = {"id": recording_id}
    parameters.update({f"type_{index}": value for index, value in enumerate(artifact_types)})
    return _readonly_rows(
        f"""
        SELECT id, artifact_type, file_name, mime_type, expected_size_bytes,
               server_relative_path, storage_status
        FROM artifacts
        WHERE recording_id=:id
          AND artifact_type IN ({placeholders})
        ORDER BY artifact_type
        """,
        parameters,
    )


def _artifact_paths(recording_id: uuid.UUID) -> tuple[Path, Path | None]:
    rows = _artifact_rows(recording_id, ("packet", "packet_timeline"))
    by_type = {
        row["artifact_type"]: _safe_artifact_path(row["server_relative_path"])
        for row in rows
        if row["storage_status"] == "available"
    }
    packet = by_type.get("packet")
    if packet is None:
        raise HTTPException(404, "Verified packet artifact is not available")
    return packet, by_type.get("packet_timeline")


@lru_cache(maxsize=24)
def _cached_index(
    packet_name: str,
    packet_size: int,
    packet_mtime_ns: int,
    timeline_name: str | None,
    timeline_size: int | None,
    timeline_mtime_ns: int | None,
) -> RecordingIndex:
    del packet_size, packet_mtime_ns, timeline_size, timeline_mtime_ns
    return build_index(
        Path(packet_name),
        Path(timeline_name) if timeline_name else None,
    )


def _index_for(recording_id: uuid.UUID) -> RecordingIndex:
    packet, timeline = _artifact_paths(recording_id)
    packet_stat = packet.stat()
    timeline_stat = timeline.stat() if timeline else None
    return _cached_index(
        str(packet),
        packet_stat.st_size,
        packet_stat.st_mtime_ns,
        str(timeline) if timeline else None,
        timeline_stat.st_size if timeline_stat else None,
        timeline_stat.st_mtime_ns if timeline_stat else None,
    )


def _parse_streams(value: str | None) -> set[tuple[int, int]] | None:
    if value is None or not value.strip():
        return None
    result: set[tuple[int, int]] = set()
    for item in value.split(","):
        parts = item.strip().split(":")
        if len(parts) != 2:
            raise HTTPException(422, f"Invalid stream key: {item}")
        try:
            sensor_type, channel = int(parts[0]), int(parts[1])
        except ValueError as error:
            raise HTTPException(422, f"Invalid stream key: {item}") from error
        if not 0 <= sensor_type <= 255 or not 1 <= channel <= 255:
            raise HTTPException(422, f"Invalid stream key: {item}")
        result.add((sensor_type, channel))
    return result


@app.exception_handler(DecodeError)
async def decode_error(_: Request, exception: DecodeError) -> JSONResponse:
    return JSONResponse(
        status_code=409,
        content={"code": "recording_data_invalid", "detail": str(exception)},
    )


@app.get("/health/ready")
def health_ready():
    return {"status": "ok"}


@app.get("/", dependencies=[Depends(require_viewer_user)])
def viewer_page():
    return FileResponse(STATIC_ROOT / "index.html", media_type="text/html")


@app.get("/viewer.css")
def viewer_css():
    return FileResponse(STATIC_ROOT / "viewer.css", media_type="text/css")


@app.get("/viewer.js")
def viewer_js():
    return FileResponse(STATIC_ROOT / "viewer.js", media_type="text/javascript")


@app.get("/api/recordings", dependencies=[Depends(require_viewer_user)])
def recordings(limit: int = Query(default=250, ge=1, le=1000)):
    rows = _readonly_rows(
        """
        SELECT r.id, r.started_at, r.session_label, r.capture_status, r.ingest_status,
               d.number_or_name AS dog,
               bool_or(a.artifact_type='packet' AND a.storage_status='available') AS has_packets,
               bool_or(a.artifact_type='packet_timeline' AND a.storage_status='available') AS has_timeline,
               bool_or(a.artifact_type='video' AND a.storage_status='available') AS has_video
        FROM recordings r
        JOIN dogs d ON d.id=r.dog_id
        LEFT JOIN artifacts a ON a.recording_id=r.id
        GROUP BY r.id, r.started_at, r.session_label, r.capture_status, r.ingest_status, d.number_or_name
        HAVING bool_or(a.artifact_type='packet' AND a.storage_status='available')
        ORDER BY r.started_at DESC
        LIMIT :limit
        """,
        {"limit": limit},
    )
    return {
        "recordings": [
            {
                "id": str(row["id"]),
                "dog": row["dog"],
                "sessionLabel": row["session_label"],
                "startedAtUtc": row["started_at"].isoformat(),
                "captureStatus": row["capture_status"],
                "ingestStatus": row["ingest_status"],
                "hasTimeline": bool(row["has_timeline"]),
                "hasVideo": bool(row["has_video"]),
            }
            for row in rows
        ]
    }


@app.get("/api/recordings/{recording_id}/meta", dependencies=[Depends(require_viewer_user)])
async def recording_meta(recording_id: uuid.UUID):
    index = await run_in_threadpool(_index_for, recording_id)
    rows = _readonly_rows(
        """
        SELECT r.started_at, r.session_label, r.capture_status, r.ingest_status, d.number_or_name AS dog,
               s.video_offset_from_sensor_ns, s.video_first_sample_pts_us,
               s.overall_sync_quality, s.camera_clock_quality
        FROM recordings r
        JOIN dogs d ON d.id=r.dog_id
        LEFT JOIN recording_sync s ON s.recording_id=r.id
        WHERE r.id=:id
        """,
        {"id": recording_id},
    )
    if not rows:
        raise HTTPException(404, "Recording not found")
    row = rows[0]
    return {
        "id": str(recording_id),
        "dog": row["dog"],
        "sessionLabel": row["session_label"],
        "startedAtUtc": row["started_at"].isoformat(),
        "captureStatus": row["capture_status"],
        "ingestStatus": row["ingest_status"],
        "durationMs": index.duration_ms,
        "timeBase": index.time_base,
        "packetCount": len(index.entries),
        "gapCount": len(index.gaps),
        "video": {
            "available": any(
                row["storage_status"] == "available"
                and _safe_artifact_path(row["server_relative_path"]) is not None
                for row in _artifact_rows(recording_id, ("video",))
            ),
            "offsetFromSensorMs": (
                row["video_offset_from_sensor_ns"] / 1_000_000.0
                if row["video_offset_from_sensor_ns"] is not None
                else None
            ),
            "firstSamplePtsUs": row["video_first_sample_pts_us"],
            "syncQuality": row["overall_sync_quality"],
            "cameraClockQuality": row["camera_clock_quality"],
        },
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


@app.get("/api/recordings/{recording_id}/signals", dependencies=[Depends(require_viewer_user)])
async def signals(
    recording_id: uuid.UUID,
    from_ms: float = Query(default=0.0, ge=0.0),
    to_ms: float | None = Query(default=None, ge=0.0),
    streams: str | None = Query(default=None),
    max_points: int = Query(default=3000, ge=200, le=10_000),
):
    selected = _parse_streams(streams)
    index = await run_in_threadpool(_index_for, recording_id)
    end_ms = index.duration_ms if to_ms is None else min(to_ms, index.duration_ms)
    if end_ms < from_ms:
        raise HTTPException(422, "to_ms must be greater than from_ms")
    return await run_in_threadpool(
        query_signals,
        index,
        start_ms=from_ms,
        end_ms=end_ms,
        selected_streams=selected,
        max_points=max_points,
    )



def _stream_file(path: Path, start: int, length: int):
    with path.open("rb") as source:
        source.seek(start)
        remaining = length
        while remaining > 0:
            chunk = source.read(min(1024 * 1024, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
            yield chunk


@app.get("/api/recordings/{recording_id}/video", dependencies=[Depends(require_viewer_user)])
def recording_video(recording_id: uuid.UUID, request: Request):
    rows = _artifact_rows(recording_id, ("video",))
    row = next(
        (
            item
            for item in rows
            if item["storage_status"] == "available"
            and item["server_relative_path"]
        ),
        None,
    )
    if row is None:
        raise HTTPException(404, "Verified video artifact is not available")

    path = _safe_artifact_path(row["server_relative_path"])
    if path is None:
        raise HTTPException(404, "Verified video artifact is not available")

    size = path.stat().st_size
    expected = int(row["expected_size_bytes"])
    if size != expected:
        raise HTTPException(409, "Video file size does not match database metadata")

    headers = {
        "Accept-Ranges": "bytes",
        "Cache-Control": "private, max-age=0",
    }
    range_header = request.headers.get("range")
    if not range_header:
        return FileResponse(
            path,
            media_type=row["mime_type"] or "video/mp4",
            filename=row["file_name"] or "video.mp4",
            headers=headers,
        )

    try:
        start, end = parse_byte_range(range_header, size)
    except ValueError as error:
        raise HTTPException(
            416,
            "Range not satisfiable",
            headers={"Content-Range": f"bytes */{size}"},
        ) from error
    length = end - start + 1
    headers.update(
        {
            "Content-Range": f"bytes {start}-{end}/{size}",
            "Content-Length": str(length),
        }
    )
    return StreamingResponse(
        _stream_file(path, start, length),
        status_code=206,
        media_type=row["mime_type"] or "video/mp4",
        headers=headers,
    )
