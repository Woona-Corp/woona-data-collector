# Read-only deployment provenance and preflight

`deployment_provenance.py` is a standalone Python 3.10+ stdlib tool (Linux/POSIX,
`O_NOFOLLOW` required). It never invokes Docker, Git, SSH, SQL, migrations, health
requests, backup, chmod/chown, deletion or deployment. It reads only explicitly
provided JSON evidence files and reviewed public source inputs; output is stdout.
Exit 0 means the requested comparison passed, 1 means rejected, 2 means CLI usage
error. A successful comparison is **not** deployment authorization or attestation.

## Trust boundary and exact formats

Root is `shared/` in a candidate checkout, or `/app` in an image. Inventory covers
exactly the Docker COPY scopes `server/`, `docs/target-server-plan/models/`, and
`testdata/`. Every regular file there must be in the explicit reviewed input list
and have suffix `.py`, `.ini`, `.mako`, `.toml`, `.lock`, `.sh`, `.yaml`, `.json`,
`.sql`, `.md`, or name `Dockerfile`, `Caddyfile`, `Caddyfile.label`. Unsupported
files, hidden paths, sensitive directories (`data`, `storage`, `credentials`,
`secrets`), missing/extra files, symlinks (including root ancestors), traversal,
and special files fail closed **before hashing any input**. Never put private
material in these scopes, even with an allowed extension. Names are inspected to
reject inputs; contents of rejected extras are not read. Files outside the three
scopes (including root `.env` and mounted data) are not traversed or hashed.

Ordinary `__pycache__` directories are the sole ignored generated-input exception;
they are not traversed. A symlink in their place is rejected. Use a clean exported
candidate/build context, not an operational checkout with arbitrary extra files.
Hashing is streaming and rejects changes observed during each read. This is not a
snapshot protocol: freeze the candidate tree and prevent concurrent writes. No
ACL/capability/group simulation or hostile-writer guarantee is provided.

Evidence files (inputs, manifest, observation) must be explicit regular, non-hidden
`.json` files, at most 4 MiB, with no symlink ancestors or traversal. Do not supply
private JSON as evidence. Inputs JSON is a nonempty array of unique relative
POSIX file paths. Manifest v1:

```json
{"format":1,"source_id":"<full lowercase 40- or 64-hex Git commit>","schema_revision":"0009","files":{"server/app.py":{"sha256":"<64 lowercase hex>","size":123},"docs/target-server-plan/models/model.json":{"sha256":"<64 lowercase hex>","size":456},"testdata/vector.json":{"sha256":"<64 lowercase hex>","size":789}}}
```

All three scopes must have entries. Every object has exactly the documented keys;
format and sizes must be integers, not booleans; duplicate JSON keys are rejected.
Revision is an explicit 1–80 character alphanumeric/underscore identifier. The
manifest does not infer the migration head from filenames or query a database.
Canonical encoding is ASCII JSON (`ensure_ascii=True`), sorted keys, separators
`,` and `:`, plus one final LF. `manifest_sha256` is SHA-256 of that encoding;
formatting changes to a supplied manifest do not change its canonical identity.
No timestamps, host paths, secrets, or file contents are included. Keep the manifest
and inputs list **outside** COPY scopes, avoiding a self-hash cycle.

Operator observation v1 has exactly these keys:

```json
{"image_digest":"sha256:<64 lowercase hex>","source_id":"<full commit>","manifest_sha256":"<canonical manifest hash>","schema_revision":"0009","uid":10001}
```

Use one consistent image identity kind **within each comparison**. Docker's
resolved local image ID can be a configuration digest or a platform manifest
digest, depending on its image store/version; it is not universally portable.
An OCI index, platform manifest and configuration digest are different values:
never compare different kinds or silently substitute them. A mutable tag is never
accepted. A store transition requires the archive proof below, independently
observed consumer identity and a separate consumer-side comparison.

`compare` requires exact source, manifest, image, schema and non-root UID matches;
there is deliberately no guessed backward/forward migration compatibility. The
observed source/hash must come from trusted build evidence plus verified image
contents, not from the deployment checkout's HEAD or a hand-copied expected value.
The operator supplies these observations; this tool does not authenticate them.
Missing provenance is a stop/review condition, not permission to fabricate it.

