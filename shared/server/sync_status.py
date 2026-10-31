"""Read-only recording progress; transfer, capture and labeling remain independent."""
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import json
import stat

from server.eligibility import activity_exclusion_reasons

REFERENCE_TYPES = frozenset({'ecg', 'heart_rate', 'rr'})
STALE_AFTER_SECONDS = 15 * 60


def iso(value):
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')


def calibration_status(sync, artifacts=()) -> dict:
    """A legacy numeric offset is not proof that calibration was measured."""
    value = sync.get('calibration_offset_ns')
    from server.alignment import verified_alignment
    measured = value is not None and sync.get('sensor_clock_quality') == 'calibrated' and verified_alignment(sync, artifacts) is not None
    return {'measured': measured, 'offsetNs': value if measured else None,
            'reason': 'hash_bound_calibration_verified' if measured else 'not_measured_in_source',
            'compatibilityPlaceholder': value is None}


def quality_status(alignment) -> dict:
    alignment = alignment if isinstance(alignment, dict) else {}
    source = alignment.get('archive_import', {}).get('capture_quality') or {}
    quality = alignment.get('data_quality') or {}
    warnings = []
    if source.get('rejected_log_events'):
        warnings.append({'code': 'packet_rejections_observed',
                         'count': source['rejected_log_events']})
    if source.get('reported_lost_max'):
        warnings.append({'code': 'reported_packet_loss_requires_validation',
                         'count': source['reported_lost_max']})
    if quality.get('excluded_sensor_intervals'):
        warnings.append({'code': 'excluded_sensor_intervals',
                         'count': len(quality['excluded_sensor_intervals'])})
    if quality.get('invalid_structure_packets'):
        warnings.append({'code': 'invalid_sensor_packets', 'count': quality['invalid_structure_packets']})
    return {'status': 'warnings' if warnings else 'audited' if quality or source.get('status') == 'diagnostics_checked' else 'not_audited',
            'warnings': warnings, 'diagnosticSha256': source.get('diagnostic_sha256'),
            'continuousSensorCoverageVerified': False,
            'medicalQualityVerified': False}


def artifact_status(row, storage_root: Path) -> dict:
    """HEAD-compatible acknowledged offset, without hashing large files on every poll."""
    expected = row['expected_size_bytes']
    acknowledged = min(max(row['stored_size_bytes'], 0), expected)
    status = row['storage_status']
    code, message = row.get('error_code'), row.get('error_message')
    retryable, action = True, 'resume_upload'
    verified = False
    if status == 'available':
        retryable, action = False, 'none'
        relative = row.get('server_relative_path')
        path = (storage_root / relative).resolve() if relative else None
        try:
            info = path.stat() if path is not None and storage_root in path.parents else None
            if info is None or not stat.S_ISREG(info.st_mode):
                code = 'stored_file_missing'
            elif info.st_size != expected:
                code = 'stored_file_size_mismatch'
            else:
                verified = row.get('verified_at') is not None
        except FileNotFoundError:
            code = 'stored_file_missing'
        except OSError:
            code = 'stored_file_unreadable'
        if not verified:
            code = code or 'artifact_verification_missing'
            message = 'The server cannot confirm the previously verified file. Preserve local data and contact support.'
            action = 'contact_support_preserve_local_data'
    elif status == 'rejected':
        retryable, action = False, 'review_rejected_file'
    else:
        try:
            info = (storage_root / 'incoming' / f"{row['id']}.part").stat()
            acknowledged = min(acknowledged, info.st_size) if stat.S_ISREG(info.st_mode) else 0
        except FileNotFoundError:
            acknowledged = 0
        except OSError:
            acknowledged = 0
            code = 'upload_file_unreadable'
            message = 'The server cannot read the temporary upload. Preserve the source file and retry later.'
            action = 'retry_later'
        if status == 'corrupt':
            code = code or 'hash_mismatch'
            action = 'restart_file_upload'
        elif acknowledged == expected and not code:
            action = 'verify_file'
    return {
        'id': str(row['id']), 'type': row['artifact_type'], 'fileName': row['file_name'],
        'storageStatus': status, 'sizeBytes': expected, 'uploadedBytes': acknowledged,
        'verified': verified, 'verifiedAtUtc': iso(row.get('verified_at')),
        'lastProgressAtUtc': iso(row.get('upload_updated_at')),
        'errorCode': code, 'errorMessage': message, 'retryable': retryable,
        'nextAction': action, 'partOfCaptureReceipt': row['artifact_type'] not in REFERENCE_TYPES,
    }


