# Reproducible server dependency/image inputs

## Scope and provenance (reviewed 2026-10-30)

`pyproject.toml` remains the direct-dependency source of truth. No direct version
was changed. `requirements.lock` is the complete runtime graph for **CPython 3.13,
Linux glibc, amd64 and arm64**. Other Python versions, musl, Windows, free-threaded
Python, and other image architectures are not supported by this lock contract.
The Dockerfile rejects unsupported Python/architectures rather than compiling
native extensions with unreviewed build dependencies.

The initial runtime constraints came from the owner's read-only live
`importlib.metadata` snapshot, not the older local `server/.venv`. Resolution used
**uv 0.12.24**, public `https://pypi.org/simple`, Python 3.13, and separately
`x86_64-manylinux_2_28` / `aarch64-manylinux_2_28`. The generated files were identical
for these two targets. uv's SHA-256 hashes are PyPI distribution hashes, including
multiple wheels and sometimes sdists; the installer accepts **wheels only**. Do
not replace these with hashes of requirement text or a single developer's wheel.

The reviewed base is the Docker Official Image:

```text
python:3.13.18-slim-trixie
OCI index sha256:76baad6037690d6e8c4397fbcaef17bca6f19eecef822b708fe8fa3417d30bb5
linux/amd64 manifest sha256:aaf08c5490d52cd92bc27142a5215b1e47355a5eaf9adfad2a0fbc022d0b5490
linux/arm64/v8 manifest sha256:7b58e4266b99c869d2225c050345f7c7fec255d9e3baeca19ea7de9411411c91
amd64 config sha256:bdfc738a8a869292ec1b01f1b8e620db533e09d1fe68fe980a7118b22dae9cec
arm64 config sha256:03e07c1a31b1330bcca830eb9ca263608aef404b6581281e3e4b1ee401dcf4d4
```

Read-only HTTPS requests to Docker Hub's token service and
`registry-1.docker.io/v2/library/python/manifests/3.13.18-slim-trixie`, then each
child manifest and config blob, supplied this evidence. The index body SHA-256
matched the registry digest header; both configs reported `PYTHON_VERSION=3.13.18`
and `PYTHON_SHA256=abb0102e6d4ae027509bcb82327d9dd85515b44a3ba8ad538cfc5e9847029f68`.
The floating `3.13-slim` index was also inspected: its different index digest
`2d44738ebf4ce5f63b9d9ea871e9c7cfdc0426f7b0c97cac915fd88ded1d86bb` referenced
the same amd64/arm64 child manifests. The Dockerfile deliberately uses the explicit
version/distro index above, **not** that floating tag. Digest review is not a
vulnerability audit or proof of a successful image build.

Compose service images are also digest-pinned. PostgreSQL
`sha256:4ef4dbc939d61acea57712655ddb4b4ab27419c913f94cca0cd57cb3ea3c2280`
and Caddy `sha256:de23def33b17fb5d1290b0f6c2add1d70780e52341896c00a4c8a2a2fe9d355e`
were read from the exact running Woona containers' immutable `RepoDigests` on
2026-10-30, preserving their resolved images rather than upgrading mutable tags.
CloudBeaver's existing `26.1.4` tag was resolved read-only through Docker Hub to
`sha256:c0975db279e488c6f770e4a5a74e7f8d388d5bc53c75bce82647e82cb6358a3f`;
the index body hash matched the registry header and lists amd64/arm64. That is
registry evidence, not proof that CloudBeaver is deployed. Existing File Browser
and Label Studio digest pins are unchanged. No production containers were changed
by pinning these source inputs. Review these digests deliberately, with relevant
service compatibility/security checks, rather than resolving tags on deployment.

## Exact runtime graph

Dependencies below are active `Requires-Dist` edges on CPython 3.13 Linux; the
`binary` extra is enabled for psycopg. Package names are case-insensitive and
hyphen/underscore-equivalent. No platform markers are needed in these two equal
Linux closures; this does **not** establish a universal cross-platform lock.

