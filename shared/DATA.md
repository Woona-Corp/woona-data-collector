# Recording data

Android and iOS use the same V2 questionnaires. Questions, options and validation
live in Git; the server owns accepted answers, profile versions and revisions.
A recording references one dog UUID and its accepted profile-version UUID.
Names and filenames do not establish identity. Later profile edits create a new
version; unchanged answers reuse the existing version.

Every recording retains packet, packet timeline, raw fragments, diagnostics,
sync metadata and all recorded video. Failed validation/upload preserves the
whole local unit and reports the error. Training performs any packet filtering
or cropping; ingestion and export preserve source bytes.

`recording_sync` holds the native sensor/camera clock anchors. Its server-owned
`alignment` JSON holds hash-bound alignment evidence and BLE quality diagnostics.
`original_capture_sync` and `recovery` retain needed historical capture metadata.
An arrival timestamp alone does not establish a one-second error bound.

Label Studio uses `woona:<recording UUID>` and the same server questionnaires.
`python -m server.export_dataset OUTPUT --mode video` exports labeled intervals
in video seconds. `--mode ble` also requires measured alignment with at most one
second error, bound to exact packet/timeline/video SHA-256. It emits the time
mapping and sensor intervals without changing any source file. Export schema 2
preserves every original annotation range; `sensor_intervals` may split at video
pauses and omits only intervals with no certified mapping. All source files
remain complete. Accepted server metadata takes precedence over the original
capture sync artifact.

Retired identities are stored only as SHA-256 of lowercase UUID strings.
Authenticated `/v1/deletions` propagates deletion to clients and prevents upload
of the retired dog, profile, recording or artifact.

Retirement is an authoritative global decision for the exact identity, including
inactive workspaces on the same device. It differs from user-requested eviction
of a local copy, which requires fresh receipt and file verification. Clients
commit retirement and a durable cleanup job in one database transaction before
unlinking files. A failed unlink is visible and retried after restart. Active
capture identities are deferred until shutdown/recovery; a failed SQL transaction
must never remove their files. A missing list/detail response alone is not a
retirement marker and cannot authorize local deletion.

For reviewed recovery from a loose native export, `server.directory_import`
requires the original final manifest and all of its exact-size files. An operator
review binds the original manifest/sync SHA-256, recording UUID, source profile
UUID, canonical dog UUID and reason. A different source profile may map only to
an existing canonical external animal ID; it cannot merge two existing animals.
Only an explicitly reviewed session-label change between the two original sync
snapshots is accepted. Clock or animal-answer differences remain blocked. Both
original snapshots, file hashes and the review are retained in provenance; no
ZIP checksum, capture end timestamp or hardware calibration is invented.
