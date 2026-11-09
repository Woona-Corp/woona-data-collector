# Identity, validation and delivery UX — RU/EN specification

Date: 2026-11-07. **Design requirements, not an implementation or verification report.**
Applies equally to native Android and iOS. Canonical compact requirements are in
[UI/UX contract](../UI_UX_CONTRACT.md); account semantics remain defined by
[Accounts](../ACCOUNTS.md) and persistence boundaries by [Architecture](../../ARCHITECTURE.md).
No source, API, clinical fixtures, release or hardware change is authorized by this document.

## 1. Product decisions and invariants

1. Work is saved locally before network work. Every successful durable local
   domain commit (profile/version, binding intent, finalized recording/artifact,
   supported questionnaire edit) schedules an asynchronous server attempt for the
   affected pending work. Persist queue intent atomically with that commit;
   coalescing redundant work is allowed, dropping the newest revision is not.
   Internal progress/log writes must not recursively schedule themselves. A draft
   keystroke is not a commit; active capture is not uploaded as a finalized session.
2. An attempt must run when server configuration, connectivity, Wi-Fi policy and
   OS scheduling permit. Offline/disabled server means a durable waiting state,
   not a synchronous Save failure or a promise of immediate background execution.
   Retry on eligible reconnection/resume, with bounded backoff; manual Retry
   requests the same queue, never a second concurrent upload. Offline, timeout,
   process death and interruption must not crash or discard saved data.
3. Locally mirror the server's applicable deterministic validation: required and
   conditional fields, types, bounds/lengths, enums, identifier normalization,
   identity/linkage and immutable-version rules. Derive acceptance cases from the
   versioned API/schema, not new UI-only guesses. Display field errors before Save;
   do not commit invalid domain data (retain the draft for correction).
   A local pass is **not** server confirmation. Uniqueness, ownership, current
   revisions and server-only policy remain authoritative server checks.
4. A server rejection preserves valid local work and draft input; stop automatic
   retry for a deterministic rejection until corrected. Schema drift/unknown
   validation gets a safe actionable server-error presentation, not silent coercion.
   Retry transient failures; do not repeatedly hammer authentication or conflicts.
5. No guessed identity from dog name, account text or file name; no silent merge,
   reassignment, overwrite or conflict resolution. IDs and versions are stable.
   Repeated requests are idempotent. Local capture, server delivery and clinical quality are
   independent; successful delivery proves neither good capture nor clinical use.
6. This does not relax online-only server questionnaire editing or introduce an
   offline account-transfer API. Unsupported operations explain the prerequisite
   and preserve the draft; a saved draft must never be labelled a committed edit.

## 2. Screen hierarchy and compact mobile layouts

Keep the five tabs and current navigation. Account guidance is grouped at the top
of Animals, dog identity/status next, then recent recording cards; do not repeat
an account editor in Settings. These wireframes use EN strings for space; RU uses
identical order and semantics, not forced equal line lengths.

```text
+----------------------------------------+
| Animals                                |
| DATA ACCOUNT                           |
| Active: clinic-a                       |
| Account ID [clinic-a            ]      |
| Creates or opens a data account.       |
| Not a password. [Apply account]        |
| Restore: Checking…                     |
| Previous account stays active.         |
| [Details v]                            |
+----------------------------------------+
| DOG                                    |
| Luna                   [Selected]      |
| Data account: clinic-a                 |
| Animal identity: Unverified            |
| Saved on this device.                  |
| Next: connect to check identity.       |
| [New dog] [Edit] [Check now]           |
| [Identity details v]                   |
+----------------------------------------+
| Recent recordings       [History]      |
| 07.11.2026 14:05 · Luna                |
| Local capture: Completed               |
| Server delivery: Waiting for network   |
| Saved on this device                   |
| [Packets: saved] [Video: absent]       |
| [Timeline: saved] [More files v]       |
| Next: connect to upload.               |
| [Retry] [Details v]                    |
+----------------------------------------+
| Animals | Session | Video | ...        |
+----------------------------------------+
```

```text
+----------------------------------------+
| Recording details           [Back]     |
| Local capture: Interrupted             |
| Server delivery: Uploading             |
| 2 of 4 files · 12 / 30 MB · 40%        |
| [Packets: delivered]                   |
| [Video: failed] [Timeline: queued]     |
| Next: upload remaining files.          |
|                                        |
| LAST ERROR                             |
| Video upload was interrupted.          |
| The connection was lost.               |
| Next: reconnect, then tap Retry.       |
| [Retry] [Details v]                    |
|                                        |
| ATTEMPTS                    [v]        |
| 14:09 Upload · Interrupted             |
| 14:05 Check profile · Confirmed        |
| [Show older attempts]                  |
| [Edit questionnaire] [Download]        |
| [Share session ZIP]                    |
+----------------------------------------+
```

