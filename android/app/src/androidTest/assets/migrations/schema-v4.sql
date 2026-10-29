-- Reconstructed compatibility schema, NOT original release DDL.
-- Published v5 migration contracts retain the same tables for versions 4 to 5.
CREATE TABLE dogs (
    id TEXT PRIMARY KEY,
    number_or_name TEXT NOT NULL CHECK(length(trim(number_or_name)) > 0),
    server_revision INTEGER NOT NULL DEFAULT 0,
    created_at_utc TEXT NOT NULL,
    updated_at_utc TEXT NOT NULL,
    archived_at_utc TEXT
);

CREATE TABLE dog_profile_versions (
    id TEXT PRIMARY KEY,
    dog_id TEXT NOT NULL REFERENCES dogs(id) ON DELETE RESTRICT,
    schema_version INTEGER NOT NULL,
    validation_state TEXT NOT NULL CHECK(validation_state IN ('complete','legacy_incomplete')),
    questionnaire_json TEXT NOT NULL,
    content_sha256 TEXT NOT NULL,
    client_created_at_utc TEXT NOT NULL,
    superseded_at_utc TEXT,
    server_sync_state TEXT NOT NULL DEFAULT 'pending'
        CHECK(server_sync_state IN ('pending','uploading','synced','retryable_error','permanent_error')),
    server_revision INTEGER,
    sync_attempt_count INTEGER NOT NULL DEFAULT 0,
    next_retry_at_utc TEXT,
    last_error_code TEXT,
    last_error_message TEXT,
    server_synced_at_utc TEXT,
    UNIQUE(dog_id, content_sha256)
);

CREATE UNIQUE INDEX dog_profile_one_current ON dog_profile_versions(dog_id) WHERE superseded_at_utc IS NULL;

CREATE INDEX dog_profile_sync ON dog_profile_versions(server_sync_state, client_created_at_utc) WHERE server_sync_state <> 'synced';

CREATE TABLE recordings (
    id TEXT PRIMARY KEY,
    dog_id TEXT NOT NULL REFERENCES dogs(id) ON DELETE RESTRICT,
    dog_profile_version_id TEXT NOT NULL REFERENCES dog_profile_versions(id) ON DELETE RESTRICT,
    source TEXT NOT NULL CHECK(source IN ('live','replay')),
    status TEXT NOT NULL CHECK(status IN ('preparing','recording','completed','failed','interrupted')),
    session_label TEXT NOT NULL,
    questionnaire_schema_version INTEGER NOT NULL,
    questionnaire_validation_state TEXT NOT NULL CHECK(questionnaire_validation_state IN ('complete','legacy_incomplete')),
    questionnaire_json TEXT,
    video_requested INTEGER NOT NULL CHECK(video_requested IN (0,1)),
    started_at_utc TEXT,
    ended_at_utc TEXT,
    timezone TEXT NOT NULL,
    sensor_hardware_id TEXT,
    app_version TEXT NOT NULL,
    protocol_version TEXT,
    capture_error_code TEXT,
    capture_error_message TEXT,
    relative_directory TEXT NOT NULL UNIQUE,
    client_created_at_utc TEXT NOT NULL
);

CREATE INDEX recordings_profile_started ON recordings(dog_id, started_at_utc DESC);

CREATE TABLE recording_sync (
    recording_id TEXT PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
    schema_version INTEGER NOT NULL,
    monotonic_clock TEXT NOT NULL,
    session_zero_at_utc TEXT NOT NULL,
    session_zero_wall_clock_ms INTEGER NOT NULL,
    session_zero_monotonic_ns INTEGER NOT NULL,
    session_zero_uncertainty_ns INTEGER NOT NULL,
    first_sensor_packet_monotonic_ns INTEGER,
    first_sensor_device_timer_ms INTEGER,
    last_sensor_packet_monotonic_ns INTEGER,
    video_requested_monotonic_ns INTEGER,
    media_recorder_started_monotonic_ns INTEGER,
    video_first_frame_monotonic_ns INTEGER,
    video_first_frame_camera_timestamp_ns INTEGER,
    video_first_frame_callback_monotonic_ns INTEGER,
    video_first_sample_pts_us INTEGER,
    video_offset_from_sensor_ns INTEGER,
    camera_timestamp_source TEXT,
    camera_clock_quality TEXT,
    sensor_clock_quality TEXT NOT NULL,
    overall_sync_quality TEXT NOT NULL,
    calibration_offset_ns INTEGER NOT NULL DEFAULT 0,
    estimated_drift_ppm REAL,
    updated_at_utc TEXT NOT NULL
);

CREATE TABLE artifacts (
    id TEXT PRIMARY KEY,
    recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK(type IN ('packet','packet_timeline','raw','diagnostic','csv','video','sync','imported_source')),
    file_name TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    relative_path TEXT,
    size_bytes INTEGER NOT NULL CHECK(size_bytes >= 0),
    sha256 TEXT NOT NULL,
    hash_state TEXT NOT NULL DEFAULT 'pending' CHECK(hash_state IN ('pending','verified','failed')),
    local_presence TEXT NOT NULL DEFAULT 'local' CHECK(local_presence IN ('local','remote_only','both','missing')),
    upload_state TEXT NOT NULL DEFAULT 'pending'
        CHECK(upload_state IN ('pending','uploading','available','retryable_error','permanent_error')),
    uploaded_bytes INTEGER NOT NULL DEFAULT 0,
    server_relative_path TEXT,
    server_verified_at_utc TEXT,
    last_error_code TEXT,
    last_error_message TEXT,
    created_at_utc TEXT NOT NULL,
    UNIQUE(recording_id, relative_path)
);

CREATE TABLE server_sync_state (
    recording_id TEXT PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
    state TEXT NOT NULL DEFAULT 'pending'
        CHECK(state IN ('pending','uploading','synced','retryable_error','permanent_error')),
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_retry_at_utc TEXT,
    current_artifact_id TEXT,
    last_error_code TEXT,
    last_error_message TEXT,
    manifest_sha256 TEXT,
    server_receipt_sha256 TEXT,
    server_receipt_at_utc TEXT,
    updated_at_utc TEXT NOT NULL
);

CREATE INDEX artifacts_recording ON artifacts(recording_id);

CREATE INDEX artifacts_upload ON artifacts(upload_state, recording_id) WHERE upload_state <> 'available';

PRAGMA user_version=4;
