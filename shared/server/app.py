from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import threading
import tempfile
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated, Any, Literal

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from jsonschema import Draft202012Validator, ValidationError as SchemaValidationError
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Connection
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.types import ASGIApp, Message, Receive, Scope, Send

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql+psycopg://woona:woona-local-only@127.0.0.1:5432/woona",
)
STORAGE_ROOT = Path(os.getenv("WOONA_STORAGE_ROOT", "../var/storage")).resolve()
DEVICE_ID = uuid.UUID(
    os.getenv("WOONA_DEVICE_ID", "00000000-0000-0000-0000-000000000001")
)
DEVICE_LABEL = os.getenv("WOONA_DEVICE_LABEL", "Local device")
DEBUG_TOKEN = os.getenv("WOONA_DEBUG_TOKEN", "change-me-local-token")
ALLOW_LEGACY_MIGRATION = os.getenv("WOONA_ALLOW_LEGACY_MIGRATION", "false").lower() == "true"
MAX_CHUNK_BYTES = 16 * 1024 * 1024
MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_ARTIFACT_BYTES = 100 * 1024 * 1024 * 1024
HEX_64 = re.compile(r"^[0-9a-f]{64}$")
ARTIFACT_RULES = {
    "packet": ({".bin"}, {"application/octet-stream"}),
    "packet_timeline": ({".bin"}, {"application/octet-stream"}),
    "raw": ({".binlog"}, {"application/octet-stream"}),
    "diagnostic": ({".log"}, {"text/plain", "application/octet-stream"}),
    "csv": ({".csv"}, {"text/csv"}),
    "video": ({".mp4"}, {"video/mp4"}),
    "sync": ({".json"}, {"application/json"}),
    "imported_source": ({".bin", ".binlog"}, {"application/octet-stream"}),
    **{kind: ({".csv", ".json", ".txt", ".edf", ".bdf", ".dat", ".bin", ".zip", ".pdf"},
              {"application/octet-stream", "text/csv", "application/json", "text/plain", "application/pdf", "application/zip"})
       for kind in ("ecg", "heart_rate", "rr")},
}

engine = create_engine(DATABASE_URL, pool_pre_ping=True)
artifact_locks: dict[uuid.UUID, threading.Lock] = {}
artifact_locks_guard = threading.Lock()
logger = logging.getLogger("woona.api")


def utc_isoformat(value: datetime) -> str:
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def load_validator(env_name: str, default_path: str) -> Draft202012Validator:
    path = Path(os.getenv(env_name, default_path))
    schema = json.loads(path.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema)


dog_validator: Draft202012Validator | None = None
session_validator: Draft202012Validator | None = None


class StrictModel(BaseModel):
    model_config = ConfigDict(
        extra="forbid", populate_by_name=True, str_strip_whitespace=True
    )


class DogPayload(StrictModel):
    id: uuid.UUID
    number_or_name: str = Field(alias="numberOrName", min_length=1, max_length=100)
    expected_revision: int = Field(alias="expectedRevision", ge=0)


class ProfileVersionPayload(StrictModel):
    id: uuid.UUID
    schema_version: int = Field(alias="schemaVersion", ge=1)
    validation_state: Literal["complete", "legacy_incomplete"] = Field(
        alias="validationState"
    )
    questionnaire: dict[str, Any]
    content_sha256: str = Field(alias="contentSha256")
    client_created_at_utc: datetime = Field(alias="clientCreatedAtUtc")

    @field_validator("content_sha256")
    @classmethod
    def valid_hash(cls, value: str) -> str:
        if not HEX_64.fullmatch(value):
            raise ValueError("must be lowercase SHA-256")
        return value


class ProfilePut(StrictModel):
    dog: DogPayload
    profile_version: ProfileVersionPayload = Field(alias="profileVersion")


class AccountAssignment(StrictModel):
    account_id: str = Field(alias="accountId")


class QuestionnaireEdit(StrictModel):
    expected_revision: int = Field(alias="expectedRevision", ge=1)
    questionnaire: dict[str, Any]


class RecordingPayload(StrictModel):
    source: Literal["live", "replay"]
    capture_status: Literal["completed", "failed", "interrupted"] = Field(
        alias="captureStatus"
    )
    started_at_utc: datetime = Field(alias="startedAtUtc")
    ended_at_utc: datetime | None = Field(alias="endedAtUtc")
    timezone: str = Field(min_length=1, max_length=100)
    session_label: str = Field(alias="sessionLabel", min_length=1, max_length=100)
    video_requested: bool = Field(alias="videoRequested")
    sensor_hardware_id: str | None = Field(alias="sensorHardwareId", default=None)
    app_version: str = Field(alias="appVersion", min_length=1, max_length=100)
    protocol_version: str | None = Field(alias="protocolVersion", default=None)
    questionnaire_schema_version: int = Field(
        alias="questionnaireSchemaVersion", ge=1
    )
    questionnaire_validation_state: Literal["complete", "legacy_incomplete"] = Field(
        alias="questionnaireValidationState"
    )
    session_questionnaire: dict[str, Any] = Field(alias="sessionQuestionnaire")
    capture_error_code: str | None = Field(alias="captureErrorCode", default=None)
    capture_error_message: str | None = Field(
        alias="captureErrorMessage", default=None
    )


class SyncPayload(StrictModel):
    schema_version: int = Field(alias="schemaVersion", ge=1)
    monotonic_clock: Literal[
        "android.elapsedRealtimeNanos", "ios.CMClock.hostTime"
    ] = Field(
        alias="monotonicClock"
    )
    session_zero_at_utc: datetime = Field(alias="sessionZeroAtUtc")
    session_zero_wall_clock_ms: int = Field(alias="sessionZeroWallClockMs", ge=0)
    session_zero_monotonic_ns: int = Field(alias="sessionZeroMonotonicNs", ge=0)
    session_zero_uncertainty_ns: int = Field(
        alias="sessionZeroUncertaintyNs", ge=0
    )
    first_sensor_packet_monotonic_ns: int | None = Field(
        alias="firstSensorPacketMonotonicNs", default=None, ge=0
    )
    first_sensor_device_timer_ms: int | None = Field(
        alias="firstSensorDeviceTimerMs", default=None, ge=0
    )
    last_sensor_packet_monotonic_ns: int | None = Field(
        alias="lastSensorPacketMonotonicNs", default=None, ge=0
    )
    video_requested_monotonic_ns: int | None = Field(
        alias="videoRequestedMonotonicNs", default=None, ge=0
    )
    media_recorder_started_monotonic_ns: int | None = Field(
        alias="mediaRecorderStartedMonotonicNs", default=None, ge=0
    )
    video_first_frame_monotonic_ns: int | None = Field(
        alias="videoFirstFrameMonotonicNs", default=None, ge=0
    )
    video_first_frame_camera_timestamp_ns: int | None = Field(
        alias="videoFirstFrameCameraTimestampNs", default=None, ge=0
    )
    video_first_frame_callback_monotonic_ns: int | None = Field(
        alias="videoFirstFrameCallbackMonotonicNs", default=None, ge=0
    )
    video_first_sample_pts_us: int | None = Field(
        alias="videoFirstSamplePtsUs", default=None, ge=0
    )
    video_offset_from_sensor_ns: int | None = Field(
        alias="videoOffsetFromSensorNs", default=None
    )
    camera_timestamp_source: Literal[
        "realtime", "avfoundation_session_clock", "unknown"
    ] | None = Field(
        alias="cameraTimestampSource", default=None
    )
    camera_clock_quality: Literal[
        "hardware_monotonic", "callback_estimate", "unavailable"
    ] = Field(alias="cameraClockQuality")
    sensor_clock_quality: Literal[
        "first_packet_arrival", "device_timer_mapped", "calibrated", "unavailable"
    ] = Field(alias="sensorClockQuality")
    overall_sync_quality: Literal[
        "arrival_aligned", "callback_estimate", "degraded", "unavailable"
    ] = Field(alias="overallSyncQuality")
    calibration_offset_ns: int = Field(alias="calibrationOffsetNs", default=0)
    estimated_drift_ppm: float | None = Field(
        alias="estimatedDriftPpm", default=None
    )

    @model_validator(mode="after")
    def consistent_anchors(self):
        if self.overall_sync_quality in {"arrival_aligned", "callback_estimate"}:
            if self.first_sensor_packet_monotonic_ns is None or self.video_first_frame_monotonic_ns is None:
                raise ValueError("Aligned capture requires sensor and camera anchors")
            if self.video_offset_from_sensor_ns != self.video_first_frame_monotonic_ns - self.first_sensor_packet_monotonic_ns:
                raise ValueError("Video offset does not match monotonic anchors")
        if self.camera_clock_quality == "hardware_monotonic" and (
            not self.video_first_frame_monotonic_ns or self.camera_timestamp_source not in {"realtime", "avfoundation_session_clock"}
        ):
            raise ValueError("Hardware camera clock requires a comparable timestamp source")
        return self


