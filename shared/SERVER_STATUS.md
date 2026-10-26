# Recording transfer and error diagnostics

`GET /v1/recordings/{recordingId}/sync-status` remains backward compatible:
`recordingId`, `ingestStatus`, `verifiedAtUtc`, `receiptSha256` are unchanged.
The additive response has `schemaVersion: 2` and independent `capture`,
`transfer`, `artifacts`, and `labeling` objects.

## Transfer

`transfer.status` is one of:

| Value | Meaning | Recovery |
| --- | --- | --- |
| `metadata_pending` | No capture manifest/files yet | Upload the manifest |
| `uploading` | Capture file bytes are incomplete | Resume from HEAD offset |
| `awaiting_verification` | Bytes arrived; file verification or final receipt is pending | Verify files, then finalize recording |
| `verified` | Stored SHA-256 receipt matches capture manifest and current files have the expected size | No transfer action |
| `integrity_problem` | Corruption, missing/truncated file, or conflicting receipt | Keep local originals; follow `nextAction` |
| `rejected` | Recording or file was rejected | Review the cause; avoid automatic blind retries |

`totalBytes`, `uploadedBytes`, `verifiedBytes`, `totalFiles`, `verifiedFiles`,
`allFilesUploaded`, `allFilesVerified`, and `receiptVerified` describe original
capture artifacts. Later `ecg`, `heart_rate`, and `rr` references are listed in
`artifacts` with `partOfCaptureReceipt: false` and do not change that receipt.
`uploadedBytes` follows HEAD semantics: acknowledged `.part` bytes, bounded by
both database offset and actual temporary-file size.

A persisted receipt confirms the size/hash verification performed during upload.
A status poll rechecks manifest/receipt metadata and file existence/size; it does
**not** rehash gigabytes on each request. `verificationScope` explicitly reads
`stored_sha256_receipt_and_current_file_sizes`. Same-size out-of-band changes
require a separate full integrity audit.

`lastProgressAtUtc`, `secondsSinceLastProgress`, `stalled`, and
`staleAfterSeconds: 900` expose uploads without recent progress. Stalled does not
prove a server failure: the source device can be offline. `retryable`,
`nextAction`, and `lastError` describe recovery without deleting local data.
Per-file entries also include `storageStatus`, `sizeBytes`, `uploadedBytes`,
`verified`, timestamps and error/action details.

## Capture and labeling

`capture.status`, `errorCode`, `errorMessage`, and `successful` describe capture,
not upload. A failed GATT/camera capture can be transferred and receipted in full.

`labeling.eligible`, `exclusionReasons`, and `status` apply the common activity
admission rules. `taskStatus: not_checked` deliberately means the polling API
has not contacted Label Studio; eligibility does not prove a task exists.
The authenticated dashboard separately reconciles eligible records against real
LS tasks, duplicates, unknown and excluded sources. It also shows stalled
uploads and file integrity problems. LS API failures produce unavailable states
instead of invented zero task counts. Dashboard login still requires successful
Label Studio authentication; device-token API diagnostics remain separate.

The worker refreshes managed questionnaire metadata after approved questionnaire
edits, without changing annotations, frozen frame coordinates or custom metadata.
A task identity conflict is reported rather than silently overwritten.

## API errors

Error codes and existing fields are preserved. Responses add safe, actionable
`message`, `retryable`, `nextAction`, and `requestId`; the matching header is
`X-Request-ID`. Token, account/identity conflicts, ownership, invalid inputs,
upload offset, incomplete bytes, checksum mismatch, database/storage outage and
unexpected 500 failures have distinct recovery guidance. Unexpected exception
strings and connection credentials are never included in API responses.