| Package | Version | Active dependencies |
| --- | --- | --- |
| alembic | 1.16.4 | Mako, SQLAlchemy, typing-extensions |
| annotated-doc | 0.0.5 | — |
| annotated-types | 0.8.0 | — |
| anyio | 4.15.1 | idna, typing-extensions |
| attrs | 26.1.0 | — |
| click | 8.5.0 | — |
| fastapi | 0.143.0 | annotated-doc, opentelemetry-api, pydantic, starlette, typing-extensions, typing-inspection |
| greenlet | 3.5.6 | — |
| h11 | 0.16.0 | — |
| idna | 3.20 | — |
| jsonschema | 4.25.0 | attrs, jsonschema-specifications, referencing, rpds-py |
| jsonschema-specifications | 2025.9.1 | referencing |
| mako | 1.4.3 | MarkupSafe |
| markupsafe | 3.0.4 | — |
| opentelemetry-api | 1.45.1 | typing-extensions |
| psycopg | 3.2.9 | psycopg-binary |
| psycopg-binary | 3.2.9 | — |
| pydantic | 2.14.1 | annotated-types, pydantic-core, typing-extensions, typing-inspection |
| pydantic-core | 2.50.1 | typing-extensions |
| referencing | 0.37.0 | attrs, rpds-py |
| rpds-py | 2026.9.1 | — |
| sqlalchemy | 2.0.42 | greenlet, typing-extensions |
| starlette | 1.7.0 | anyio |
| typing-extensions | 4.16.0 | — |
| typing-inspection | 0.4.4 | typing-extensions |
| uvicorn | 0.35.0 | click, h11 |

`requirements-test.lock` is a separate complete graph for the existing `test`
extra, constrained to the runtime lock. It adds certifi 2026.10.23, httpcore 1.0.9,
httpx 0.28.1, iniconfig 2.3.1, packaging 26.3, pluggy 1.7.0, pygments 2.21.0,
and pytest 8.4.1. These eight packages are **not installed in the runtime image**.

## Layering and imports

Only `requirements.lock` is copied before the dependency install layer. Source
changes do not rerun pip. Installation uses `--require-hashes --only-binary=:all:`
and `pip check`, with pip itself supplied by the pinned base. No OS package
install, source build, global tool upgrade, or PEP 517 backend resolution occurs.
The application is imported directly from `/app/server` with `/app` as working
directory and explicit `PYTHONPATH=/app` (also preserving direct operator script
imports or imports from another working directory), rather than installing the
local project and fetching its floating
`setuptools>=75` backend. `woona-server` distribution metadata is consequently
not installed; no runtime/operator code uses that metadata. Alembic and uvicorn
console scripts are provided by their locked wheel packages. Preserve the
`server/`, model JSON, and `testdata/` COPY inputs, permissions normalization,
UID **10001**, and existing migration/start command.