class ReferenceMetadata(StrictModel):
    source: str = Field(min_length=1, max_length=200)
    started_at_utc: datetime = Field(alias="startedAtUtc")
    ended_at_utc: datetime = Field(alias="endedAtUtc")
    offset_from_recording_ms: float | None = Field(alias="offsetFromRecordingMs", default=None, allow_inf_nan=False)
    notes: str | None = Field(default=None, max_length=2000)

    @field_validator("started_at_utc", "ended_at_utc")
    @classmethod
    def explicit_timezone(cls, value: datetime) -> datetime:
        if value.tzinfo is None:
            raise ValueError("include a timezone")
        return value


class ArtifactPayload(StrictModel):
    id: uuid.UUID
    type: Literal[
        "packet",
        "packet_timeline",
        "raw",
        "diagnostic",
        "csv",
        "video",
        "sync",
        "imported_source",
        "ecg", "heart_rate", "rr",
    ]
    file_name: str = Field(alias="fileName", min_length=1, max_length=255)
    mime_type: str = Field(alias="mimeType", min_length=1, max_length=150)
    size_bytes: int = Field(alias="sizeBytes", ge=0)
    sha256: str
    client_created_at_utc: datetime = Field(alias="clientCreatedAtUtc")
    reference_metadata: ReferenceMetadata | None = Field(alias="referenceMetadata", default=None)

    @field_validator("file_name")
    @classmethod
    def safe_name(cls, value: str) -> str:
        if (
            "/" in value
            or "\\" in value
            or "\x00" in value
            or "\r" in value
            or "\n" in value
            or value in {".", ".."}
        ):
            raise ValueError("path separators are not allowed")
        return value

    @field_validator("sha256")
    @classmethod
    def valid_hash(cls, value: str) -> str:
        if not HEX_64.fullmatch(value):
            raise ValueError("must be lowercase SHA-256")
        return value


class RecordingManifest(StrictModel):
    schema_version: int = Field(alias="schemaVersion", ge=1)
    capture_device_id: uuid.UUID = Field(alias="captureDeviceId")
    dog: DogPayload
    dog_profile_version: ProfileVersionPayload = Field(alias="dogProfileVersion")
    recording: RecordingPayload
    sync: SyncPayload
    artifacts: list[ArtifactPayload] = Field(min_length=1, max_length=32)


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def validate_questionnaire(
    validator: Draft202012Validator | None, questionnaire: dict[str, Any], name: str
) -> None:
    if questionnaire.get("schemaVersion") == 2:
        from server.questionnaires import validate_sheet
        try:
            validate_sheet(name, questionnaire)
        except (ValueError, SchemaValidationError) as error:
            raise HTTPException(422, detail={"code": f"invalid_{name}_questionnaire", "message": str(error).split("\n")[0]}) from error
        return
    if validator is None:
        raise HTTPException(503, detail={"code": "schema_not_ready"})
    errors = sorted(validator.iter_errors(questionnaire), key=lambda error: list(error.path))
    if errors:
        first = errors[0]
        path = ".".join(str(part) for part in first.path)
        raise HTTPException(
            422,
            detail={
                "code": f"invalid_{name}_questionnaire",
                "field": path,
                "message": first.message,
            },
        )


def token_hash() -> str:
    return sha256_bytes(DEBUG_TOKEN.encode("utf-8"))


def ensure_device() -> None:
    with engine.begin() as connection:
        connection.execute(
            text(
                """
                INSERT INTO client_devices(id,label,token_hash)
                VALUES(:id,:label,:hash)
                ON CONFLICT(id) DO UPDATE
                SET label=EXCLUDED.label, token_hash=EXCLUDED.token_hash
                """
            ),
            {"id": DEVICE_ID, "label": DEVICE_LABEL, "hash": token_hash()},
        )


@asynccontextmanager
async def lifespan(_: FastAPI):
    global dog_validator, session_validator
    STORAGE_ROOT.joinpath("incoming").mkdir(parents=True, exist_ok=True)
    STORAGE_ROOT.joinpath("recordings").mkdir(parents=True, exist_ok=True)
    dog_validator = load_validator(
        "WOONA_DOG_SCHEMA_PATH",
        "docs/target-server-plan/models/dog-questionnaire.schema.json",
    )
    session_validator = load_validator(
        "WOONA_SESSION_SCHEMA_PATH",
        "docs/target-server-plan/models/session-questionnaire.schema.json",
    )
    ensure_device()
    yield


class MetadataBodyLimitMiddleware:
    def __init__(self, app: ASGIApp):
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send):
        if scope["type"] != "http" or (
            scope["method"] == "PATCH"
            and re.fullmatch(r"/(?:v1|dashboard)/artifacts/[^/]+/content/?", scope["path"])
        ):
            return await self.app(scope, receive, send)
        request = Request(scope)
        length = request.headers.get("content-length", "")
        too_large = length.isdigit() and int(length) > MAX_JSON_BYTES
        body = bytearray()
        disconnected = False
        while not too_large:
            message = await receive()
            chunk = message.get("body", b"")
            too_large = len(body) + len(chunk) > MAX_JSON_BYTES
            if too_large:
                break
            body.extend(chunk)
            disconnected = message["type"] == "http.disconnect"
            if disconnected or not message.get("more_body", False):
                break
        if too_large:
            request_id = request.state.request_id
            return await JSONResponse(status_code=413, content={
                "requestId": request_id, "code": "json_body_too_large",
                **error_guidance("json_body_too_large", 413),
            }, headers={"X-Request-ID": request_id})(scope, receive, send)
        messages: list[Message] = [{"type": "http.request", "body": bytes(body), "more_body": disconnected}]
        if disconnected:
            messages.append({"type": "http.disconnect"})
        pending = iter(messages)

        async def replay() -> Message:
            return next(pending, None) or await receive()

        await self.app(scope, replay, send)


app = FastAPI(title="Woona API", version="1.0.0", lifespan=lifespan)
app.add_middleware(MetadataBodyLimitMiddleware)

from server.errors import error_guidance
from server.sync_status import recording_status
from server.dashboard import router as dashboard_router

app.include_router(dashboard_router)


@app.middleware("http")
async def request_id_middleware(request: Request, call_next):
    started = time.monotonic()
    supplied_id = request.headers.get("X-Request-ID", "")
    request_id = supplied_id if re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", supplied_id) else str(uuid.uuid4())
    request.state.request_id = request_id
    response = await call_next(request)
    response.headers["X-Request-ID"] = request_id
    logger.info(
        json.dumps(
            {
                "requestId": request_id,
                "method": request.method,
                "path": request.url.path,
                "status": response.status_code,
                "durationMs": round((time.monotonic() - started) * 1000, 2),
            },
            separators=(",", ":"),
        )
    )
    return response


@app.exception_handler(StarletteHTTPException)
async def http_error(request: Request, exception: StarletteHTTPException) -> JSONResponse:
    detail = exception.detail if isinstance(exception.detail, dict) else {}
    code = str(detail.get("code", "request_failed"))
    content = {
        "requestId": getattr(request.state, "request_id", ""),
        "code": code,
        **error_guidance(code, exception.status_code),
    }
    if isinstance(exception.detail, str) and exception.detail:
        content['detail'] = exception.detail
    content.update({key: value for key, value in detail.items() if key != "code"})
    return JSONResponse(
        status_code=exception.status_code,
        content=content,
        headers={**(exception.headers or {}), "X-Request-ID": content["requestId"]},
    )


@app.exception_handler(Exception)
async def unexpected_error(request: Request, exception: Exception) -> JSONResponse:
    request_id = getattr(request.state, "request_id", "")
    # Never return exception strings, SQL parameters, connection URLs or credentials.
    logger.error(json.dumps({"requestId": request_id, "event": "request_failed",
                             "exceptionType": type(exception).__name__}))
    return JSONResponse(status_code=500, content={"requestId": request_id,
        "code": "internal_server_error", **error_guidance("internal_server_error", 500)},
        headers={"X-Request-ID": request_id})


@app.exception_handler(RequestValidationError)
async def validation_error(
    request: Request, exception: RequestValidationError
) -> JSONResponse:
    fields = {
        ".".join(str(part) for part in error["loc"]): error["msg"]
        for error in exception.errors()
    }
    return JSONResponse(
        status_code=422,
        content={
            "requestId": getattr(request.state, "request_id", ""),
            "code": "request_invalid",
            **error_guidance("request_invalid", 422),
            "fieldErrors": fields,
        },
    )


