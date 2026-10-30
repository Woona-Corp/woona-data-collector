"""Offline lock/build-contract checks; no third-party packages or network needed."""
from pathlib import Path
import re
import tomllib

ROOT = Path(__file__).resolve().parent


def canonical(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def parse_lock(text: str) -> dict[str, str]:
    """Accept only exact pins and SHA-256 hashes (no URLs/options/editables)."""
    pins: dict[str, str] = {}
    logical = text.replace("\\\n", " ")
    for line in logical.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([A-Za-z0-9.+!-]+)((?:\s+--hash=sha256:[0-9a-f]{64})+)", line)
        if not match:
            raise ValueError(f"Not a hashed exact pin: {line[:100]}")
        name = canonical(match[1])
        if name in pins:
            raise ValueError(f"Duplicate package: {name}")
        pins[name] = match[2]
    if not pins:
        raise ValueError("Empty dependency lock")
    return pins


def validate(root: Path = ROOT) -> None:
    runtime = parse_lock((root / "requirements.lock").read_text())
    tests = parse_lock((root / "requirements-test.lock").read_text())
    project = tomllib.loads((root / "pyproject.toml").read_text())["project"]
    for requirement in project["dependencies"]:
        name, version = requirement.split("==")
        name = canonical(name.split("[")[0])
        if runtime.get(name) != version:
            raise ValueError(f"Direct dependency drift: {requirement}")
    for name, version in runtime.items():
        if tests.get(name) != version:
            raise ValueError(f"Test/runtime lock drift: {name}")
    for requirement in project["optional-dependencies"]["test"]:
        name, version = requirement.split("==")
        if tests.get(canonical(name)) != version:
            raise ValueError(f"Test dependency drift: {requirement}")
    # The binary extra is essential: psycopg without libpq cannot import on slim.
    if runtime.get("psycopg-binary") != runtime.get("psycopg"):
        raise ValueError("Missing/mismatched psycopg binary extra")
    docker = (root / "Dockerfile").read_text()
    if not re.search(r"^FROM python:3\.13\.18-slim-trixie@sha256:[0-9a-f]{64} AS runtime-base$", docker, re.M):
        raise ValueError("Base must pin the reviewed Python version and OCI index")
    install = docker.index("--require-hashes --only-binary=:all:")
    if install > docker.index("COPY server /app/server"):
        raise ValueError("Dependencies must install before copying server sources")
    if not docker.rstrip().endswith("FROM runtime-base AS runtime"):
        raise ValueError("Unverified runtime must remain the default developer target")
    for fragment in ("USER 10001", "PYTHONPATH=/app", "COPY docs/target-server-plan/models", "COPY testdata", "pip check",
                     "FROM runtime-base AS verified", "ARG WOONA_SOURCE_ID",
                     "COPY --chmod=0444 build-provenance/source-manifest.json /app/deployment-source-manifest.json",
                     'test "$(id -u)" = 10001', '--expected-source-id "$WOONA_SOURCE_ID"',
                     "--manifest /app/deployment-source-manifest.json --uid 10001"):
        if fragment not in docker:
            raise ValueError(f"Missing image contract: {fragment}")


def validate_compose(shared: Path = ROOT.parent) -> None:
    for name in ('compose.yaml', 'compose.production.yaml', 'compose.label.yaml'):
        content = (shared / name).read_text()
        images = [value.split('#', 1)[0].strip() for value in
                  re.findall(r'^\s+image:\s*(.*?)\s*$', content, re.M)]
        if not images or any(not re.fullmatch(r'[A-Za-z0-9_./:-]+@sha256:[0-9a-f]{64}', image)
                             for image in images):
            raise ValueError('Compose images must use explicit immutable digests')
        if name != 'compose.yaml':
            if '  api:\n    build:\n      target: verified\n' not in content or \
                    '${WOONA_SOURCE_ID:?set the reviewed full source commit}' not in content:
                raise ValueError('Production API builds must require verified source provenance')
            if name == 'compose.label.yaml' and \
                    '      dockerfile: server/Dockerfile\n      target: verified\n' not in content:
                raise ValueError('Label-sync builds must use the same verified source')


if __name__ == "__main__":
    validate()
    validate_compose()
    print("Dependency lock/build static checks passed")