Do not hide existing applicable recording actions inside diagnostic prose.
Delete-local remains separately confirmed and requires fresh server-copy checks;
this redesign grants no new deletion authority. Active capture retains reachable
Stop regardless of errors, scrolling or network activity.

## 3. Account guidance, identity and exact core copy

An account ID selects a data scope; it is **not sign-in or a password**. Technical
server access is separate. Use «Аккаунт данных / Data account», never invent a
signed-in person. Show active account separately from pending typed ID. Explain:
«Создаёт или открывает аккаунт данных. Это не пароль.» /
“Creates or opens a data account. Not a password.” Before Apply, explain that a
new valid ID creates an account; do not imply the ID must already exist.

With server configured, Apply changes active scope, selection and persisted ID
only after successful metadata restore. While checking, keep the previous scope
visible, disable duplicate Apply, show pending target and keep typed input on
failure. Partial restore is not a successful switch; never show other-scope data.
Without configured server, existing local selection works and is marked
unverified. With configured but unreachable server, explain why Apply cannot
finish; saving other allowed local work still works. Block account switching
during capture/account operations with a readable reason.

For legacy unassigned dogs, group «Животные без аккаунта / Dogs without an
account» and explicit «Привязать / Link». Explain the existing sequence: on a new
phone apply an empty account ID to restore unassigned metadata, then apply the
intended account, inspect the dog and confirm Link. Preview dog + target account
and inheritance by all sessions before confirmation. Existing assigned dogs
cannot be transferred; a conflict never offers an unsupported Move or guesses a
replacement dog. Upload uses the dog's assigned account, not the current selector.

Identity is the server's acknowledgement of the exact dog UUID, account binding
and relevant profile revision, not just a successful network request. Display
account and a shortened stable dog ID in identity details (full ID selectable).

| State | RU / EN visible label | Meaning and next action |
| --- | --- | --- |
| Unverified | Не проверено / Unverified | Local identity/revision not yet acknowledged; «Проверить / Check now» when eligible. |
| Checking | Проверка… / Checking… | Actual check running; retain local content, prevent duplicate action. |
| Confirmed | Подтверждено сервером / Server confirmed | Exact identity/revision acknowledged; show last confirmation time. Not permanent proof of current server availability. |
| Conflict | Конфликт / Conflict | Explicit server identity/account/version mismatch; show what differs and supported resolution, not endless Retry. |
| Offline | Нет связи / Offline | Check cannot currently run; «Сохранено на устройстве. Проверим после подключения.» / “Saved on this device. We will check after connection.” |

Track last known confirmation separately from current connectivity: offline may
show “Last confirmed …” without erasing evidence or presenting a fresh success.
Show Checking only while an actual check is running, never merely because work
is queued. A new local revision becomes unverified even if its predecessor was confirmed.
Confirmation must come from explicit authoritative response, not local validation,
HTTP acceptance of an unrelated request, queue completion or a restored name.

## 4. Recording summary: independent capture, delivery and quality

| Axis | RU / EN labels and rules |
| --- | --- |
| Local capture | Запись на телефоне / Local capture: Подготовка / Preparing; Идёт запись / Recording; Завершён / Completed; Прерван / Interrupted; Ошибка / Failed; Неизвестно / Unknown. Derived from actual persisted lifecycle; legacy missing reason is «Причина не сохранена / Reason not saved». |
| Server delivery | Доставка на сервер / Server delivery: Только на устройстве / On device only; В очереди / Queued; Ожидает сети / Waiting for network; Ожидание Wi-Fi / Waiting for Wi-Fi; Сервер отключён / Server disabled; Проверка / Checking; Загрузка / Uploading; Ожидание подтверждения / Awaiting confirmation; Подтверждена сервером / Server confirmed; Нужно исправить / Needs attention; Конфликт / Conflict. Receipt requires all required artifact verification, not bytes sent. |
| Existing quality information | Show existing data-quality information only when known, with its source. Do not add an empty clinical-quality block or a new “Not assessed” assertion to every card. Never infer clinical quality from CRC, receipt, packet count, waveform appearance or completed capture. This spec introduces no assessment capability. |