def normalize_account(value: str) -> str:
    value = value.strip().lower()
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,63}", value, flags=re.ASCII):
        raise HTTPException(422, detail={"code": "invalid_account_identifier", "message": "Use 1–64 Latin letters, digits, dots, underscores or hyphens"})
    return value


def selected_account(request: Request) -> str | None:
    value = request.headers.get("X-Woona-Account")
    return normalize_account(value) if value is not None else None


def ensure_account(connection: Connection, identifier: str) -> None:
    connection.execute(text("INSERT INTO accounts(identifier) VALUES(:id) ON CONFLICT DO NOTHING"), {"id": identifier})


def assert_dog_account(connection: Connection, dog_id: uuid.UUID, account: str | None) -> None:
    row = connection.execute(text("SELECT account_id FROM dogs WHERE id=:id FOR UPDATE"), {"id": dog_id}).first()
    if row is not None and row.account_id != account:
        raise HTTPException(404, detail={"code": "dog_not_found"})


def authenticated_device(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> uuid.UUID:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, detail={"code": "missing_bearer_token"})
    supplied_hash = sha256_bytes(authorization.removeprefix("Bearer ").encode("utf-8"))
    with engine.begin() as connection:
        row = connection.execute(
            text(
                """
                UPDATE client_devices SET last_seen_at=now()
                WHERE token_hash=:hash AND revoked_at IS NULL
                RETURNING id
                """
            ),
            {"hash": supplied_hash},
        ).first()
    if row is None:
        raise HTTPException(401, detail={"code": "invalid_bearer_token"})
    account = selected_account(request)
    # Identifiers select a workspace; the existing device token still protects API access.
    resources = {
        "dog_id": "SELECT account_id FROM dogs WHERE id=:id",
        "recording_id": "SELECT d.account_id FROM recordings r JOIN dogs d ON d.id=r.dog_id WHERE r.id=:id",
        "artifact_id": "SELECT d.account_id FROM artifacts a JOIN recordings r ON r.id=a.recording_id JOIN dogs d ON d.id=r.dog_id WHERE a.id=:id",
    }
    if not (request.method == "PUT" and request.url.path.endswith("/account")):
        for parameter, query in resources.items():
            if parameter not in request.path_params:
                continue
            try:
                identity = uuid.UUID(str(request.path_params[parameter]))
            except ValueError:
                raise HTTPException(422, detail={"code": "invalid_resource_id"})
            with engine.connect() as connection:
                owner = connection.execute(text(query), {"id": identity}).first()
            if owner is not None and owner.account_id != account:
                raise HTTPException(404, detail={"code": "resource_not_found"})
    return row.id


@app.get("/health/live")
def live() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/health/ready")
def ready() -> dict[str, str]:
    try:
        with engine.connect() as connection:
            connection.execute(text("SELECT 1"))
    except Exception as exception:
        raise HTTPException(503, detail={"code": "database_unavailable"}) from exception
    try:
        # Concurrent readiness probes must not truncate or unlink each other's file.
        with tempfile.NamedTemporaryFile(prefix=".health-", dir=STORAGE_ROOT) as probe:
            probe.write(b"ok")
            probe.flush()
            probe.seek(0)
            if probe.read() != b"ok":
                raise OSError("storage probe mismatch")
    except Exception as exception:
        raise HTTPException(503, detail={"code": "storage_unavailable"}) from exception
    return {"status": "ready"}


def apply_profile(
    connection: Connection,
    dog: DogPayload,
    profile: ProfileVersionPayload,
    device_id: uuid.UUID,
    account: str | None = None,
) -> int:
    assert_dog_account(connection, dog.id, account)
    if account is not None:
        ensure_account(connection, account)
    ensure_not_retired(connection, "dog", dog.id)
    ensure_not_retired(connection, "profile", profile.id)
    if profile.schema_version != 2 and not ALLOW_LEGACY_MIGRATION:
        raise HTTPException(403,detail={"code":"legacy_migration_disabled"})
    existing_profile = connection.execute(
        text("SELECT dog_id,content_sha256,questionnaire FROM dog_profile_versions WHERE id=:id"),
        {"id": profile.id},
    ).mappings().first()
    # Android/iOS JSON encoders may write a received 27.0 as 27. An existing
    # immutable version is reusable only with its original hash and equal
    # validated answers; preserve the stored source representation and hash.
    same_existing = existing_profile is not None and (
        existing_profile["dog_id"] == dog.id
        and existing_profile["questionnaire"] == profile.questionnaire
    )
    content_hash = existing_profile["content_sha256"] if same_existing else sha256_bytes(canonical_json(profile.questionnaire))
    if profile.validation_state == "complete":
        if profile.schema_version != profile.questionnaire.get("schemaVersion"):
            raise HTTPException(422, detail={"code": "profile_schema_version_mismatch"})
        validate_questionnaire(dog_validator, profile.questionnaire, "dog")
    elif not ALLOW_LEGACY_MIGRATION:
        raise HTTPException(403, detail={"code": "legacy_migration_disabled"})
    if existing_profile is not None:
        if (
            existing_profile["dog_id"] != dog.id
            or not same_existing
        ):
            raise HTTPException(409, detail={"code": "immutable_profile_conflict"})
        revision = connection.execute(
            text("SELECT revision FROM dogs WHERE id=:id"), {"id": dog.id}
        ).scalar_one()
        return revision

    current_dog = connection.execute(
        text(
            "SELECT revision FROM dogs WHERE id=:id FOR UPDATE"
        ),
        {"id": dog.id},
    ).mappings().first()
    if current_dog is None:
        if dog.expected_revision != 0:
            raise HTTPException(
                409,
                detail={"code": "revision_conflict", "serverRevision": 0},
            )
        revision = 1
        connection.execute(
            text(
                """
                INSERT INTO dogs(id,number_or_name,revision,created_by_device_id,account_id)
                VALUES(:id,:name,:revision,:device,:account)
                """
            ),
            {
                "id": dog.id,
                "name": dog.number_or_name.strip(),
                "revision": revision,
                "device": device_id,
                "account": account,
            },
        )
    else:
        current_revision = current_dog["revision"]
        if current_revision != dog.expected_revision:
            raise HTTPException(
                409,
                detail={
                    "code": "revision_conflict",
                    "serverRevision": current_revision,
                },
            )
        revision = current_revision + 1
        connection.execute(
            text(
                """
                UPDATE dogs SET number_or_name=:name,revision=:revision,updated_at=now()
                WHERE id=:id
                """
            ),
            {
                "id": dog.id,
                "name": dog.number_or_name.strip(),
                "revision": revision,
            },
        )
        connection.execute(
            text(
                """
                UPDATE dog_profile_versions SET superseded_at=now()
                WHERE dog_id=:dog AND superseded_at IS NULL
                """
            ),
            {"dog": dog.id},
        )
    connection.execute(
        text(
            """
            INSERT INTO dog_profile_versions(
                id,dog_id,schema_version,validation_state,questionnaire,
                content_sha256,created_by_device_id,client_created_at
            ) VALUES(
                :id,:dog,:schema,:validation_state,CAST(:questionnaire AS jsonb),
                :hash,:device,:created
            )
            """
        ),
        {
            "id": profile.id,
            "dog": dog.id,
            "schema": profile.schema_version,
            "validation_state": profile.validation_state,
            "questionnaire": json.dumps(profile.questionnaire, ensure_ascii=False),
            "hash": content_hash,
            "device": device_id,
            "created": profile.client_created_at_utc,
        },
    )
    if profile.questionnaire.get("schemaVersion") == 2:
        external_id = profile.questionnaire["animalId"].strip().casefold()
        connection.execute(text("""
            INSERT INTO dog_external_ids(namespace,external_id,dog_id)
            VALUES('woona',:external,:dog) ON CONFLICT DO NOTHING
        """), {"external": external_id, "dog": dog.id})
        owner = connection.execute(text("SELECT dog_id FROM dog_external_ids WHERE namespace='woona' AND external_id=:external"),
                                   {"external": external_id}).scalar_one()
        if owner != dog.id:
            raise HTTPException(409, detail={"code": "animal_id_already_exists", "dogId": str(owner),
                                           "message": "Use the existing dog profile for this animal ID"})
    return revision


def ensure_not_retired(connection: Connection, kind: str, identity: uuid.UUID) -> None:
    retired = connection.execute(text(
        "SELECT 1 FROM retired_entities WHERE kind=:kind AND id_sha256=:hash"
    ), {"kind": kind, "hash": sha256_bytes(str(identity).encode())}).first()
    if retired:
        raise HTTPException(410, detail={"code": "entity_retired", "kind": kind})


