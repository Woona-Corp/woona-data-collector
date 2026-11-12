# Video presentation derivatives

Capture artifacts, source hashes and completion receipts remain immutable. The
label worker mounts storage read-only: it admits registered derivatives but never
generates or overwrites media. See [normalizer operations](operations/video/README.md).

## Current CFR30 registry

Schema 2 entries under `derived/video-presentations.json` bind recording/source
identity, canonical source SHA-256, versioned derivative path, actual SHA-256/size,
encoder recipe and qualified frame/timestamp evidence. Initial full SHA-256
verification of a new CFR30 derivative establishes its `derivative_fingerprint`,
which binds that checksum to device, inode, size, `mtime_ns` and `ctime_ns`.
Outputs use immutable UUID-based paths, and the schema 2 registry is published by
atomic replacement.

API/worker admission reuses that verification without rereading the derivative
when the fingerprint matches exactly. A missing or mismatched fingerprint triggers
a full SHA-256 read; `stat` metadata captured before and after the complete read
must also match. Any checksum or metadata mismatch, absent entry or invalid entry
fails closed. A matching file size alone is insufficient. Schema 1 orientation-only
entries retain legacy rules; they are not proof of CFR30 normalization.

The immutable-output publication contract is the fast path's trust boundary:
admission is not a byte-for-byte audit every time and is not a guarantee against
an external writer that can change bytes while preserving the recorded fingerprint.

`label_sync` preserves `data.original_video` and attaches CFR30 only when the task's
existing frozen coordinates are 30 fps, origin 1, inclusive. It preserves task IDs,
annotations, questionnaire/custom metadata and fresh-detail guards; PATCH never
sends annotations. Unexpected URLs or coordinate conflicts fail closed. A task
still pointing at a previous derivative after regeneration requires separately
reviewed provenance-checked transition, not arbitrary derived-URL acceptance.

Dataset export verifies source/derivative identity and performs full source and
derivative hashes regardless of cached fingerprints. Use the admitted presentation
video when present; originals remain provenance/hardware-alignment inputs. CFR30 sampling does not imply identical original timestamps, pixel-level
correspondence, complete annotation coverage, quality admission or hardware sync.

## Operational boundaries

The owner reports the existing 24-to-30 data migration complete; do not replay it
for this integration. Future migration apply/rollback requires real Label Studio
Django/PostgreSQL transaction/recovery validation, not only pure coordinate tests.
Never disable the registry or restore old task fields/project frame rate blindly.
An API/worker image replacement does not update the independently operated host
normalizer source. Timer/source changes need separate explicit authority. Versioned
publication retains previously admitted bytes; failed registry publication may
leave completed unreferenced output. Do not perform broad cleanup. All Woona
scheduled/full backups and off-host transfers remain disabled by owner decision.
