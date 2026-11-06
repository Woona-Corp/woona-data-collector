# Video presentation derivatives

Working videos use **CFR 30 fps**. Capture artifacts, hashes, completion receipts
and video/BLE calibrations retain their original bytes and time basis. Android
and iOS request 30 fps at capture; camera scheduling can still produce VFR.
Changing an MP4 header or the Label Studio setting alone cannot normalize it.

`python3 -m server.video_normalization --root /srv/woona/storage --prepare
/srv/woona/storage/derived/video-presentations.json` runs on the server host with
FFmpeg/ffprobe and Docker. It discovers available video artifacts with a read-only
PostgreSQL query, checks the source hash, encodes H.264/yuv420p, and copies valid
audio streams. Empty audio streams without a codec are omitted. Original orientation
corrections are carried forward. Source and output start at the same video time;
frames are selected/duplicated on the 1/30-second grid without stretching playback.
The final duration rounds up by less than one frame.

Every output's presentation timestamps, frame count and duration are checked, then
the complete output is decoded and both source/output hashes checked before atomic
admission to registry schema 2. Entries bind source artifact ID/SHA-256, derivative
path/hash/size, frame count/rate and an identity time mapping. New outputs bound
source-image timestamp selection using every inspected source PTS and the encoder's
`fps round=near` rule; unsupported gaps exceeding 1/30 s are rejected. Output CFR
alone is not this proof, nor is timestamp selection pixel/content identity or
hardware synchronization. Historical entries remain provenance, not re-certified
encoder truth. Full source hashes are checked during encoding; cached reuse and
read-only admission stream-check derivative hashes against the DB source anchor.
Dataset export checks
full source and derivative hashes again. `--audit /private/path/report.json` checks
every original presentation timestamp without changing files.

The maintained `operations/video/video-normalize.service` and timer are host-only,
using three CPUs and low priority. The owner reports migration complete; this
source integration does not authorize migration replay, timer installation/start,
manual scans, or repointing existing jobs. Host source updates require a separate
explicit live gate; an API/worker image update does not update the host job.
This is video processing; scheduled/full/off-host backups remain disabled under
the owner’s decision of 27 October 2026. Encoding errors
appear in the service journal and do not admit the failed video. The next scan
retries it while other uploads can proceed.

`label_sync` mounts storage read-only. In a 30 fps project it imports only videos
with a verified CFR30 entry. Production sets `LABEL_TARGET_FRAME_RATE=30`; a changed
LS grid stops synchronization. The worker keeps the original URL in
`data.original_video`, switches `data.video` and writes `meta.video_presentation`.
Existing IDs, questionnaires and frozen coordinates are preserved by ordinary sync;
unexpected video URLs fail closed. Dataset exports use the derivative download URL
and retain original artifacts for provenance. BLE exports additionally expose the
working video's sampling error; normalization does not establish hardware sync.

## One-time Label Studio migration

The explicit `server/migrate_video_fps.py` command runs with Label Studio's installed
Django environment. Prepare all task videos before stopping the labeling web
process and sync worker. Run a separate migration container with the same LS image,
database environment and storage mounts. PostgreSQL stays running. Without
`--apply`, the command validates and plans only.

```text
python /opt/woona-fps30/shared/server/migrate_video_fps.py --project 21 \
  --registry /label-studio/files/woona/derived/video-presentations.json \
  --storage /label-studio/files/woona \
  --journal /label-studio/data/migrations/video-cfr30-v1.json --apply
```

The migration locks project/task/annotation/draft/prediction tables in one database
transaction and refuses active annotation locks. It changes only the Video FPS
attribute and cached parser fields, working video pointers, frozen coordinate
metadata, and frame ranges in annotations (including canceled annotations), drafts,
predictions and nested prediction snapshots. Labels, IDs and noncoordinate fields
remain intact. Frame intervals are one-based inclusive: `[start,end]` denotes
`[(start-1)/fps,end/fps)` seconds. Each boundary rounds to the nearest 30 fps grid
point (ties upward); the maximum endpoint shift is 1/60 s. For example 25–48 at
24 fps becomes 31–60 at 30 fps. A second run checks the migrated state and does not
round coordinates again.

The private journal records exact before/after values of changed fields, written
and fsynced before the transaction commits. It is migration evidence, not a full
database backup. For immediate rollback while labeling remains stopped, restore
the previous registry and run `--journal <path> --rollback`, then restart the
previous images. Rollback refuses to overwrite rows edited after migration. Do
not attempt inverse rounding. Historical schema-1 orientation entries remain
readable for rollback, but cannot enter a new 30 fps labeling task.

New media is fsynced and published under a unique path before registry replacement;
registry publication failure before replacement leaves the previous reference and
bytes intact. Successful publication flushes affected directories. Per-recording
successes/failures are not a batch transaction. Retain old derivatives, originals,
registry and migration journal; this change grants no cleanup authority.

The rational unit tests do not prove real Label Studio Django/PostgreSQL transaction
or recovery behavior. Before any future apply/rollback require a pinned isolated
real-LS fixture and separate authority; do not replay the owner-completed migration
for this source integration. A label does not prove coverage or dataset quality.
