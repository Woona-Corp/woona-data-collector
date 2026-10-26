FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY server /app/server
# Operator hotfix files can have a restrictive host umask. Normalize public code
# explicitly so the runtime UID can import it without changing credential modes.
RUN find /app/server -type d -exec chmod 755 {} + && \
    find /app/server -type f \( -name '*.py' -o -name '*.ini' -o -name '*.toml' \) -exec chmod 644 {} +
RUN pip install --no-cache-dir /app/server
COPY docs/target-server-plan/models /app/docs/target-server-plan/models
COPY testdata /app/testdata
RUN find /app/docs -type d -exec chmod 755 {} + && \
    find /app/docs -type f -name '*.json' -exec chmod 644 {} +

RUN useradd --system --uid 10001 --no-create-home woona
USER 10001

CMD ["sh", "-c", "alembic -c /app/server/alembic.ini upgrade head && uvicorn server.app:app --host 0.0.0.0 --port 8080"]