@app.get("/v1/deletions")
def get_deletions(device_id: Annotated[uuid.UUID, Depends(authenticated_device)]) -> dict:
    with engine.connect() as connection:
        rows = connection.execute(text("SELECT kind,id_sha256 FROM retired_entities ORDER BY kind,id_sha256")).mappings()
        return {"entities": [dict(row) for row in rows]}


@app.put("/v1/dogs/{dog_id}/profile-versions/{profile_id}")
def put_profile(
    dog_id: uuid.UUID,
    profile_id: uuid.UUID,
    payload: ProfilePut,
    device_id: Annotated[uuid.UUID, Depends(authenticated_device)],
    account: Annotated[str | None, Depends(selected_account)] = None,
) -> dict[str, Any]:
    if dog_id != payload.dog.id or profile_id != payload.profile_version.id:
        raise HTTPException(422, detail={"code": "path_payload_id_mismatch"})
    with engine.begin() as connection:
        revision = apply_profile(
            connection, payload.dog, payload.profile_version, device_id, account
        )
        accepted = connection.execute(text("SELECT id,schema_version,validation_state,questionnaire,content_sha256,client_created_at FROM dog_profile_versions WHERE id=:id"), {"id": profile_id}).mappings().one()
    return {
        "dogId": str(dog_id),
        "dogRevision": revision,
        "currentProfileVersionId": str(profile_id),
        "serverTimestampUtc": utc_isoformat(datetime.now(timezone.utc)),
        "profileVersion": {
            "id": str(accepted["id"]), "schemaVersion": accepted["schema_version"],
            "validationState": accepted["validation_state"], "questionnaire": accepted["questionnaire"],
            "contentSha256": accepted["content_sha256"],
            "clientCreatedAtUtc": utc_isoformat(accepted["client_created_at"]),
        },
    }


def required_artifact_types(recording: RecordingPayload) -> set[str]:
    if (
        recording.capture_status != "completed"
        or recording.questionnaire_validation_state == "legacy_incomplete"
    ):
        return set()
    required = {"packet", "diagnostic", "sync"}
    if recording.source == "live":
        required.update({"raw", "packet_timeline"})
    if recording.video_requested and recording.capture_error_code is None:
        required.add("video")
    return required


REFERENCE_TYPES = {"ecg", "heart_rate", "rr"}


def validate_artifact(artifact: ArtifactPayload) -> None:
    suffixes, mime_types = ARTIFACT_RULES[artifact.type]
    if (artifact.type not in REFERENCE_TYPES and Path(artifact.file_name).suffix.lower() not in suffixes) or artifact.mime_type not in mime_types:
        raise HTTPException(422, detail={"code": "artifact_type_mismatch", "artifactId": str(artifact.id)})
    if artifact.size_bytes > MAX_ARTIFACT_BYTES:
        raise HTTPException(413, detail={"code": "artifact_too_large", "artifactId": str(artifact.id)})
    if artifact.type in REFERENCE_TYPES:
        if artifact.reference_metadata is None or artifact.size_bytes == 0:
            raise HTTPException(422, detail={"code": "reference_metadata_required"})
        if artifact.reference_metadata.ended_at_utc < artifact.reference_metadata.started_at_utc:
            raise HTTPException(422, detail={"code": "reference_ended_before_started"})
    elif artifact.reference_metadata is not None:
        raise HTTPException(422, detail={"code": "unexpected_reference_metadata"})


def insert_artifact(connection: Connection, recording_id: uuid.UUID, artifact: ArtifactPayload, uploader: uuid.UUID | None = None) -> None:
    ensure_not_retired(connection, "recording", recording_id)
    ensure_not_retired(connection, "artifact", artifact.id)
    connection.execute(text("""
        INSERT INTO artifacts(id,recording_id,artifact_type,file_name,mime_type,
            expected_size_bytes,sha256,storage_status,client_created_at,reference_metadata,uploaded_by_device_id)
        VALUES(:id,:recording,:type,:name,:mime,:size,:hash,'uploading',:created,CAST(:reference AS jsonb),:uploader)
    """), {"id": artifact.id, "recording": recording_id, "type": artifact.type,
        "name": artifact.file_name, "mime": artifact.mime_type, "size": artifact.size_bytes,
        "hash": artifact.sha256, "created": artifact.client_created_at_utc,
        "reference": artifact.reference_metadata.model_dump_json(by_alias=True) if artifact.reference_metadata else None, "uploader": uploader})


@app.post("/v1/recordings/{recording_id}/references")
def add_reference(recording_id: uuid.UUID, artifact: ArtifactPayload,
                  device_id: Annotated[uuid.UUID, Depends(authenticated_device)]) -> dict[str, str]:
    if artifact.type not in REFERENCE_TYPES:
        raise HTTPException(422, detail={"code": "reference_type_required"})
    validate_artifact(artifact)
    with engine.begin() as connection:
        ensure_not_retired(connection, "recording", recording_id)
        recording = connection.execute(text("SELECT capture_device_id FROM recordings WHERE id=:id FOR UPDATE"),
                                       {"id": recording_id}).mappings().first()
        if recording is None:
            raise HTTPException(404, detail={"code": "recording_not_found"})
        existing = connection.execute(text("SELECT * FROM artifacts WHERE id=:id OR (recording_id=:recording AND file_name=:name)"),
                                      {"id": artifact.id, "recording": recording_id, "name": artifact.file_name}).mappings().first()
        if existing:
            reference = json.loads(artifact.reference_metadata.model_dump_json(by_alias=True))
            if (existing["id"] != artifact.id or existing["recording_id"] != recording_id
                    or existing["artifact_type"] != artifact.type or existing["file_name"] != artifact.file_name
                    or existing["sha256"] != artifact.sha256 or existing["expected_size_bytes"] != artifact.size_bytes
                    or existing["reference_metadata"] != reference):
                raise HTTPException(409, detail={"code": "immutable_artifact_conflict"})
        else:
            insert_artifact(connection, recording_id, artifact, device_id)
    return {"recordingId": str(recording_id), "artifactId": str(artifact.id)}


