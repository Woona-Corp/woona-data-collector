# Video presentation derivatives

Capture artifacts, their hashes and completion receipts remain immutable. A verified
orientation derivative lives under `WOONA_STORAGE_ROOT/derived/` and is referenced
by `derived/video-presentations.json` (schema version 1). Entries bind recording ID,
source artifact ID/SHA-256, derivative relative path/SHA-256/size and successful
payload/timestamp equivalence checks. Do not register a file before those checks.
The label worker mounts storage read-only; it cannot generate or overwrite media.

`label_sync` preserves the original video URL in `data.original_video`, switches
`data.video` to the registered derivative and adds `meta.video_presentation`.
Existing task IDs, questionnaire metadata and annotation coordinates are retained;
PATCH never sends annotations. Unexpected existing video URLs fail closed.

Dataset export verifies canonical source artifacts as before, rejects mismatched
presentation metadata, and verifies the derivative's SHA-256 before writing a
manifest. Exported records carry `video_presentation.download_url` and its SHA-256;
consumers should use that video when present. `artifacts` retain the originals for
provenance and hardware alignment. Original and derivative timestamps must match.
A task with labels is not proof of complete annotation coverage or quality admission.

For rollback, preserve original task data/meta before activation; disable the
registry and restore only those task fields through the Label Studio API, leaving
annotations untouched. Do not change project frame rate or label configuration.
The storage backup includes `derived/` and the active registry.
