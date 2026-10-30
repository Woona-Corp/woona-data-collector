"""Stable machine actions and safe explanations for API failures."""

ERRORS = {
    'recording_metadata_incomplete': ('The recording exists but its required synchronization metadata is missing. Preserve local originals and contact support; the server did not invent timestamps or change stored files.', 'contact_support_preserve_local_data'),
    'storage_status_busy': ('Storage diagnostics could not finish within their lock, query or file-inspection budget. Wait for Retry-After and retry; upload admission is checked separately, no capacity is promised and no files were removed.', 'retry_later'),
    'storage_quota_exceeded': ('This manifest would exceed the configured recording or account storage quota. Preserve local originals and review the reported quota with the server operator; already accepted files may still resume.', 'review_server_storage_limits'),
    'storage_reservation_unavailable': ('The server cannot reserve enough remaining capacity for this new file after accounting for pending uploads and its safety reserve. Preserve local originals; existing uploads may resume and no files were removed.', 'retry_after_storage_available'),
    'integrity_check_busy': ('The bounded integrity audit is busy, cooling down, or reached its database query budget. Wait for Retry-After before continuing the audit; recording uploads use a separate admission path.', 'retry_later'),
    'storage_space_low': ('The server has insufficient free storage to accept this chunk safely. Keep the original files and retry after server space is freed; the acknowledged offset has not advanced.', 'retry_after_storage_available'),
    'storage_full': ('The server ran out of storage while writing this chunk. Preserve local originals and resume from the acknowledged offset after storage is available.', 'retry_after_storage_available'),
    'missing_bearer_token': ('The server token is missing. Enter the device token in server settings; local data is unchanged.', 'update_server_token'),
    'invalid_bearer_token': ('The server token is invalid or revoked. Check the server address and replace the token in settings.', 'update_server_token'),
    'invalid_account_identifier': ('The account identifier must contain 1–64 Latin letters, digits, dots, underscores or hyphens.', 'review_account'),
    'account_header_mismatch': ('The selected account does not match this request. Choose the intended account and retry.', 'review_account'),
    'account_required': ('Choose an account before moving these records. Local data is unchanged.', 'review_account'),
    'dog_account_conflict': ('This animal belongs to another account. Check the selected account before changing its ownership.', 'review_account'),
    'resource_not_found': ('This item is absent or belongs to another account. Check the selected account and restore its server list; preserve local data.', 'check_account_and_restore'),
    'animal_id_already_exists': ('This animal ID is already reserved by another animal, possibly a historical profile. Restore the existing profile or correct the ID; do not delete local recordings.', 'resolve_animal_identity'),
    'revision_conflict': ('The server has a newer profile revision. Restore it and review your edits before saving again.', 'restore_and_review_changes'),
    'questionnaire_revision_conflict': ('The server questionnaire changed after it was opened. Reload it and review your edits before saving again.', 'restore_and_review_changes'),
    'immutable_profile_conflict': ('A saved profile version cannot be overwritten with different content. Preserve local data and create a new reviewed version.', 'review_manifest_conflict'),
    'profile_content_already_exists': ('This animal already has a saved profile version with these answers. Preserve your draft and reuse the existing version after reviewing it.', 'reuse_existing_profile_version'),
    'immutable_recording_conflict': ('This recording ID already exists with different capture metadata. Preserve both sources and contact support.', 'contact_support_preserve_local_data'),
    'immutable_artifact_conflict': ('This file ID already exists with different size or checksum. Preserve the original file and contact support.', 'contact_support_preserve_local_data'),
    'immutable_capture_field': ('Completed capture metadata cannot be changed through the questionnaire editor. Edit questionnaire answers only.', 'review_questionnaire_changes'),
    'receipt_conflict': ('The existing server receipt does not match this manifest. Keep local originals and contact support before retrying.', 'contact_support_preserve_local_data'),
    'offset_mismatch': ('The server has acknowledged a different upload offset. Read the current offset and resume from it.', 'refresh_upload_offset'),
    'artifact_hash_mismatch': ('The uploaded file checksum differs from its manifest. Preserve the source, verify it locally and restart this file upload.', 'restart_file_upload'),
    'hash_mismatch': ('The uploaded file checksum differs from its manifest. Verify the source before restarting this file upload.', 'restart_file_upload'),
    'part_file_missing': ('The temporary upload file is absent. Keep the source file and restart this file upload from the server offset.', 'refresh_upload_offset'),
    'upload_incomplete': ('This file has not arrived in full. Resume its upload before requesting checksum verification.', 'resume_upload'),
    'artifacts_incomplete': ('Some recording files have not been verified. Upload and verify the listed files before finalizing the recording.', 'upload_and_verify_files'),
    'artifact_not_available': ('This file has not been verified on the server yet. Finish its upload before restoring it.', 'wait_for_verified_upload'),
    'artifact_already_complete': ('The file is already verified and cannot accept more bytes. Refresh its status before continuing.', 'refresh_upload_status'),
    'stored_file_missing': ('Server metadata exists but the stored file is missing. Preserve local originals and contact support.', 'contact_support_preserve_local_data'),
    'database_unavailable': ('The server cannot reach its database. Keep local data; upload can resume when the server is available.', 'retry_later'),
    'storage_unavailable': ('The server cannot read or write recording storage. Keep local data and retry after the server recovers.', 'retry_later'),
    'schema_not_ready': ('The server database schema is not ready for this request. Keep local data and contact support.', 'contact_support_preserve_local_data'),
    'entity_retired': ('This item was deliberately retired on the server. Keep any remaining local source and review the retirement before restoring it.', 'review_retired_item'),
    'recording_not_owned': ('Only the original capture device can finish this upload. Resume it from that device or request a reviewed recovery.', 'resume_on_original_device'),
    'artifact_not_owned': ('Only the file upload owner can change this upload. Resume on its original device; local files remain intact.', 'resume_on_original_device'),
    'wrong_capture_device': ('The capture device ID does not match the authenticated device. Use the original device or request a reviewed import.', 'resume_on_original_device'),
    'missing_required_artifacts': ('The manifest is missing required capture files. Preserve the local directory and rebuild the manifest.', 'review_local_files_and_manifest'),
    'request_invalid': ('The request contains invalid fields. Review fieldErrors and correct the affected values before retrying.', 'review_invalid_fields'),
    'json_body_too_large': ('The metadata request exceeds the server size limit. Keep the local data and review the export or client version.', 'review_request_size'),
    'artifact_too_large': ('The file exceeds the server artifact size limit. Preserve it and contact support for an import path.', 'review_request_size'),
    'chunk_too_large': ('The upload chunk exceeds the server limit. Resume with smaller chunks.', 'reduce_chunk_size'),
    'chunk_size_invalid': ('The upload chunk size is invalid. Review its length and resume from the acknowledged offset.', 'refresh_upload_offset'),
    'content_length_mismatch': ('The received byte count differs from Content-Length. Resume from the server-acknowledged offset.', 'refresh_upload_offset'),
    'content_length_required': ('The upload request is missing Content-Length. Send the actual chunk length and resume.', 'review_upload_headers'),
    'artifact_size_exceeded': ('This chunk would exceed the declared file size. Check the source file and resume from the acknowledged offset.', 'review_local_files_and_manifest'),
    'legacy_migration_disabled': ('This server does not accept the legacy questionnaire format. Preserve the export and use the supported migration or client.', 'review_client_version'),
}