@app.put("/v1/recordings/{recording_id}")
def put_recording(
    recording_id: uuid.UUID,
    manifest: RecordingManifest,
    device_id: Annotated[uuid.UUID, Depends(authenticated_device)],
    account: Annotated[str | None, Depends(selected_account)] = None,
) -> dict[str, Any]:
    if manifest.capture_device_id != device_id:
        raise HTTPException(403, detail={"code": "wrong_capture_device"})
    if manifest.recording.questionnaire_schema_version != 2 and not ALLOW_LEGACY_MIGRATION:
        raise HTTPException(403,detail={"code":"legacy_migration_disabled"})
    if manifest.recording.ended_at_utc is not None and (
        manifest.recording.ended_at_utc < manifest.recording.started_at_utc
    ):
        raise HTTPException(422, detail={"code": "ended_before_started"})
    if manifest.recording.questionnaire_validation_state == "complete":
        if manifest.recording.questionnaire_schema_version != manifest.recording.session_questionnaire.get("schemaVersion"):
            raise HTTPException(422, detail={"code": "session_schema_version_mismatch"})
        animal_id = manifest.recording.session_questionnaire.get("animalId")
        if animal_id and animal_id.strip().casefold() != str(manifest.dog_profile_version.questionnaire.get("animalId", "")).strip().casefold():
            raise HTTPException(422, detail={"code": "session_dog_mismatch"})
        validate_questionnaire(
            session_validator,
            manifest.recording.session_questionnaire,
            "session",
        )
    elif not ALLOW_LEGACY_MIGRATION:
        raise HTTPException(403, detail={"code": "legacy_migration_disabled"})
    missing = required_artifact_types(manifest.recording) - {
        artifact.type for artifact in manifest.artifacts
    }
    if missing:
        raise HTTPException(
            422,
            detail={"code": "missing_required_artifacts", "missing": sorted(missing)},
        )
    if len({artifact.id for artifact in manifest.artifacts}) != len(
        manifest.artifacts
    ):
        raise HTTPException(422, detail={"code": "duplicate_artifact_id"})
    if len({artifact.file_name for artifact in manifest.artifacts}) != len(
        manifest.artifacts
    ):
        raise HTTPException(422, detail={"code": "duplicate_artifact_name"})
    for artifact in manifest.artifacts:
        validate_artifact(artifact)

    with engine.begin() as connection:
        ensure_not_retired(connection, "recording", recording_id)
        existing = connection.execute(
            text(
                """
                SELECT dog_id,capture_device_id
                FROM recordings WHERE id=:id FOR UPDATE
                """
            ),
            {"id": recording_id},
        ).mappings().first()
        if existing is not None:
            if existing["capture_device_id"] != device_id:
                raise HTTPException(403, detail={"code": "recording_not_owned"})
            if existing["dog_id"] != manifest.dog.id:
                raise HTTPException(409, detail={"code": "immutable_recording_conflict"})
        revision = apply_profile(
            connection,
            manifest.dog,
            manifest.dog_profile_version,
            device_id,
            account,
        )
        if existing is None:
            recording = manifest.recording
            connection.execute(
                text(
                    """
                    INSERT INTO recordings(
                        id,dog_id,dog_profile_version_id,capture_device_id,source,
                        capture_status,ingest_status,started_at,ended_at,timezone,
                        session_label,questionnaire_schema_version,
                        questionnaire_validation_state,session_questionnaire,
                        video_requested,sensor_hardware_id,app_version,protocol_version,
                        capture_error_code,capture_error_message,client_created_at
                    ) VALUES(
                        :id,:dog,:profile,:device,:source,:capture,'uploading',
                        :started,:ended,:timezone,:label,:q_schema,:q_validation,
                        CAST(:questionnaire AS jsonb),:video,:sensor,:app,:protocol,
                        :error_code,:error_message,:created
                    )
                    """
                ),
                {
                    "id": recording_id,
                    "dog": manifest.dog.id,
                    "profile": manifest.dog_profile_version.id,
                    "device": device_id,
                    "source": recording.source,
                    "capture": recording.capture_status,
                    "started": recording.started_at_utc,
                    "ended": recording.ended_at_utc,
                    "timezone": recording.timezone,
                    "label": recording.session_label,
                    "q_schema": recording.questionnaire_schema_version,
                    "q_validation": recording.questionnaire_validation_state,
                    "questionnaire": json.dumps(
                        recording.session_questionnaire, ensure_ascii=False
                    ),
                    "video": recording.video_requested,
                    "sensor": recording.sensor_hardware_id,
                    "app": recording.app_version,
                    "protocol": recording.protocol_version,
                    "error_code": recording.capture_error_code,
                    "error_message": recording.capture_error_message,
                    "created": recording.started_at_utc,
                },
            )
            insert_sync(connection, recording_id, manifest.sync)
            for artifact in manifest.artifacts:
                insert_artifact(connection, recording_id, artifact)
        else:
            rows = connection.execute(
                text(
                    """
                    SELECT id,sha256,expected_size_bytes,stored_size_bytes,storage_status,reference_metadata,artifact_type,file_name
                    FROM artifacts WHERE recording_id=:recording
                    """
                ),
                {"recording": recording_id},
            ).mappings()
            existing_artifacts = {row["id"]: row for row in rows}
            for artifact in manifest.artifacts:
                row = existing_artifacts.get(artifact.id)
                if row is None and artifact.type in REFERENCE_TYPES:
                    conflict = connection.execute(text("SELECT id FROM artifacts WHERE id=:id OR (recording_id=:recording AND file_name=:name)"),
                        {"id": artifact.id, "recording": recording_id, "name": artifact.file_name}).first()
                    if conflict:
                        raise HTTPException(409, detail={"code": "immutable_artifact_conflict"})
                    insert_artifact(connection, recording_id, artifact)
                    continue
                if (
                    row is None
                    or row["sha256"] != artifact.sha256
                    or row["expected_size_bytes"] != artifact.size_bytes
                    or row["artifact_type"] != artifact.type
                    or row["file_name"] != artifact.file_name
                    or row["reference_metadata"] != (json.loads(artifact.reference_metadata.model_dump_json(by_alias=True)) if artifact.reference_metadata else None)
                ):
                    raise HTTPException(
                        409, detail={"code": "immutable_artifact_conflict"}
                    )
        result_rows = connection.execute(
            text(
                """
                SELECT id,storage_status,stored_size_bytes
                FROM artifacts WHERE recording_id=:recording ORDER BY id
                """
            ),
            {"recording": recording_id},
        ).mappings().all()
    return {
        "recordingId": str(recording_id),
        "ingestStatus": "uploading",
        "dogRevision": revision,
        "artifacts": [
            {
                "id": str(row["id"]),
                "storageStatus": row["storage_status"],
                "uploadOffset": row["stored_size_bytes"],
            }
            for row in result_rows
        ],
    }


def insert_sync(
    connection: Connection, recording_id: uuid.UUID, sync: SyncPayload
) -> None:
    values = sync.model_dump()
    values["recording_id"] = recording_id
    values["updated_at"] = datetime.now(timezone.utc)
    columns = ", ".join(values)
    parameters = ", ".join(f":{key}" for key in values)
    connection.execute(
        text(f"INSERT INTO recording_sync({columns}) VALUES({parameters})"),
        values,
    )


def artifact_row(
    connection: Connection, artifact_id: uuid.UUID, for_update: bool = False
):
    ensure_not_retired(connection, "artifact", artifact_id)
    suffix = " FOR UPDATE" if for_update else ""
    return connection.execute(
        text(
            """
            SELECT a.*,COALESCE(a.uploaded_by_device_id,r.capture_device_id) AS capture_device_id
            FROM artifacts a JOIN recordings r ON r.id=a.recording_id
            WHERE a.id=:id
            """
            + suffix
        ),
        {"id": artifact_id},
    ).mappings().first()


def assert_owner(row: Any, device_id: uuid.UUID) -> None:
    if row is None:
        raise HTTPException(404, detail={"code": "artifact_not_found"})
    if row["capture_device_id"] != device_id:
        raise HTTPException(403, detail={"code": "artifact_not_owned"})


def assert_artifact_exists(row: Any) -> None:
    if row is None:
        raise HTTPException(404, detail={"code": "artifact_not_found"})


def artifact_lock(artifact_id: uuid.UUID) -> threading.Lock:
    with artifact_locks_guard:
        return artifact_locks.setdefault(artifact_id, threading.Lock())


def incoming_path(artifact_id: uuid.UUID) -> Path:
    return STORAGE_ROOT / "incoming" / f"{artifact_id}.part"


@app.head("/v1/artifacts/{artifact_id}/content")
def head_artifact(
    artifact_id: uuid.UUID,
    device_id: Annotated[uuid.UUID, Depends(authenticated_device)],
) -> Response:
    with engine.connect() as connection:
        row = artifact_row(connection, artifact_id)
    assert_owner(row, device_id)
    offset = row["stored_size_bytes"]
    if row["storage_status"] != "available":
        try:
            offset = min(offset, incoming_path(artifact_id).stat().st_size)
        except FileNotFoundError:
            offset = 0
    return Response(
        headers={
            "Upload-Offset": str(offset),
            "Upload-Length": str(row["expected_size_bytes"]),
            "ETag": f'"{row["sha256"]}"',
        }
    )


@app.patch("/v1/artifacts/{artifact_id}/content", status_code=204)
async def patch_artifact(
    artifact_id: uuid.UUID,
    request: Request,
    device_id: Annotated[uuid.UUID, Depends(authenticated_device)],
    upload_offset: Annotated[int, Header(alias="Upload-Offset", ge=0)],
) -> Response:
    content_length = request.headers.get("content-length")
    if content_length is None or not content_length.isdigit():
        raise HTTPException(411, detail={"code": "content_length_required"})
    length = int(content_length)
    if length < 1 or length > MAX_CHUNK_BYTES:
        raise HTTPException(413, detail={"code": "chunk_size_invalid"})
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > MAX_CHUNK_BYTES:
            raise HTTPException(413, detail={"code": "chunk_too_large"})
    if len(body) != length:
        raise HTTPException(400, detail={"code": "content_length_mismatch"})

    with artifact_lock(artifact_id):
        with engine.begin() as connection:
            row = artifact_row(connection, artifact_id, for_update=True)
            assert_owner(row, device_id)
            if row["storage_status"] == "available":
                raise HTTPException(
                    409,
                    detail={"code": "artifact_already_complete"},
                    headers={"Upload-Offset": str(row["stored_size_bytes"])},
                )
            current = row["stored_size_bytes"]
            part = incoming_path(artifact_id)
            part.parent.mkdir(parents=True, exist_ok=True)
            actual = part.stat().st_size if part.exists() else 0
            if actual > current:
                with part.open("r+b") as output:
                    output.truncate(current)
                    output.flush()
                    os.fsync(output.fileno())
                actual = current
            elif actual < current:
                current = actual
                connection.execute(
                    text(
                        """
                        UPDATE artifacts SET stored_size_bytes=:offset,
                            storage_status='uploading',upload_updated_at=now()
                        WHERE id=:id
                        """
                    ),
                    {"offset": current, "id": artifact_id},
                )
            if upload_offset != current:
                raise HTTPException(
                    409,
                    detail={"code": "offset_mismatch", "uploadOffset": current},
                    headers={"Upload-Offset": str(current)},
                )
            if current + length > row["expected_size_bytes"]:
                raise HTTPException(413, detail={"code": "artifact_size_exceeded"})
            with part.open("ab", buffering=0) as output:
                output.write(body)
                output.flush()
                os.fsync(output.fileno())
            next_offset = current + length
            connection.execute(
                text(
                    """
                    UPDATE artifacts
                    SET stored_size_bytes=:offset,storage_status='uploading',
                        upload_updated_at=now()
                    WHERE id=:id
                    """
                ),
                {"offset": next_offset, "id": artifact_id},
            )
    return Response(status_code=204, headers={"Upload-Offset": str(next_offset)})