## Offline candidate workflow (no production access)

After all agents' changes are reviewed and the candidate commit is finalized,
prepare an explicit input list outside `shared/`. For example, from `shared/`:

```sh
# This lists tracked names only, not contents. Review the resulting JSON before use.
git ls-files -z -- server docs/target-server-plan/models testdata |
  python3 -c 'import json,sys; print(json.dumps([p.decode("utf-8") for p in sys.stdin.buffer.read().split(b"\0") if p]))' > /tmp/woona-reviewed-inputs.json
# Substitute the actual reviewed full commit id; this tool does not infer clean Git state.
python3 -B server/deployment_provenance.py manifest --root . \
  --inputs /tmp/woona-reviewed-inputs.json --source-id FULL_REVIEWED_COMMIT \
  --schema-revision 0009 > /tmp/woona-source-manifest.json
python3 -B server/deployment_provenance.py verify --root . \
  --manifest /tmp/woona-source-manifest.json
```

The placeholder is intentionally invalid: supply the real value. Generation fails
if relevant untracked files exist; review/commit them separately, never auto-delete
them or reset/pull a dirty tree. The tool does not assert that an arbitrary source
id actually names these bytes. Independent review must establish that link. A
commit without matching bytes fails subsequent manifest verification. A local
manifest binds bytes, not a whole reproducible OCI image: base digest, pinned
lockfiles, builder/platform, build arguments, ignore rules, and image artifact
identity also need retained build evidence.

### Integrated image targets and CI evidence

The Dockerfile now has a shared `runtime-base`, an explicit `verified` target,
and a last/default `runtime` target. Developer Compose defaults to `runtime`:
**that image is unverified and must not be treated as production provenance**.
Production overlays force `verified` for the API and Label Studio worker, and
require a nonempty `WOONA_SOURCE_ID`; standalone candidates must also select
`verified`. Both targets retain UID 10001 and
the existing migration/start CMD; selecting a target does not make startup
read-only or authorize migrations.

After freezing a clean reviewed candidate and generating the manifest above:

```sh
mkdir -p build-provenance
cp /tmp/woona-source-manifest.json build-provenance/source-manifest.json
WOONA_BUILD_TARGET=verified WOONA_SOURCE_ID=FULL_REVIEWED_COMMIT \
  docker compose --env-file /dev/null build api
```

`build-provenance/` is Git-ignored. The sole generated Docker-context exception is
`build-provenance/source-manifest.json`, copied to
`/app/deployment-source-manifest.json` with mode 0444, outside hash scopes. No
credential mode is changed to make evidence readable. A missing manifest, empty
or mismatched full source id, changed/missing/extra public bytes, or unreadability
by UID 10001 fails the verified build. The build runs the CLI as actual UID 10001
and also checks conservative readability. `verify --expected-source-id` checks
full source identity before hashing. The OCI revision label is supplementary.

The `server` CI job validates locks before build, requires a clean checkout, lists
tracked COPY-scope paths as reviewed inputs, and creates the manifest for actual
`git rev-parse HEAD` (including the actual checkout merge commit on PR runs), with
schema revision `0009`. Review of the PR/source list remains a human trust gate.
CI selects `verified`, then probes the immutable Docker image ID with an explicit
Python entrypoint and no network, without running the default migration CMD.
The probe verifies final `/app` bytes, expected full source id, actual UID, and
Alembic's exact single current head `0009`. Image ID comes from Docker; source,
manifest hash and schema come from the verified manifest; UID comes from
`os.getuid()`. CI binds these in `image-binding.json` and runs `compare`.
This records the CI engine's actual local identity, **not** a claim of a pullable
registry reference or authenticated attestation. Record its kind before comparing
across engines. No image digest is inserted into its own image.

Ordinary successful runs retain only small `server-image-provenance` metadata
for seven days: input list, manifest, verification, image binding and explicit
build configuration files, including both production overlays. The API suite runs
on that same image in isolated
Compose with PostgreSQL 18. Test dependencies are installed only in the disposable
container from its copied hashed wheel-only test lock, followed by `pip check`;
this does not change the retained image. Runtime dependency layers remain shared.