ERRORS.update({
    'path_payload_id_mismatch': ('The identifier in the URL differs from the payload. Preserve the source and correct the request identifiers.', 'review_manifest_conflict'),
    'duplicate_artifact_id': ('The manifest contains a repeated file ID. Preserve local files and rebuild the manifest with distinct artifact IDs.', 'review_local_files_and_manifest'),
    'duplicate_artifact_name': ('The manifest contains repeated file names. Preserve all originals and resolve the duplicate manifest entries.', 'review_local_files_and_manifest'),
    'ended_before_started': ('The capture end time precedes its start time. Review stored clock metadata before retrying; do not invent timestamps.', 'review_timestamps'),
    'reference_ended_before_started': ('The reference end time precedes its start time. Correct the reference interval before retrying.', 'review_timestamps'),
    'artifact_type_mismatch': ('The file extension or MIME type does not match its artifact type. Review the source and manifest before uploading.', 'review_local_files_and_manifest'),
    'profile_schema_version_mismatch': ('The profile schema version differs from its questionnaire. Update the client or rebuild a consistent manifest.', 'review_client_version'),
    'session_schema_version_mismatch': ('The session schema version differs from its questionnaire. Preserve the source and use a compatible client.', 'review_client_version'),
    'session_dog_mismatch': ('The session refers to another animal. Review the intended animal/profile association before retrying.', 'resolve_animal_identity'),
    'reference_metadata_required': ('The reference file requires source and timing metadata. Fill in the missing fields without guessing unknown timestamps.', 'review_invalid_fields'),
    'reference_type_required': ('This endpoint accepts ECG, heart-rate and RR references only. Choose the correct artifact type.', 'review_invalid_fields'),
    'unexpected_reference_metadata': ('Capture files cannot carry reference metadata. Keep capture and post-recording reference manifests separate.', 'review_invalid_fields'),
    'invalid_range': ('The requested download range is invalid. Refresh the file size and restart from a valid byte offset.', 'refresh_download_offset'),
    'range_not_satisfiable': ('The requested byte range lies outside this file. Refresh its size and resume from a valid offset.', 'refresh_download_offset'),
    'invalid_resource_id': ('The resource identifier is not a valid UUID. Review the selected record or client request.', 'review_request'),
    'recording_not_found': ('This recording is absent from the selected server/account. Check the account and preserve its local source.', 'check_account_and_restore'),
    'dog_not_found': ('This animal is absent from the selected server/account. Check the account and refresh the profile list.', 'check_account_and_restore'),
    'artifact_not_found': ('This file is absent from the selected server/account. Refresh the recording manifest and preserve the local source.', 'check_account_and_restore'),
})

RETRY_CODES = frozenset({'offset_mismatch', 'part_file_missing', 'upload_incomplete',
    'artifacts_incomplete', 'content_length_mismatch', 'artifact_hash_mismatch', 'hash_mismatch'})


def error_guidance(code: str, status: int) -> dict:
    if code in ERRORS:
        message, action = ERRORS[code]
    elif status == 401:
        message, action = 'Server authentication failed. Check the device token and server address.', 'update_server_token'
    elif status == 403:
        message, action = 'The server denied this operation. Check account, device ownership and access before retrying.', 'review_access'
    elif status == 404:
        message, action = 'The requested item is absent or unavailable in this account. Keep local data and refresh the server list.', 'check_account_and_restore'
    elif status >= 500:
        message, action = 'The server could not complete this request. Keep local data and retry later; provide requestId to support if it persists.', 'retry_later'
    else:
        message, action = 'The server rejected this request. Review its error code and affected fields before retrying; local data is unchanged.', 'review_request'
    return {'message': message, 'retryable': status >= 500 or status in (408, 429) or code in RETRY_CODES,
            'nextAction': action}
