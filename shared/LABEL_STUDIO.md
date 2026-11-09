# Label Studio deployment

The worker uses existing project **21 — Активность и Аллюр** and preserves its
labeling configuration. It reads completed V2 activity recordings from
PostgreSQL, requires all six capture artifact types, and adds missing tasks
every 60 seconds. In the CFR30 setup it waits for a verified working video before
importing a task; production enforces `LABEL_TARGET_FRAME_RATE=30`. Tasks use `woona:<recording UUID>` and files from the ordinary
Woona storage. [Data contract](DATA.md).

From `shared/` on a fresh host:

```sh
python3 tools/bootstrap_label_env.py
install -d -m 0755 /srv/woona/storage /srv/woona/postgres /srv/woona/label-postgres
chown 10001:10001 /srv/woona/storage
docker compose --env-file .env --env-file .env.label \
  -f compose.yaml -f compose.label.yaml up -d --build --wait
```

Bootstrap refuses to overwrite credentials. Device tokens stay in app settings;
server and Label Studio credentials stay in root-only env files.

Caddy serves API and dashboard alongside Label Studio at
`https://cool-trams.digital/`. The dashboard requires a Label Studio login.
Both PostgreSQL databases stay private. Label Studio mounts Woona files read-only.

## Recording catalog

The catalog implementation at `/dashboard` uses a compact, semantic recording
list with separate capture, transfer and annotation columns. On narrow screens,
the same rows become short labeled blocks rather than a wide, shrunken table.
The desktop account sidebar shows actual project-wide counts; selected-filter
metrics and tab counts are scoped separately. Search accepts dog names, account
identifiers and recording/dog UUIDs. Native filter menus, visible removable
filter chips and pagination retain the current selection. Invalid calendar dates
or a reversed date range keep the HTML workspace and entered filters, show an
accessible correction message, and leave selection metrics unknown rather than
reporting an empty result. The response remains HTTP 422 with `no-store`.
The record's **К
выборке записей** link preserves filters and page through a catalog-only return
URL; external return destinations are rejected. The **Без аккаунта** selection
means the dog's current `account_id` is NULL, not an identified historical uploader.

Open a recording to see available video, file links, the dog profile version
linked to that recording and the current session questionnaire. The profile is a
historical snapshot; the session questionnaire may have been edited after capture.
The detail view separates playback/files from recording metadata and provides
section links to questionnaires and technical details. Nested answers have
readable field labels. Empty answer rows are initially collapsed, while explicit
false, zero and unknown answers remain visible. Raw JSON and identifiers remain
in collapsed technical details. Available files have explicit download links
with their original filenames; unavailable files do not. An explicit
`videoRequested=false` in the session questionnaire distinguishes unrequested
video from missing media; an available video always remains playable. Missing
flags are not inferred as false. Video uses the existing Label Studio local-file
route, browser controls and metadata-only preload, without autoplay. A current
file-size check does not verify video content, signal quality or synchronization.

The summary's hours include known nonnegative `ended_at - started_at` durations
of selected **live** sessions, including unfinished transfers or failed capture.
Replay is excluded, and unknown duration is counted separately, never inferred
from file size. The fully transferred count requires the existing fresh
server-status/receipt check, not only `ingest_status = complete`. Upload problems
include derived artifact errors, including failures of separately added control
files. A verified original capture can therefore coexist with a reference-upload
problem. Annotation class/interval counts remain available in the collapsed
project-wide summary; they are not scoped by catalog filters.

All pages retain the existing Label Studio authentication and `Cache-Control:
no-store`. Anonymous HTML navigation or an expired session redirects to the
existing `/user/login/` page, with a local `next` destination retaining the
requested dashboard page and query. JSON/data and write requests still return
401, not a login document. Permission denials remain 403 and authentication
outages remain 503 rather than causing a login loop. This does **not** grant
access using the separate pgweb/FileBrowser
HTTP Basic credentials. An unavailable Label Studio summary is shown as unknown,
not as zero tasks or missing annotations. Annotation-only filters then show an
unavailable selection, not an empty zero-count result, with a recovery link that
keeps the remaining filters. Refresh is manual to avoid interrupting video,
reading or filter entry. Each page request preserves the existing fresh
physical-file pass; this UI is not a new SHA-256 audit or a load-test result.

Catalog browsing adds no mutation endpoint. The existing **Добавить ЭКГ / ЧСС**
action is explicitly marked as an upload and retains its same-origin protections.
The PostgreSQL/file viewer panels remain separate technical tools; the catalog
requires no schema migration, data move, new dependency or backup job. These are
source-level behavior notes, not evidence of a production deployment.

Targeted local checks from `shared/`:

```sh
server/.venv/bin/python -m unittest -v server.tests.test_dashboard \
  server.tests.test_dashboard_catalog server.tests.test_dashboard_catalog_routes \
  server.tests.test_dashboard_budget server.tests.test_dashboard_workspace \
  server.tests.test_dashboard_review server.tests.test_dashboard_detail_review \
  server.tests.test_dashboard_login
```

A deployment still needs separate verification with real Label Studio sessions,
protected media URLs and production data; synthetic browser checks do not prove
those integrations.

### UI references and boundaries

The application layout and components are independently implemented in local
HTML/CSS, without React, Tailwind, external fonts, scripts or copied kit assets.
References used for interaction and visual hierarchy:

- [HyperUI application tables](https://www.hyperui.dev/components/application/tables/)
  and [details lists](https://www.hyperui.dev/components/application/details-list/):
  semantic list/metadata structure and restrained row separators.
- [Carbon data tables](https://carbondesignsystem.com/components/data-table/usage/),
  discovered through [Component Gallery](https://component.gallery/components/table/):
  compact rows, toolbar versus row actions, progressive disclosure.
- [Preline tables](https://preline.co/docs/tables.html): search/list/pagination as
  one working surface.
- [Untitled UI tables](https://www.untitledui.com/components/tables): consistent
  density, status hierarchy and explicit empty states.

Marketing galleries and animation libraries were not used as operational UI
specifications. Inspection of the supplied resources was not universal: several
sites, the linked Figma file and Checklist Design's checklist contents were
unavailable to the research tools. No paid/private asset or unverified component
license was copied into the repository.

## Label synchronization and exports

```sh
docker compose --env-file .env --env-file .env.label \
  -f compose.yaml -f compose.label.yaml exec -T label_sync python -m server.label_sync --once
```

Exports read the project's explicit frame rate and preserve one-based inclusive
frame ranges as zero-based half-open seconds. Existing annotation metadata
freezes the coordinate frame rate; changing it requires a range migration.
BLE export additionally validates measured, hash-bound alignment.

Backups remain **disabled** under the owner's 27 October 2026 decision.
`server/backup.label.sh` is a disabled entrypoint and exits 78 before touching
services or files. Keep setup and updates consistent with the
[backup policy](operations/backups/README.md). Separate Drive sources and
recovered-recording roots are outside the runtime.

CFR30 working videos, the explicit 24-to-30 coordinate migration and dataset export: [VIDEO_PRESENTATION.md](VIDEO_PRESENTATION.md).