An explicit `workflow_dispatch` with scope `server` or `all` and boolean
`export_server_image=true` additionally retains `server-verified-image` for **one
day**: `docker image save` of the verified immutable ID, archive SHA-256 and JSON
provenance. Use only repository-authorized private Actions artifact access; no
access policy or workflow permissions are changed and nothing is published to
GHCR. There is no scheduled export, release asset, environment dump, DB, or storage
export. Before any separately authorized exact-image deployment, check archive
SHA-256, load in an isolated environment, compare same-kind loaded identities
against `image-binding.json` (or establish the archive bridge below), rerun the
no-migration tree/UID verification and consumer-side `compare`,
and independently apply the operator gates below. Artifacts are not permanent
rollback retention or deployment authorization. Local Docker is absent in the
current integration environment; CI must still prove build and Docker-backed tests.

### Image-store transitions: prove the archive identity chain

An observed 2026-10-30 transfer exposed a real distinction: CI recorded the image
configuration digest, while the VPS Docker29.1.3 reported the loaded OCI platform
manifest digest. The API was **not** replaced on the initial mismatch. These are
not equal hashes and neither observation should be overwritten to make them equal.

For this Docker-save/OCI layout, the separately retained archive SHA-256, OCI index,
platform-manifest blob, configuration blob and layer descriptors establish the
chain. Without extracting into a host filesystem:

1. Verify the complete archive against its trusted CI checksum. Reject duplicate
   member names, links, unsafe paths, ambiguous platforms or unsupported layouts.
2. Verify the OCI index's selected platform-manifest digest/size against that blob's
   actual bytes; verify the manifest's configuration digest/size against the actual
   configuration blob. The latter must equal the CI producer configuration identity.
   Check OS/architecture, ordered layers, descriptor sizes/hashes and configuration
   rootfs diff IDs. Compressed layers need correct compressed/diff-ID handling;
   do not apply an uncompressed-only proof to another format.
3. Independently inspect the loaded consumer image. Its reported kind/value must
   match the corresponding **proven** configuration or platform-manifest identity.
   Retain original producer binding, archive checksum, identity-chain evidence and
   consumer observation separately. Do not edit the producer's recorded ID.
4. Run the image's explicit no-migration verification entrypoint as UID10001 with
   no network, verify source bytes/schema/full source ID again, and run `compare`
   using the independently expected **consumer-kind** digest. Repeat against the
   running container after an authorized rollout. Unknown/missing links are a stop,
   not permission to accept an arbitrary replacement ID.

The source-manifest CLI does not parse OCI archives or authenticate this bridge;
that remains an independently reviewed operator gate. Five synthetic transfer-proof
cases (valid, wrong producer, broken config link, changed layer, duplicate member)
and an actual15-layer archive were checked for the observed transition. This does
not promise support for every archive format or engine. No production data is
needed for this proof; application start/migration is not part of it.

Build-maintainer invariants:

1. Freeze/review inputs after lockfiles and Dockerfile are final. Include this
   tool, its tests/guide, dependency locks, migrations, public model and testdata
   files in the manifest; all public COPY-scope files must match.
2. Keep the manifest artifact outside the source scopes (for example
   `/app/deployment-source-manifest.json`). Verify copied bytes, after mode
   normalization, before accepting the image. `--uid 10001` adds conservative
   owner/other mode read/search checks on public files/directories and root.
   It does not change permissions or examine mounted storage. Group-only access
   is conservatively rejected; use an actual non-root interpreter verification
   in an isolated candidate image too. Source checkout ancestor permissions are
   not an image-mode check; run the UID check against the final image tree.
3. Retain canonical manifest/hash and full commit with immutable image identity
   **after** build; never insert the final image digest into a file within that
   same image (circular identity). OCI source/revision labels may supplement,
   but cannot replace, byte verification. No image is source-proven merely
   because a label says so. Recheck COPY scopes/policy if the Dockerfile changes.
4. Run verification with Python `-B` to avoid bytecode writes. Example within an
   already approved isolated image, with manifest present:
   `python -B /app/server/deployment_provenance.py verify --root /app --manifest /app/deployment-source-manifest.json --uid 10001 --expected-source-id FULL_REVIEWED_COMMIT`.
   Invoking this entrypoint directly does not invoke the image's default CMD.