The shared dependency/source layers form `runtime-base`. The last/default
`runtime` target and default Compose `WOONA_BUILD_TARGET=runtime` remain convenient
**unverified developer images**. Both production overlays force `verified` for
the API (and Label Studio's worker) and require `WOONA_SOURCE_ID`. Other candidate
builds must explicitly select `WOONA_BUILD_TARGET=verified`, provide the actual full
reviewed commit, and generate `build-provenance/source-manifest.json` outside hash scopes.
The `verified` stage copies the manifest mode 0444 and verifies final public bytes,
source id and readability as actual UID 10001. See
[image provenance and CI evidence](DEPLOYMENT_PROVENANCE.md#integrated-image-targets-and-ci-evidence).
The revision label alone proves nothing. Both targets inherit the same default
CMD, including `alembic upgrade head`; building/probing with an overridden
entrypoint is not approval to start/migrate/deploy.

CI validates locks before building the verified target, checks the exact schema
head `0009` and image tree, and retains Docker local image-ID-to-manifest metadata.
The existing PostgreSQL 18/API suite installs `requirements-test.lock` from the
image with `--require-hashes --only-binary=:all:` and runs `pip check`, not editable
installation or floating setuptools/test tools. Tests mutate only a disposable
container, not the saved candidate image. A manual-only opt-in exact-image export
is documented in the provenance guide; ordinary runs retain small metadata only.

## Deliberate update procedure

1. Use an isolated checkout and disposable environment, never the production or
   existing `server/.venv`. Have Python 3.13+ and uv **0.12.24** available; if uv is
   absent, install that exact tool version only inside a temporary virtualenv and
   put its `bin` directory on the process-local PATH. Do not globally install it.
2. Review upstream release/security notes first. Change direct pins only by an
   explicit reviewed edit to `pyproject.toml`; do not blindly bump major versions.
   From `shared/`, run:

   ```sh
   python3 server/update_dependency_lock.py
   # Only if deliberately updating a transitive package:
   python3 server/update_dependency_lock.py --upgrade pydantic --upgrade pydantic-core
   ```

   The default retains current versions while refreshing hashes. `--upgrade`
   removes only those current-version constraints; dependency coupling may require
   additional explicit names (e.g. pydantic-core with pydantic). For a changed direct
   pin, also pass its name via `--upgrade` to release the old lock constraint.
   The script compiles both runtime/test closures for both target architectures,
   refuses unequal results, and writes only after both comparisons pass. An
   architecture-specific new dependency requires an explicit marker/separate-lock
   design and validator review, not bypassing the comparison.
3. Review every version/hash change and update the graph/provenance above. Locks
   are version preferences on refresh, not permission to trust arbitrary packages.
   Use a clean public-index configuration; do not add private indexes or credentials.
4. For a base refresh, repeat the read-only registry index/child/config inspection,
   verify returned bytes against their SHA-256 identifiers, review Python/distro
   changes and supported platforms, and update the full `FROM` digest and this
   evidence together. Never resolve a mutable tag during normal builds. Re-run all
   checks even for a digest-only patch update. Revisit the validator if Python's
   minor version changes.
5. Perform the validation below. A generated lock is not an installed/tested image.
   Deployments and migrations remain separately authorized operator actions; none
   of these scripts connect to production, deploy, or enable backups.

## Validation

Offline, stdlib-only checks, from `shared/`:

```sh
python3 server/check_dependency_lock.py
python3 -m unittest -v server.tests.test_dependency_lock
```

These reject unhashed/unpinned/URL/option requirements, duplicates, direct-pin
and test/runtime drift, missing psycopg binary support, an unpinned base, source
COPY before install, lost UID/COPY/build contracts, mutable Compose images, and
unverified production build targets. Compose/workflow checks run in the source
checkout before image build, not against nonexistent configuration inside the
runtime image. They do not claim that
hashes are genuine PyPI artifacts or prove dependency closure: the resolver,
verified download/install, and `pip check` provide that evidence.

Install into a **new disposable Python 3.13** environment, not the live one:

```sh
python3.13 -m venv /tmp/woona-dependency-check
/tmp/woona-dependency-check/bin/python -m pip install --index-url https://pypi.org/simple \
  --require-hashes --only-binary=:all: -r server/requirements.lock
/tmp/woona-dependency-check/bin/python -m pip check
/tmp/woona-dependency-check/bin/python -m pip install --index-url https://pypi.org/simple \
  --require-hashes --only-binary=:all: -r server/requirements-test.lock
/tmp/woona-dependency-check/bin/python -m pip check
```

Also download the complete runtime closure with pip's `--require-hashes
--only-binary=:all: --python-version 3.13 --implementation cp --abi cp313 --abi abi3
--abi none`, separately for each architecture. Pass compatible glibc wheel tags
(`--platform manylinux_2_41_ARCH` down through `manylinux_2_17_ARCH`, plus
`manylinux2014_ARCH` and `linux_ARCH`); use temporary destinations. The trixie
base's glibc compatibility must be rechecked if its distro changes. Cross-target
pip downloads use the host's marker evaluation, so they are **not** a substitute
for the two-target resolver comparison or an actual arm64 image test.

With an available Docker daemon, use an isolated Compose project/fresh storage
and the existing server CI commands to build and exercise API/migration tests;
do not point them at a live database. Run `docker compose config -q` from
`shared/`. Verify both amd64 and arm64 image builds/imports when both architectures
are published. Keep existing backups disabled.

Initial local evidence: isolated Python **3.13.13** runtime and test installs
passed hash verification and `pip check`; both architectures' runtime wheel
downloads passed. All 18 server runtime/operator modules imported, including
`app`, `device_admin`, archive/directory imports and migration dependencies;
`psycopg.pq.__impl__` was `binary`. The 23 tests across dependency-lock, schema,
body-limit unit, backend-safety unit, alignment and video-presentation modules
passed, with DB/API endpoints set to unreachable localhost port 1 and temporary
storage. `docker compose config -q` passed. The Docker daemon was absent, so no
image build, actual Python 3.13.18 execution, arm64 execution, database migration,
or full API suite is claimed by these local checks; Docker-backed CI must supply
that remaining evidence.