def final_relative_path(row: Any) -> Path:
    recording = str(row["recording_id"])
    artifact = str(row["id"])
    extension = Path(row["file_name"]).suffix.lower()
    if not re.fullmatch(r"\.[a-z0-9]{1,10}", extension):
        extension = ""
    return Path("recordings") / recording[:2] / recording / artifact / (
        f"content{extension}"
    )


@app.post("/v1/artifacts/{artifact_id}/complete")
def complete_artifact(
    artifact_id: uuid.UUID,
    device_id: Annotated[uuid.UUID, Depends(authenticated_device)],
) -> dict[str, Any]:
    hash_mismatch = False
    with artifact_lock(artifact_id):
        with engine.begin() as connection:
            row = artifact_row(connection, artifact_id, for_update=True)
            assert_owner(row, device_id)
            if row["storage_status"] == "available":
                return {
                    "artifactId": str(artifact_id),
                    "sha256": row["sha256"],
                    "sizeBytes": row["stored_size_bytes"],
                    "serverRelativePath": row["server_relative_path"],
                }
            if row["stored_size_bytes"] != row["expected_size_bytes"]:
                raise HTTPException(
                    409,
                    detail={
                        "code": "upload_incomplete",
                        "uploadOffset": row["stored_size_bytes"],
                    },
                )
            part = incoming_path(artifact_id)
            relative = final_relative_path(row)
            target = STORAGE_ROOT / relative
            if (
                row["expected_size_bytes"] == 0
                and not part.exists()
                and not target.exists()
            ):
                part.parent.mkdir(parents=True, exist_ok=True)
                part.touch()
            candidate = part if part.is_file() else target
            if (
                not candidate.is_file()
                or candidate.stat().st_size != row["expected_size_bytes"]
            ):
                raise HTTPException(409, detail={"code": "part_file_missing"})
            digest = hashlib.sha256()
            with candidate.open("rb") as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(chunk)
            if digest.hexdigest() != row["sha256"]:
                with candidate.open("r+b") as output:
                    output.truncate(0)
                    output.flush()
                    os.fsync(output.fileno())
                connection.execute(
                    text(
                        """
                        UPDATE artifacts
                        SET stored_size_bytes=0,storage_status='corrupt',
                            error_code='hash_mismatch',upload_updated_at=now()
                        WHERE id=:id
                        """
                    ),
                    {"id": artifact_id},
                )
                hash_mismatch = True
            else:
                if candidate == part:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    os.replace(part, target)
                    directory_fd = os.open(target.parent, os.O_RDONLY)
                    try:
                        os.fsync(directory_fd)
                    finally:
                        os.close(directory_fd)
                connection.execute(
                    text(
                        """
                        UPDATE artifacts
                        SET storage_status='available',server_relative_path=:path,
                            verified_at=now(),upload_updated_at=now(),
                            error_code=NULL,error_message=NULL
                        WHERE id=:id
                        """
                    ),
                    {"path": relative.as_posix(), "id": artifact_id},
                )
        if hash_mismatch:
            raise HTTPException(422, detail={"code": "artifact_hash_mismatch"})
    return {
        "artifactId": str(artifact_id),
        "sha256": row["sha256"],
        "sizeBytes": row["expected_size_bytes"],
        "serverRelativePath": relative.as_posix(),
    }


@app.post("/v1/recordings/{recording_id}/complete")
def complete_recording(
    recording_id: uuid.UUID,
    device_id: Annotated[uuid.UUID, Depends(authenticated_device)],
) -> dict[str, Any]:
    with engine.begin() as connection:
        ensure_not_retired(connection, "recording", recording_id)
        recording = connection.execute(
            text(
                """
                SELECT * FROM recordings
                WHERE id=:id AND capture_device_id=:device FOR UPDATE
                """
            ),
            {"id": recording_id, "device": device_id},
        ).mappings().first()
        if recording is None:
            raise HTTPException(404, detail={"code": "recording_not_found"})
        artifacts = connection.execute(
            text(
                """
                SELECT id,artifact_type,expected_size_bytes,sha256,storage_status
                FROM artifacts WHERE recording_id=:id AND artifact_type NOT IN ('ecg','heart_rate','rr') ORDER BY id
                """
            ),
            {"id": recording_id},
        ).mappings().all()
        unavailable = [
            str(row["id"]) for row in artifacts if row["storage_status"] != "available"
        ]
        if unavailable:
            raise HTTPException(
                409,
                detail={"code": "artifacts_incomplete", "artifacts": unavailable},
            )
        receipt_data = [
            {
                "id": str(row["id"]),
                "sha256": row["sha256"],
                "size": row["expected_size_bytes"],
            }
            for row in artifacts
        ]
        receipt = sha256_bytes(canonical_json(receipt_data))
        if (
            recording["ingest_status"] == "complete"
            and recording["receipt_sha256"] != receipt
        ):
            raise HTTPException(409, detail={"code": "receipt_conflict"})
        connection.execute(
            text(
                """
                UPDATE recordings
                SET ingest_status='complete',server_verified_at=COALESCE(server_verified_at,now()),
                    receipt_sha256=:receipt,server_updated_at=now()
                WHERE id=:id
                """
            ),
            {"receipt": receipt, "id": recording_id},
        )
        verified = connection.execute(
            text("SELECT server_verified_at FROM recordings WHERE id=:id"),
            {"id": recording_id},
        ).scalar_one()
    return {
        "recordingId": str(recording_id),
        "ingestStatus": "complete",
        "verifiedAtUtc": utc_isoformat(verified),
        "artifactCount": len(artifacts),
        "totalBytes": sum(row["expected_size_bytes"] for row in artifacts),
        "receiptSha256": receipt,
    }


@app.get("/v1/me")
def get_me(
    device_id: Annotated[uuid.UUID, Depends(authenticated_device)],
) -> dict[str, str]:
    return {"deviceId": str(device_id)}


@app.put("/v1/accounts/{identifier}")
def put_account(identifier: str,
                device_id: Annotated[uuid.UUID, Depends(authenticated_device)]) -> dict[str, str]:
    identifier = normalize_account(identifier)
    with engine.begin() as connection:
        ensure_account(connection, identifier)
    return {"identifier": identifier}


@app.put("/v1/dogs/{dog_id}/account")
def assign_dog_account(dog_id: uuid.UUID, payload: AccountAssignment,
                       device_id: Annotated[uuid.UUID, Depends(authenticated_device)],
                       account: Annotated[str | None, Depends(selected_account)] = None) -> dict[str, str]:
    identifier = normalize_account(payload.account_id)
    if account != identifier:
        raise HTTPException(422, detail={"code": "account_header_mismatch"})
    with engine.begin() as connection:
        ensure_not_retired(connection, "dog", dog_id)
        dog = connection.execute(text("SELECT account_id FROM dogs WHERE id=:id FOR UPDATE"), {"id": dog_id}).first()
        if dog is None:
            raise HTTPException(404, detail={"code": "dog_not_found"})
        if dog.account_id is not None and dog.account_id != identifier:
            raise HTTPException(409, detail={"code": "dog_account_conflict", "message": "Dog already belongs to another account"})
        ensure_account(connection, identifier)
        connection.execute(text("UPDATE dogs SET account_id=:account,updated_at=now() WHERE id=:id"),
                           {"id": dog_id, "account": identifier})
    return {"dogId": str(dog_id), "accountId": identifier}