Show known transferred bytes/total and files completed/total; indeterminate state
if totals are unknown. Retry/resume does not fake monotonic progress across attempts;
label per-attempt versus total verified bytes. No invented ETA. File chips show
human-readable type and local/delivery state; expand to size/checksum/diagnostic
facts. “Video absent” distinguishes not requested, capture failure and missing
local file; never fabricate a zero-byte successful video. Remote-only files show
Download, not “saved on device”. Missing files and partial receipts stay explicit.

## 5. Errors, diagnostics and durable attempt history

Every failure names **action → reason → exact ordered next step** in the chosen
language. Keep one concise last-error card per relevant operation, with visible
primary remedy and optional secondary action. A successful retry clears only that
operation's active error, not another operation's failure. It does not erase history.

| Situation | RU / EN action-oriented message and action |
| --- | --- |
| Local field rejection | «Профиль не сохранён: заполните поле „{поле}“, затем нажмите „Сохранить“.» / “Profile not saved: complete ‘{field}’, then tap Save.” Focus first invalid field; retain all answers. |
| Offline after Save | «Профиль сохранён на устройстве. Нет связи с сервером. Подключитесь к сети; проверка продолжится автоматически.» / “Profile saved on this device. Cannot reach server. Connect to a network; checking will resume automatically.” No false Save failed. |
| Account restore interrupted | «Аккаунт не переключён: восстановление не завершено. Подключитесь и нажмите „Повторить“. Активен {old}.» / “Account not switched: restore incomplete. Connect, then tap Retry. {old} remains active.” |
| Account conflict | «Привязка не выполнена: собака относится к другому аккаунту. Проверьте ID собаки и выберите её аккаунт. Перенос не поддерживается.» / “Link failed: this dog belongs to another account. Check the dog ID and select its account. Transfer is not supported.” Preserve local files; offer Inspect identity, not blind reassignment. |
| Questionnaire revision conflict | «Ответы не отправлены: на сервере новая версия. Сохраните свою правку как черновик, обновите данные, откройте редактор и проверьте ответы перед сохранением.» / “Answers not submitted: a newer version is on the server. Keep your edit as a draft, refresh, reopen the editor and review answers before saving.” Preserve draft explicitly before refresh; no silent merge or overwrite. |
| Access rejected | «Сервер отклонил доступ. Откройте настройки сервера, проверьте доступ и повторите отправку. Локальные данные сохранены.» / “Server access rejected. Open server settings, check access, then retry delivery. Local data is saved.” Do not request a token in an error report. |
| Capture failed, delivery confirmed | «Захват прерван: {безопасная причина}. Файлы доставлены; это не подтверждает качество записи. Проверьте детали захвата.» / “Capture interrupted: {safe reason}. Files delivered; this does not confirm recording quality. Review capture details.” |

A long raw exception is never the primary message. Unknown failures use a safe
localized explanation plus Retry or Open settings as appropriate; never “Something
went wrong” alone. Do not assert “no internet” for a server timeout: distinguish
known disconnected device, server unreachable, access denied and validation rejection.

Use «Нужно исправить / Needs attention» for actionable rejected/failed work,
with the concrete reason beneath it; retain «Конфликт / Conflict» where an explicit
choice is required. Dog status group is «Идентичность животного / Animal identity».

**Last error is not history.** This iteration provides a bounded, best-effort
persistent diagnostic event journal for real local saves, checks, delivery and
restore actions. Retain at most 128 events across the installation; show at most
20 recent matching events per exact profile-version/recording UUID, newest first
with local timestamps. Explain this retention limit in the expanded viewer.
A queue event is explicitly “Queued”, not a network attempt. Never synthesize
“uploaded / confirmed” events from a current row or backfill fictional chronology.
Show that earlier or missing events may not have been recorded.

Journal writes run on a bounded background writer and never block domain saves;
logging failure cannot discard work or crash the app. Pending journal writes may
be lost on process exit. A “Started” without a result remains unknown, never
success. The journal is not a complete audit, has no attempt-ID correlation or
crash-recovery guarantee, and is not the durable sync queue. Completed writes
survive navigation/relaunch and a successful retry does not explicitly clear them;
oldest events roll out at the stated cap. Richer authoritative audit retention is
a separate future capability, not a release claim.

Collapsed «Подробности / Details» is selectable/copyable and
contains timestamp/timezone, subsystem, HTTP/GATT/error code, requestId if supplied,
and safe message. Copy uses the same redacted representation as display. Never
show/copy authorization headers, tokens, passwords, signed URLs, secret query
parameters or raw private payloads; sanitize before persistence, not only rendering.
Do not invent requestId when absent. Keep IDs/codes out of the summary prose;
requestId and safe codes are diagnostic references, not secrets to erase blindly.
Sharing logs is explicit and previews sanitized content; no automatic upload of
support logs and no clinical answers in diagnostic previews/screenshots.