def recording_status(recording, artifact_rows, storage_root: Path, *, now=None) -> dict:
    storage_root = storage_root.resolve()
    now = now or datetime.now(timezone.utc)
    # Retired artifacts remain part of the frozen capture receipt, but are not
    # displayed or required for progress. Keeping both views on the same rows
    # prevents an administrative retirement from looking like disk corruption.
    visible_rows = [row for row in artifact_rows if row.get('is_active', True)]
    artifacts = [artifact_status(row, storage_root) for row in visible_rows]
    capture_files = [item for item in artifacts if item['partOfCaptureReceipt']]
    total_bytes = sum(item['sizeBytes'] for item in capture_files)
    uploaded = sum(item['uploadedBytes'] for item in capture_files)
    verified_bytes = sum(item['sizeBytes'] for item in capture_files if item['verified'])
    all_uploaded = bool(capture_files) and all(item['uploadedBytes'] == item['sizeBytes'] for item in capture_files)
    all_verified = bool(capture_files) and all(item['verified'] for item in capture_files)
    receipt_rows = [{'id': str(row['id']), 'sha256': row['sha256'], 'size': row['expected_size_bytes']}
                    for row in sorted(artifact_rows, key=lambda row: str(row['id']))
                    if row['artifact_type'] not in REFERENCE_TYPES]
    expected_receipt = hashlib.sha256(json.dumps(receipt_rows, ensure_ascii=False,
        sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    receipt_present = recording['server_verified_at'] is not None and bool(recording['receipt_sha256'])
    receipt_matches = receipt_present and recording['receipt_sha256'] == expected_receipt
    receipt_verified = recording['ingest_status'] == 'complete' and receipt_matches and all_verified
    integrity_problem = (any(item['storageStatus'] in ('corrupt', 'missing') or
                            (item['storageStatus'] == 'available' and not item['verified']) for item in capture_files)
                         or (recording['ingest_status'] == 'complete' and not receipt_verified)
                         or recording['ingest_status'] == 'corrupt')
    if integrity_problem:
        state, retryable, action = 'integrity_problem', False, 'contact_support_preserve_local_data'
        if not any(item['storageStatus'] == 'available' and not item['verified'] for item in capture_files) and not receipt_present:
            retryable, action = True, 'restart_file_upload'
    elif recording['ingest_status'] == 'rejected' or any(item['storageStatus'] == 'rejected' for item in capture_files):
        state, retryable, action = 'rejected', False, 'review_rejected_file'
    elif receipt_verified:
        state, retryable, action = 'verified', False, 'none'
    elif all_uploaded:
        state, retryable = 'awaiting_verification', True
        action = 'finalize_recording' if all_verified else 'verify_files'
    elif recording['ingest_status'] == 'metadata_pending' or not capture_files:
        state, retryable, action = 'metadata_pending', True, 'upload_manifest'
    else:
        state, retryable, action = 'uploading', True, 'resume_upload'
    progress_times = [row.get('upload_updated_at') for row in visible_rows if row['artifact_type'] not in REFERENCE_TYPES]
    progress_times = [value for value in progress_times if value is not None]
    last_progress = max(progress_times) if progress_times else recording.get('server_updated_at')
    age = max(0, int((now - last_progress).total_seconds())) if last_progress else None
    stale = state in ('uploading', 'awaiting_verification', 'metadata_pending') and age is not None and age >= STALE_AFTER_SECONDS
    reasons = activity_exclusion_reasons(recording['ingest_status'], recording['capture_status'],
        recording.get('capture_error_code'), recording.get('session_questionnaire') or {},
        {item['type'] for item in artifacts if item['verified']})
    if integrity_problem:
        reasons.append('Проверка целостности серверных файлов не подтверждена')
    last_error = next(({'code': item['errorCode'], 'message': item['errorMessage'],
                        'retryable': item['retryable'], 'nextAction': item['nextAction']}
                       for item in reversed(capture_files) if item['errorCode']), None)
    if integrity_problem and last_error is None:
        last_error = {'code': 'receipt_not_confirmed',
            'message': 'The stored recording receipt or current file integrity could not be confirmed. Preserve local originals.',
            'retryable': retryable, 'nextAction': action}
    return {
        'schemaVersion': 2, 'recordingId': str(recording['id']),
        'ingestStatus': recording['ingest_status'], 'verifiedAtUtc': iso(recording['server_verified_at']),
        'receiptSha256': recording['receipt_sha256'],
        'capture': {'status': recording['capture_status'], 'errorCode': recording.get('capture_error_code'),
                    'errorMessage': recording.get('capture_error_message'),
                    'successful': recording['capture_status'] == 'completed' and not recording.get('capture_error_code')},
        'transfer': {'status': state, 'totalBytes': total_bytes, 'uploadedBytes': uploaded,
            'verifiedBytes': verified_bytes, 'totalFiles': len(capture_files),
            'verifiedFiles': sum(item['verified'] for item in capture_files),
            'allFilesUploaded': all_uploaded, 'allFilesVerified': all_verified, 'receiptVerified': receipt_verified,
            'verificationScope': 'stored_sha256_receipt_and_current_file_sizes',
            'lastProgressAtUtc': iso(last_progress), 'secondsSinceLastProgress': age,
            'stalled': stale, 'staleAfterSeconds': STALE_AFTER_SECONDS, 'retryable': retryable,
            'nextAction': action, 'lastError': last_error},
        'artifacts': artifacts,
        'quality': quality_status(recording.get('alignment')),
        'labeling': {'eligible': not reasons, 'exclusionReasons': reasons,
                     'status': 'excluded' if reasons else 'eligible', 'taskStatus': 'not_checked'},
    }
