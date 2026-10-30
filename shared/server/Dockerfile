# Multi-platform OCI index; review/update procedure: server/DEPENDENCY_BUILD.md
FROM python:3.13.18-slim-trixie@sha256:76baad6037690d6e8c4397fbcaef17bca6f19eecef822b708fe8fa3417d30bb5 AS runtime-base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

WORKDIR /app
# Only dependency inputs invalidate this layer. No unpinned PEP 517 build tools
# or local-project installation: /app/server is imported directly from /app.
COPY server/requirements.lock /app/requirements.lock
RUN python -c "import platform, sys; assert sys.version_info[:2] == (3, 13); assert platform.machine() in ('x86_64', 'aarch64')" && \
    python -m pip install --no-cache-dir --index-url https://pypi.org/simple \
      --require-hashes --only-binary=:all: -r /app/requirements.lock && \
    python -m pip check

COPY server /app/server
# Operator hotfix files can have a restrictive host umask. Normalize public code
# explicitly so the runtime UID can import it without changing credential modes.
RUN find /app/server -type d -exec chmod 755 {} + && \
    find /app/server -type f \( -name '*.py' -o -name '*.ini' -o -name '*.toml' -o -name '*.lock' \) -exec chmod 644 {} +
COPY docs/target-server-plan/models /app/docs/target-server-plan/models
COPY testdata /app/testdata
RUN find /app/docs -type d -exec chmod 755 {} + && \
    find /app/docs -type f -name '*.json' -exec chmod 644 {} +

RUN useradd --system --uid 10001 --no-create-home woona
USER 10001

CMD ["sh", "-c", "alembic -c /app/server/alembic.ini upgrade head && uvicorn server.app:app --host 0.0.0.0 --port 8080"]

# Explicit release/CI target: evidence is outside all hashed COPY scopes.
FROM runtime-base AS verified
ARG WOONA_SOURCE_ID
LABEL org.opencontainers.image.revision=$WOONA_SOURCE_ID
COPY --chmod=0444 build-provenance/source-manifest.json /app/deployment-source-manifest.json
RUN test "$(id -u)" = 10001 && \
    python -B /app/server/deployment_provenance.py verify --root /app \
      --manifest /app/deployment-source-manifest.json --uid 10001 \
      --expected-source-id "$WOONA_SOURCE_ID"

# Last stage intentionally preserves the unverified developer default.
FROM runtime-base AS runtime