## 6. Accessibility, responsive design and parity

- Both languages use native localization, pluralization and date/time formatting
  consistent with the existing date contract; canonical stored values do not change.
  Names/free text are not translated. All controls/states/actions have RU/EN text.
- Compact portrait uses one column; landscape may use aligned summary/detail
  columns only if reading/focus order stays account → dog → recording. Large font
  reflows to one column, chips wrap and button rows stack; no fixed-height cards,
  ellipsized remedies or horizontal scrolling required to read an error.
- Keep Save/Cancel/Stop reachable with keyboard and small height; scroll to invalid
  field without losing the draft. Restore focus after expanding details or dialogs.
- TalkBack/VoiceOver announces entity + axis + value (not an ambiguous “Confirmed”),
  names file chip states, progress and expand/collapse. Use grouped headings, logical
  focus, polite throttled status announcements; never announce every upload byte.
  Labels supplement icons/colors; error text and controls meet contrast requirements
  in fixed light/dark themes. Targets meet native minimums (48 dp Android, 44 pt iOS).
- Same information hierarchy, RU/EN terminology, action availability, conflict
  choices and error recovery on Android/iOS. Native permission/share differences
  remain allowed; no platform-specific omission of identity or attempts.

## 7. Acceptance matrix and release gates (required, not completed)

Use isolated synthetic nonclinical metadata and fake transport responses only.
No production records, tokens, clinical fixtures or real patient/dog histories.

| Layer | Focused acceptance coverage |
| --- | --- |
| Validation parity | Versioned server/client acceptance and rejection cases, conditional hidden fields, limits, RU/EN, normalized account ID, stale server schema. Local pass remains unverified; server rejection preserves work. |
| Durable sync | Each eligible local commit schedules work; no recursive log scheduling. Offline, disabled server, Wi-Fi-only, reconnect, duplicate Retry, restart after commit, kill mid-request, timeout and resumable partial files. No loss, crash, double binding or fake receipt. |
| Identity/account | New/local/confirmed/stale revision; checking; offline last-confirmed; existing/missing account; partial restore; empty scope; explicit unassigned Link; wrong account conflict; switch blocked during capture. No name-based match, silent merge or guessed transfer. |
| Recording axes | Every capture × meaningful delivery combination, especially interrupted + confirmed; known existing quality only (no empty quality block); missing video, remote-only, corrupt/missing file, unknown totals and incomplete receipt. Existing history pagination/download/share/delete safeguards regressions. |
| Error/history | Latest error versus bounded retained actual events; success clears only relevant error; retention/admission limits, absent old history or unflushed events, interrupted attempt, unknown code, absent requestId; token/query redaction before storage/copy; actionable recovery and draft retention. |
| Native UI/accessibility | Both platforms × RU/EN × light/dark; compact portrait/landscape, large accessibility font, keyboard, TalkBack/VoiceOver. Review screenshots of each identity state, account partial restore, field/revision conflict, partial upload, long error, expanded redacted details and attempts. |

**Before implementation acceptance:** obtain agreed copy and review schema/API
compatibility; document any unsupported UI action rather than invent an endpoint.
Run smallest changed-scope tests first, then full regression for persistence/UI:
Android `./android/tools/check.sh fast` and `./android/tools/check.sh full`;
shared API contract tests in an isolated test environment and Compose validation
if affected; complete native iOS unit/integration/UI suites on macOS/Xcode.
Native CI must report exact revision, test counts, skips and artifacts for both
platforms; Linux/static inspection cannot substitute for an iOS result.

**Before release:** repeat full regression on the integrated revision, review
paired native screenshots (not just artifact existence), and perform physical
Android/iPhone QA for accessibility, offline/reconnect/relaunch, account isolation,
local data preservation and conflict recovery. Separately execute real BLE,
camera/MP4, stop/finalization and hardware-sync checks with explicit device/OS/build
evidence; emulator/simulator/fake-BLE results do not verify these. Until performed,
report physical BLE/video/synchronization as **not verified**; this document claims
none. Compatible API/migrations must be deployed/verified before dependent builds;
retain compatibility for installed clients. Android signed release, iOS upload,
Apple processing, tester availability and physical installation are separate gates.
No commit, CI run or screenshot alone proves release readiness.

Current candidate evidence and unresolved gates are recorded separately in
[QA evidence, 2026-11-07](qa-identity-sync-20261107.md).
