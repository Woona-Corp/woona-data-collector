"""HTTP payload models and validation; independent of database and storage setup."""
from __future__ import annotations

from datetime import datetime, timezone
import math
import re
from typing import Any, Literal
import uuid

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator, model_validator

HEX_64 = re.compile(r"^[0-9a-f]{64}$")


class StrictModel(BaseModel):
    model_config = ConfigDict(
        extra="forbid", populate_by_name=True, str_strip_whitespace=True
    )

    @model_validator(mode="before")
    @classmethod
    def database_safe_metadata(cls, value):
        # JSON accepts unpaired surrogates and nonfinite numbers; PostgreSQL
        # JSONB and UTF-8 do not. Validate before hashing or idempotent returns.
        pending = [(value, 0)]
        while pending:
            item, depth = pending.pop()
            if depth > 64:
                raise ValueError("Metadata nesting exceeds 64 levels")
            if isinstance(item, str):
                if "\x00" in item:
                    raise ValueError("Text must not contain NUL characters")
                try:
                    item.encode("utf-8")
                except UnicodeEncodeError as error:
                    raise ValueError("Text must contain valid Unicode characters") from error
            elif isinstance(item, float) and not math.isfinite(item):
                raise ValueError("Numbers must be finite")
            elif isinstance(item, int) and not -(2**63) <= item < 2**63:
                raise ValueError("Integers must fit the signed 64-bit storage range")
            elif isinstance(item, dict):
                pending.extend((part, depth + 1) for pair in item.items() for part in pair)
            elif isinstance(item, (list, tuple)):
                pending.extend((part, depth + 1) for part in item)
        return value

    @field_validator("*")
    @classmethod
    def representable_utc(cls, value):
        # Catch coercions such as a numeric string or finite 1e30 becoming int.
        if isinstance(value, int) and not -(2**63) <= value < 2**63:
            raise ValueError("Integers must fit the signed 64-bit storage range")
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError("Numbers must be finite")
        if isinstance(value, datetime):
            try:
                value.astimezone(timezone.utc)
            except (OverflowError, ValueError) as error:
                raise ValueError("Timestamp must be representable in UTC years 1–9999") from error
        return value


class DogPayload(StrictModel):
    id: uuid.UUID
    number_or_name: str = Field(alias="numberOrName", min_length=1, max_length=100)
    expected_revision: int = Field(alias="expectedRevision", ge=0)


class ProfileVersionPayload(StrictModel):
    id: uuid.UUID
    schema_version: int = Field(alias="schemaVersion", ge=1, le=32767)
    validation_state: Literal["complete", "legacy_incomplete"] = Field(
        alias="validationState"
    )
    questionnaire: dict[str, Any]
    content_sha256: str = Field(alias="contentSha256")
    client_created_at_utc: AwareDatetime = Field(alias="clientCreatedAtUtc")

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
    started_at_utc: AwareDatetime = Field(alias="startedAtUtc")
    ended_at_utc: AwareDatetime | None = Field(alias="endedAtUtc")
    timezone: str = Field(min_length=1, max_length=100)
    session_label: str = Field(alias="sessionLabel", min_length=1, max_length=100)
    video_requested: bool = Field(alias="videoRequested")
    sensor_hardware_id: str | None = Field(alias="sensorHardwareId", default=None)
    app_version: str = Field(alias="appVersion", min_length=1, max_length=100)
    protocol_version: str | None = Field(alias="protocolVersion", default=None)
    questionnaire_schema_version: int = Field(
        alias="questionnaireSchemaVersion", ge=1, le=32767
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
    schema_version: int = Field(alias="schemaVersion", ge=1, le=32767)
    monotonic_clock: Literal[
        "android.elapsedRealtimeNanos", "ios.CMClock.hostTime"
    ] = Field(
        alias="monotonicClock"
    )
    session_zero_at_utc: AwareDatetime = Field(alias="sessionZeroAtUtc")
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
    started_at_utc: AwareDatetime = Field(alias="startedAtUtc")
    ended_at_utc: AwareDatetime = Field(alias="endedAtUtc")
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
    client_created_at_utc: AwareDatetime = Field(alias="clientCreatedAtUtc")
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
    schema_version: int = Field(alias="schemaVersion", ge=1, le=32767)
    capture_device_id: uuid.UUID = Field(alias="captureDeviceId")
    dog: DogPayload
    dog_profile_version: ProfileVersionPayload = Field(alias="dogProfileVersion")
    recording: RecordingPayload
    sync: SyncPayload
    artifacts: list[ArtifactPayload] = Field(min_length=1, max_length=32)