@app.put("/v1/recordings/{recording_id}/questionnaire")
def edit_session_questionnaire(recording_id: uuid.UUID, payload: QuestionnaireEdit,
                               device_id: Annotated[uuid.UUID, Depends(authenticated_device)],
                               account: Annotated[str | None, Depends(selected_account)] = None) -> dict[str, Any]:
    questionnaire = payload.questionnaire
    validate_questionnaire(session_validator, questionnaire, "session")
    with engine.begin() as connection:
        ensure_not_retired(connection, "recording", recording_id)
        row = connection.execute(text("""SELECT r.*,d.account_id FROM recordings r
            JOIN dogs d ON d.id=r.dog_id WHERE r.id=:id FOR UPDATE OF r,d"""),
            {"id": recording_id}).mappings().first()
        if row is None or row["account_id"] != account:
            raise HTTPException(404, detail={"code": "recording_not_found"})
        if account is None:
            raise HTTPException(409, detail={"code": "account_required", "message": "Link this dog to an account before editing its sessions"})
        if row["questionnaire_revision"] != payload.expected_revision:
            raise HTTPException(409, detail={"code": "questionnaire_revision_conflict", "serverRevision": row["questionnaire_revision"],
                                           "message": "The questionnaire changed on another device. Refresh and try again"})
        original = row["session_questionnaire"]
        for key, default in (("schemaVersion", None), ("animalId", None), ("sessionKind", "activity"), ("videoRequested", row["video_requested"])):
            if questionnaire.get(key, default) != original.get(key, default):
                raise HTTPException(422, detail={"code": "immutable_capture_field", "field": key})
        connection.execute(text("""UPDATE recordings SET session_questionnaire=CAST(:questionnaire AS jsonb),
            session_label=:label,questionnaire_validation_state='complete',
            questionnaire_revision=questionnaire_revision+1,server_updated_at=now() WHERE id=:id"""),
            {"id": recording_id, "questionnaire": json.dumps(questionnaire, ensure_ascii=False),
             "label": questionnaire["sessionLabel"]})
    return get_recording(recording_id, device_id)


@app.get("/v1/dogs")
def get_dogs(
    device_id: Annotated[uuid.UUID, Depends(authenticated_device)],
    limit: int = 50,
    cursor: uuid.UUID | None = None,
    account: Annotated[str | None, Depends(selected_account)] = None,
) -> dict[str, Any]:
    limit = min(max(limit, 1), 200)
    with engine.connect() as connection:
        rows = connection.execute(
            text(
                """
                SELECT d.id,d.number_or_name,d.revision,d.updated_at,d.account_id,
                       v.id profile_version_id,v.schema_version,v.questionnaire
                FROM dogs d
                JOIN dog_profile_versions v
                  ON v.dog_id=d.id AND v.superseded_at IS NULL
                WHERE d.archived_at IS NULL
                  AND d.account_id IS NOT DISTINCT FROM CAST(:account AS text)
                  AND (CAST(:cursor AS uuid) IS NULL OR d.id > CAST(:cursor AS uuid))
                ORDER BY d.id LIMIT :limit
                """
            ),
            {"limit": limit + 1, "cursor": cursor, "account": account},
        ).mappings().all()
    has_more = len(rows) > limit
    rows = rows[:limit]
    return {
        "items": [
            {
                "id": str(row["id"]),
                "numberOrName": row["number_or_name"],
                "accountId": row["account_id"],
                "revision": row["revision"],
                "updatedAtUtc": utc_isoformat(row["updated_at"]),
                "profileVersion": {
                    "id": str(row["profile_version_id"]),
                    "schemaVersion": row["schema_version"],
                    "questionnaire": row["questionnaire"],
                },
            }
            for row in rows
        ],
        "nextCursor": str(rows[-1]["id"]) if has_more else None,
    }


@app.get("/v1/dogs/{dog_id}")
def get_dog(
    dog_id: uuid.UUID,
    device_id: Annotated[uuid.UUID, Depends(authenticated_device)],
) -> dict[str, Any]:
    with engine.connect() as connection:
        ensure_not_retired(connection, "dog", dog_id)
        row = connection.execute(
            text(
                """
                SELECT d.*,v.id profile_version_id,v.schema_version,v.questionnaire,
                       v.validation_state,v.content_sha256,v.client_created_at
                FROM dogs d JOIN dog_profile_versions v
                  ON v.dog_id=d.id AND v.superseded_at IS NULL
                WHERE d.id=:id
                """
            ),
            {"id": dog_id},
        ).mappings().first()
        versions = connection.execute(
            text(
                """
                SELECT id,schema_version,validation_state,questionnaire,
                       content_sha256,client_created_at,superseded_at
                FROM dog_profile_versions
                WHERE dog_id=:id
                ORDER BY server_created_at,id
                """
            ),
            {"id": dog_id},
        ).mappings().all()
    if row is None:
        raise HTTPException(404, detail={"code": "dog_not_found"})
    return {
        "id": str(row["id"]),
        "numberOrName": row["number_or_name"],
        "accountId": row["account_id"],
        "revision": row["revision"],
        "profileVersion": {
            "id": str(row["profile_version_id"]),
            "schemaVersion": row["schema_version"],
            "validationState": row["validation_state"],
            "questionnaire": row["questionnaire"],
            "contentSha256": row["content_sha256"],
            "clientCreatedAtUtc": utc_isoformat(row["client_created_at"]),
            "supersededAtUtc": None,
        },
        "profileVersions": [
            {
                "id": str(version["id"]),
                "schemaVersion": version["schema_version"],
                "validationState": version["validation_state"],
                "questionnaire": version["questionnaire"],
                "contentSha256": version["content_sha256"],
                "clientCreatedAtUtc": utc_isoformat(version["client_created_at"]),
                "supersededAtUtc": utc_isoformat(version["superseded_at"])
                if version["superseded_at"]
                else None,
            }
            for version in versions
        ],
    }


@app.get("/v1/dogs/{dog_id}/recordings")
def get_dog_recordings(
    dog_id: uuid.UUID,
    device_id: Annotated[uuid.UUID, Depends(authenticated_device)],
    limit: int = 50,
    cursor: uuid.UUID | None = None,
) -> dict[str, Any]:
    limit = min(max(limit, 1), 200)
    with engine.connect() as connection:
        ensure_not_retired(connection, "dog", dog_id)
        rows = connection.execute(
            text(
                """
                SELECT id,source,capture_status,ingest_status,started_at,ended_at,
                       session_label,video_requested
                FROM recordings WHERE dog_id=:dog
                  AND (CAST(:cursor AS uuid) IS NULL OR id > CAST(:cursor AS uuid))
                ORDER BY id LIMIT :limit
                """
            ),
            {
                "dog": dog_id,
                "limit": limit + 1,
                "cursor": cursor,
            },
        ).mappings().all()
    has_more = len(rows) > limit
    rows = rows[:limit]
    return {
        "items": [
            {
                "id": str(row["id"]),
                "source": row["source"],
                "captureStatus": row["capture_status"],
                "ingestStatus": row["ingest_status"],
                "startedAtUtc": utc_isoformat(row["started_at"]),
                "endedAtUtc": utc_isoformat(row["ended_at"])
                if row["ended_at"]
                else None,
                "sessionLabel": row["session_label"],
                "videoRequested": row["video_requested"],
            }
            for row in rows
        ],
        "nextCursor": str(rows[-1]["id"]) if has_more else None,
    }