## Operator preflight, post-deploy, and rollback gates

These are manual review gates, not executable deployment automation. The parent
operator handles authorized live, read-only observations; no SSH or production
writes are part of this implementation.

1. Record currently running immutable image identity, actual process UID,
   observed DB Alembic revision, health/readiness, configuration *identifiers*
   (not secrets), and existing rollback image identity. Preserve the dirty
   checkout untouched. `/opt/woona` HEAD `716aa5c` is **not** image-source proof.
   The supplied historical observation of `shared-api-1` image
   `sha256:d7ed6fdf32147ef847bbacca9c1e34c1e2d57e9efd13c4ee7a6d7faae91e22a3`,
   UID 10001 and migration 0009 is not reverified by this tool and has no known
   source-manifest binding. Do not assign it a candidate source id.
2. Build/test an isolated candidate, retain reviewed source manifest and trusted
   build-to-image binding, and verify its public tree/readability. Review any
   schema change and compatibility with installed Android/iOS clients and the
   rollback image **before** authorization. The present Dockerfile default CMD
   runs `alembic ... upgrade head`; therefore even an ordinary container start
   may migrate. Do not start/restart a candidate using that CMD as a read-only
   preflight. No automatic migration is approved by this guide/tool.
3. Obtain actual observed evidence independently. Compare an already inspected
   candidate with the intended reviewed release, using local evidence files:

   ```sh
   python3 -B server/deployment_provenance.py compare \
     --manifest /tmp/woona-source-manifest.json --observed /tmp/woona-observed.json \
     --expected-source-id FULL_REVIEWED_COMMIT \
     --expected-image-digest sha256:EXPECTED_64_HEX --expected-uid 10001
   ```

   Stop on unknown/missing source provenance, schema mismatch, wrong digest/UID,
   unreadable public inputs, failing baseline health, or an unreviewed rollback
   path. Do not synthesize observed values from expectations to make it pass.
4. Only a separately approved deployment procedure may change production. This
   tool never pulls/resets a checkout, starts a service, migrates, changes data
   ownership, deletes files or creates backups. Backups and transfers remain
   disabled by the owner's 2026-10-27 decision; see
   [backup policy](../operations/backups/README.md). Any deployment-specific
   rollback artifact or data action needs separate explicit review/authorization.
5. After an authorized deployment, recollect the **running** image identity,
   actual UID and DB revision, verify image public bytes against the retained
   manifest, and run `compare` again with post-deploy evidence. Independently
   check `/health/live` and `/health/ready` (confirm actual route names in the
   release), database/storage readiness, and authorized read-only client smoke
   checks. The tool performs no HTTP calls and treats no supplied health flag
   as proof. Do not log credentials, response bodies containing private data,
   or arbitrary environment/configuration dumps.
6. If any gate fails, stop rollout/distribution and preserve failure evidence.
   An authorized operator may select the retained previous immutable image only
   if it is compatible with the *current* DB schema and storage format and its
   startup behavior is understood. A schema change can make image-only rollback
   unsafe. Never auto-downgrade/migrate the DB, restore/reset/delete data, or use
   a dirty checkout rebuild as rollback. Escalate incompatible rollback for a
   separately reviewed recovery plan; then repeat identity, readiness and
   read-only smoke checks. No rollback action is performed here.

## Isolated checks and limits

From `shared/` (no dependencies or services needed):

```sh
python3 -B -m unittest server.tests.test_deployment_provenance -v
```

Tests use temporary synthetic files and cover deterministic identity, byte changes,
missing/extra inputs, unsupported/private paths without hashing, symlinks/FIFO,
UID/mode failures, strict JSON/manifest validation, mismatched deployment fields
and CLI redaction, expected-source rejection before hashing, accepted tracked COPY
names, and static Docker/Compose/CI gate integration. They do not attest production, exercise the full app/API,
validate live storage access, prove exact OCI reproducibility, or verify physical
devices/Landing. The manifest excludes Compose, `.dockerignore` and other files
outside the COPY scopes; review/retain those separately as build/deployment
configuration evidence. Root UID, group/ACL behavior, runtime dependencies and
health need independent checks. Public file hashes may identify public code;
never use this manifest format as a private-data inventory.
