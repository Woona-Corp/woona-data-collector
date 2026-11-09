FROM python:3.13.18-slim-trixie@sha256:76baad6037690d6e8c4397fbca6f19eecef822b708fe8fa3417d30bb5 AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

WORKDIR /app
COPY server/requirements.lock /app/requirements.lock
RUN python -m pip install --no-cache-dir --index-url https://pypi.org/simple \
      --require-hashes --only-binary=:all: -r /app/requirements.lock && \
    python -m pip check

COPY viewer /app/viewer
RUN find /app/viewer -type d -exec chmod 755 {} + && \
    find /app/viewer -type f -exec chmod 644 {} +

RUN useradd --system --uid 10002 --no-create-home woona-viewer
USER 10002

CMD ["uvicorn", "viewer.app:app", "--host", "0.0.0.0", "--port", "8090"]