@app.get("/v1/recordings/{recording_id}")
def get_recording(
    recording_id: uuid.UUID,
    device_id: Annotated[uuid.UUID, Depends(authenticated_device)],
) -> dict[str, Any]:
    with engine.connect() as connection:
        ensure_not_retired(connection, "recording", recording_id)
        recording = connection.execute(
            text(
                """
                SELECT r.*,d.account_id,v.schema_version profile_schema_version,
                       v.validation_state profile_validation_state,
                       v.questionnaire profile_questionnaire,
                       v.content_sha256 profile_content_sha256,
                       v.client_created_at profile_created_at
                FROM recordings r
                JOIN dogs d ON d.id=r.dog_id
                JOIN dog_profile_versions v ON v.id=r.dog_profile_version_id
                WHERE r.id=:id
                """
            ),
            {"id": recording_id},
        ).mappings().first()
        sync = connection.execute(
            text("SELECT * FROM recording_sync WHERE recording_id=:id"),
            {"id": recording_id},
        ).mappings().first()
        artifacts = connection.execute(
            text(
                """
                SELECT id,artifact_type,file_name,mime_type,expected_size_bytes,
                       sha256,storage_status,reference_metadata
                FROM artifacts WHERE recording_id=:id ORDER BY id
                """
            ),
            {"id": recording_id},
        ).mappings().all()
    if recording is None:
        raise HTTPException(404, detail={"code": "recording_not_found"})
    return {
        "id": str(recording["id"]),
        "dogId": str(recording["dog_id"]),
        "accountId": recording["account_id"],
        "questionnaireRevision": recording["questionnaire_revision"],
        "profileVersion": {
            "id": str(recording["dog_profile_version_id"]),
            "schemaVersion": recording["profile_schema_version"],
            "validationState": recording["profile_validation_state"],
            "questionnaire": recording["profile_questionnaire"],
            "contentSha256": recording["profile_content_sha256"],
            "clientCreatedAtUtc": utc_isoformat(recording["profile_created_at"]),
        },
        "source": recording["source"],
        "captureStatus": recording["capture_status"],
        "ingestStatus": recording["ingest_status"],
        "startedAtUtc": utc_isoformat(recording["started_at"]),
        "endedAtUtc": utc_isoformat(recording["ended_at"])
        if recording["ended_at"]
        else None,
        "timezone": recording["timezone"],
        "sessionLabel": recording["session_label"],
        "questionnaireSchemaVersion": recording["questionnaire_schema_version"],
        "questionnaireValidationState": recording[
            "questionnaire_validation_state"
        ],
        "sessionQuestionnaire": recording["session_questionnaire"],
        "alignment": sync.get("alignment"),
        "videoRequested": recording["video_requested"],
        "sensorHardwareId": recording["sensor_hardware_id"],
        "appVersion": recording["app_version"],
        "protocolVersion": recording["protocol_version"],
        "captureErrorCode": recording["capture_error_code"],
        "captureErrorMessage": recording["capture_error_message"],
        "serverVerifiedAtUtc": utc_isoformat(recording["server_verified_at"])
        if recording["server_verified_at"]
        else None,
        "receiptSha256": recording["receipt_sha256"],
        "sync": {
            "schemaVersion": sync["schema_version"],
            "monotonicClock": sync["monotonic_clock"],
            "sessionZeroAtUtc": utc_isoformat(sync["session_zero_at_utc"]),
            "sessionZeroWallClockMs": sync["session_zero_wall_clock_ms"],
            "sessionZeroMonotonicNs": sync["session_zero_monotonic_ns"],
            "sessionZeroUncertaintyNs": sync["session_zero_uncertainty_ns"],
            "firstSensorPacketMonotonicNs": sync[
                "first_sensor_packet_monotonic_ns"
            ],
            "firstSensorDeviceTimerMs": sync["first_sensor_device_timer_ms"],
            "lastSensorPacketMonotonicNs": sync["last_sensor_packet_monotonic_ns"],
            "videoRequestedMonotonicNs": sync["video_requested_monotonic_ns"],
            "mediaRecorderStartedMonotonicNs": sync[
                "media_recorder_started_monotonic_ns"
            ],
            "videoFirstFrameMonotonicNs": sync["video_first_frame_monotonic_ns"],
            "videoFirstFrameCameraTimestampNs": sync[
                "video_first_frame_camera_timestamp_ns"
            ],
            "videoFirstFrameCallbackMonotonicNs": sync[
                "video_first_frame_callback_monotonic_ns"
            ],
            "videoFirstSamplePtsUs": sync["video_first_sample_pts_us"],
            "videoOffsetFromSensorNs": sync["video_offset_from_sensor_ns"],
            "cameraTimestampSource": sync["camera_timestamp_source"],
            "cameraClockQuality": sync["camera_clock_quality"],
            "sensorClockQuality": sync["sensor_clock_quality"],
            "overallSyncQuality": sync["overall_sync_quality"],
            "calibrationOffsetNs": sync["calibration_offset_ns"],
            "estimatedDriftPpm": sync["estimated_drift_ppm"],
        },
        "artifacts": [
            {
                "id": str(row["id"]),
                "type": row["artifact_type"],
                "fileName": row["file_name"],
                "mimeType": row["mime_type"],
                "sizeBytes": row["expected_size_bytes"],
                "sha256": row["sha256"],
                "storageStatus": row["storage_status"],
                "referenceMetadata": row["reference_metadata"],
            }
            for row in artifacts
        ],
    }


@app.get("/v1/recordings/{recording_id}/sync-status")
def get_recording_status(
    recording_id: uuid.UUID,
    device_id: Annotated[uuid.UUID, Depends(authenticated_device)],
) -> dict[str, Any]:
    with engine.connect() as connection:
        ensure_not_retired(connection, "recording", recording_id)
        row = connection.execute(
            text(
                """
                SELECT id,ingest_status,server_verified_at,receipt_sha256,
                       capture_status,capture_error_code,capture_error_message,
                       session_questionnaire,server_updated_at
                FROM recordings WHERE id=:id
                """
            ),
            {"id": recording_id},
        ).mappings().first()
        artifacts = connection.execute(text("""
            SELECT id,artifact_type,file_name,expected_size_bytes,stored_size_bytes,
                   sha256,storage_status,server_relative_path,verified_at,
                   upload_updated_at,error_code,error_message
            FROM artifacts WHERE recording_id=:id ORDER BY id
        """), {"id": recording_id}).mappings().all()
    if row is None:
        raise HTTPException(404, detail={"code": "recording_not_found"})
    return recording_status(row, artifacts, STORAGE_ROOT)


def stream_file(path: Path, start: int, length: int):
    with path.open("rb") as source:
        source.seek(start)
        remaining = length
        while remaining:
            chunk = source.read(min(1024 * 1024, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
            yield chunk


@app.get("/v1/artifacts/{artifact_id}/content")
def download_artifact(
    artifact_id: uuid.UUID,
    request: Request,
    device_id: Annotated[uuid.UUID, Depends(authenticated_device)],
):
    with engine.connect() as connection:
        row = artifact_row(connection, artifact_id)
    assert_artifact_exists(row)
    if row["storage_status"] != "available" or not row["server_relative_path"]:
        raise HTTPException(409, detail={"code": "artifact_not_available"})
    path = (STORAGE_ROOT / row["server_relative_path"]).resolve()
    if STORAGE_ROOT not in path.parents or not path.is_file():
        raise HTTPException(500, detail={"code": "stored_file_missing"})
    size = row["expected_size_bytes"]
    headers = {
        "Accept-Ranges": "bytes",
        "ETag": f'"{row["sha256"]}"',
        "Content-Disposition": FileResponse(path, filename=row["file_name"]).headers["content-disposition"],
    }
    range_header = request.headers.get("range")
    if not range_header:
        return FileResponse(
            path,
            media_type=row["mime_type"],
            filename=row["file_name"],
            headers=headers,
        )
    match = re.fullmatch(r"bytes=(\d+)-(\d*)", range_header)
    if match is None:
        raise HTTPException(416, detail={"code": "invalid_range"})
    try:
        start = int(match.group(1))
        end = int(match.group(2)) if match.group(2) else size - 1
    except ValueError:
        raise HTTPException(416, detail={"code": "invalid_range"}) from None
    if start >= size or end < start or end >= size:
        raise HTTPException(
            416,
            detail={"code": "range_not_satisfiable"},
            headers={"Content-Range": f"bytes */{size}"},
        )
    length = end - start + 1
    headers.update(
        {
            "Content-Range": f"bytes {start}-{end}/{size}",
            "Content-Length": str(length),
        }
    )
    return StreamingResponse(
        stream_file(path, start, length),
        status_code=206,
        media_type=row["mime_type"],
        headers=headers,
    )


@app.get("/v1/integrity")
def integrity(
    device_id: Annotated[uuid.UUID, Depends(authenticated_device)],
    account: Annotated[str | None, Depends(selected_account)] = None,
) -> dict[str, Any]:
    problems: list[dict[str, str]] = []
    with engine.connect() as connection:
        rows = connection.execute(
            text(
                """
                SELECT a.id,a.server_relative_path,a.expected_size_bytes,a.sha256
                FROM artifacts a JOIN recordings r ON r.id=a.recording_id
                JOIN dogs d ON d.id=r.dog_id
                WHERE a.storage_status='available'
                  AND d.account_id IS NOT DISTINCT FROM CAST(:account AS text)
                """
            ),
            {"account": account},
        ).mappings().all()
    for row in rows:
        path = (STORAGE_ROOT / row["server_relative_path"]).resolve()
        if STORAGE_ROOT not in path.parents or not path.is_file():
            problems.append({"artifactId": str(row["id"]), "problem": "missing"})
            continue
        if path.stat().st_size != row["expected_size_bytes"]:
            problems.append({"artifactId": str(row["id"]), "problem": "size"})
            continue
        digest_builder = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest_builder.update(chunk)
        digest = digest_builder.hexdigest()
        if digest != row["sha256"]:
            problems.append({"artifactId": str(row["id"]), "problem": "hash"})
    return {"status": "ok" if not problems else "failed", "problems": problems}
