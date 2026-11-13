#!/usr/bin/env python3
"""One exact-image promotion entrypoint. Dry-run is production read-only; no migrations.

Only GitHub metadata/code artifacts leave CI. No database/storage transfer or backup.
See server/DEPLOYMENT_PROVENANCE.md for the protected environment review contract.
"""
from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile
import time
import urllib.request
import zipfile
from pathlib import Path

REPO = "Woona-Corp/woona-data-collector"
TARGET = "root@167.99.223.71"
ROOT = "/opt/woona/shared"
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
SOURCE = re.compile(r"[0-9a-f]{40}\Z")
LIMIT = 4 * 1024 * 1024
MAX_ARCHIVE = 4 * 1024**3
SERVICES = ("api", "label_sync")
COMPOSE = ["docker", "compose", "--project-directory", ROOT,
           "--env-file", ROOT + "/.env", "--env-file", ROOT + "/.env.label",
           "-f", ROOT + "/compose.yaml", "-f", ROOT + "/compose.production.yaml",
           "-f", ROOT + "/compose.label.yaml"]


def compose_input(services=None):
    lines = ["services:\n", "  filebrowser:\n    env_file: !reset []\n",
             "  cloudbeaver:\n    env_file: !reset []\n"]
    for name, values in (services or {}).items():
        lines.append(f"  {name}:\n")
        lines.extend(f"    {key}: {json.dumps(value, ensure_ascii=True)}\n" for key, value in values.items())
    return "".join(lines).encode()


class Rejected(ValueError):
    """Only fixed, redacted diagnostics may escape this boundary."""


def require(ok, reason):
    if not ok:
        raise Rejected(reason)


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def decode(raw):
    require(len(raw) <= LIMIT, "JSON evidence exceeds bound")
    return json.loads(raw, object_pairs_hook=pairs)


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()


def sha(stream, limit=MAX_ARCHIVE):
    digest = hashlib.sha256()
    count = 0
    while block := stream.read(1024 * 1024):
        count += len(block)
        require(count <= limit, "hashed input exceeds bound")
        digest.update(block)
    return "sha256:" + digest.hexdigest()


def run(argv, *, data=None, timeout=120):
    # Never expose Docker/SSH stderr: it can contain environment/URL credentials.
    result = subprocess.run(argv, input=data, capture_output=True,
                            timeout=timeout, check=False)
    require(result.returncode == 0, "external command failed (output suppressed)")
    require(len(result.stdout) <= LIMIT, "external evidence exceeds bound")
    return result.stdout


def safe_name(name):
    require(isinstance(name, str) and name and "\\" not in name and
            all(p and p not in (".", "..") for p in name.split("/")) and
            not name.startswith("/"), "unsafe archive member")


def image_binding(path, expected_archive, producer):
    """Prove producer config/index -> OCI platform manifest -> consumer identity.

    Never extract. Accept a direct linux/amd64 image or one Buildx index wrapper
    with one image and linked unknown/unknown attestations. Layers may be raw/gzip.
    All blobs (including unused extras) must be content-addressed and intact.
    """
    require(DIGEST.fullmatch(expected_archive) and DIGEST.fullmatch(producer), "invalid image digest")
    with open(path, "rb") as stream:
        require(sha(stream) == expected_archive, "archive checksum mismatch")
    with tarfile.open(path, "r:") as archive:
        members = {}
        for member in archive:
            name = member.name.rstrip("/") if member.isdir() else member.name
            safe_name(name)
            require(name not in members, "duplicate archive member")
            require((member.isfile() or member.isdir()) and member.sparse is None,
                    "archive links/special/sparse files rejected")
            require(member.size <= MAX_ARCHIVE, "archive member exceeds bound")
            members[name] = member
            require(len(members) <= 10000, "archive member count exceeds bound")

        def raw(name):
            require(name in members and members[name].isfile() and members[name].size <= LIMIT,
                    "missing or oversized archive metadata")
            stream = archive.extractfile(members[name])
            require(stream is not None, "missing archive stream")
            assert stream is not None
            return stream.read()

        require(decode(raw("oci-layout")) == {"imageLayoutVersion": "1.0.0"}, "unsupported archive layout")
        for name, member in members.items():
            if member.isfile() and name.startswith("blobs/"):
                require(re.fullmatch(r"blobs/sha256/[0-9a-f]{64}", name), "unsupported blob name")
                require(sha(archive.extractfile(member)) == "sha256:" + name.rsplit("/", 1)[1],
                        "archive blob hash mismatch")
            else:
                require(member.isdir() or name in ("oci-layout", "index.json", "manifest.json"),
                        "unexpected archive member")

        def blob(desc):
            require(isinstance(desc, dict) and DIGEST.fullmatch(desc.get("digest", "")) and
                    type(desc.get("size")) is int and desc["size"] >= 0, "invalid OCI descriptor")
            name = "blobs/sha256/" + desc["digest"][7:]
            require(name in members and members[name].isfile() and members[name].size == desc["size"],
                    "OCI descriptor size mismatch")
            return name

        index = decode(raw("index.json"))
        require(index.get("schemaVersion") == 2 and len(index.get("manifests", [])) == 1,
                "ambiguous OCI platform")
        descriptor = index["manifests"][0]
        producer_index = None
        if descriptor.get("mediaType") == "application/vnd.oci.image.index.v1+json":
            nested = decode(raw(blob(descriptor)))
            candidates = nested.get("manifests", [])
            require(nested.get("schemaVersion") == 2 and isinstance(candidates, list) and candidates,
                    "invalid Buildx image index")
            images = [item for item in candidates if item.get("platform") == {"os": "linux", "architecture": "amd64"}]
            require(len(images) == 1, "ambiguous OCI platform")
            selected = images[0]
            for item in candidates:
                if item is selected:
                    continue
                annotations = item.get("annotations", {})
                require(item.get("platform") == {"os": "unknown", "architecture": "unknown"} and
                        annotations.get("vnd.docker.reference.type") == "attestation-manifest" and
                        annotations.get("vnd.docker.reference.digest") == selected.get("digest"),
                        "unrelated Buildx manifest")
            producer_index = descriptor["digest"]
            descriptor = selected
        require(descriptor.get("mediaType") == "application/vnd.oci.image.manifest.v1+json",
                "unsupported platform manifest")
        manifest_digest = descriptor["digest"]
        manifest = decode(raw(blob(descriptor)))
        require(manifest.get("schemaVersion") == 2, "invalid OCI manifest")
        require(manifest["config"].get("mediaType") == "application/vnd.oci.image.config.v1+json",
                "unsupported config descriptor")
        config_digest = manifest["config"]["digest"]
        identities = {config_digest: "configuration", manifest_digest: "platform-manifest"}
        if producer_index is not None:
            identities[producer_index] = "image-index"
        require(producer in identities, "producer identity absent from archive chain")
        producer_kind = identities[producer]
        config = decode(raw(blob(manifest["config"])))
        require(config.get("os") == "linux" and config.get("architecture") == "amd64",
                "unsupported consumer platform")
        require(config.get("rootfs", {}).get("type") == "layers", "unsupported rootfs")
        diffs = config["rootfs"].get("diff_ids", [])
        layers = manifest.get("layers", [])
        require(len(layers) == len(diffs) and layers, "invalid layer chain")
        for layer, diff in zip(layers, diffs, strict=True):
            require(DIGEST.fullmatch(diff), "invalid diff identity")
            stream = archive.extractfile(members[blob(layer)])
            kind = layer.get("mediaType")
            require(kind in ("application/vnd.oci.image.layer.v1.tar", "application/vnd.oci.image.layer.v1.tar+gzip"),
                    "unsupported layer compression")
            if kind.endswith("+gzip"):
                stream = gzip.GzipFile(fileobj=stream)
            require(sha(stream) == diff, "layer diff identity mismatch")
        if "manifest.json" in members:
            legacy = decode(raw("manifest.json"))
            require(isinstance(legacy, list) and len(legacy) == 1 and
                    legacy[0].get("Config") == blob(manifest["config"]) and
                    legacy[0].get("Layers") == [blob(layer) for layer in layers],
                    "Docker compatibility manifest disagrees with OCI chain")
        return {"config": config_digest, "manifest": manifest_digest, "archive": expected_archive,
                "producer": producer, "producer_kind": producer_kind}


def github(path):
    request = urllib.request.Request("https://api.github.com/repos/" + REPO + path,
                                     headers={"Authorization": "Bearer " + os.environ["GH_TOKEN"],
                                              "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=30) as response:  # nosec B310: fixed HTTPS GitHub API only
        return decode(response.read(LIMIT + 1))


def trusted_metadata(run_id, artifact_id, source, api=github):
    require(SOURCE.fullmatch(source), "invalid exact source")
    info = api(f"/actions/runs/{run_id}")
    require(info.get("repository", {}).get("full_name") == REPO and info.get("head_repository", {}).get("full_name") == REPO,
            "untrusted producer repository")
    require(info.get("id") == run_id and info.get("head_sha") == source and info.get("head_branch") == "main" and
            info.get("event") in ("push", "workflow_dispatch") and info.get("status") == "completed" and
            info.get("conclusion") == "success" and info.get("path") == ".github/workflows/mobile.yml",
            "untrusted producer run/source")
    jobs = api(f"/actions/runs/{run_id}/attempts/{info['run_attempt']}/jobs?per_page=100")
    require(jobs.get("total_count", 101) <= 100, "producer jobs exceed bound")
    server = [j for j in jobs.get("jobs", []) if j.get("name") == "server"]
    require(len(server) == 1 and server[0].get("conclusion") == "success", "successful server job required")
    artifact = api(f"/actions/artifacts/{artifact_id}")
    require(artifact.get("id") == artifact_id and artifact.get("name") == "server-verified-image" and
            artifact.get("expired") is False and artifact.get("workflow_run", {}).get("id") == run_id and
            artifact.get("workflow_run", {}).get("head_sha") == source and
            DIGEST.fullmatch(artifact.get("digest", "")), "artifact identity/digest mismatch")
    # Re-runs reuse run IDs but artifacts cannot authenticate the producing attempt.
    require(info["run_attempt"] == 1, "rerun artifact producer attempt ambiguous")
    return artifact


def unpack_artifact(bundle, destination, expected_digest):
    with open(bundle, "rb") as stream:
        require(sha(stream) == expected_digest, "GitHub artifact digest mismatch")
    expected = {"server-image.tar", "SHA256SUMS", "source-manifest.json", "image-binding.json",
                "reviewed-inputs.json", "tree-verification.json"}
    with zipfile.ZipFile(bundle) as archive:
        infos = archive.infolist()
        require(len(infos) == len(expected) and {i.filename for i in infos} == expected,
                "unexpected artifact contents")
        for info in infos:
            safe_name(info.filename)
            require((info.external_attr >> 16) & 0o170000 in (0, 0o100000), "artifact special file rejected")
            require(info.file_size <= (MAX_ARCHIVE if info.filename == "server-image.tar" else LIMIT),
                    "artifact entry exceeds bound")
        destination.mkdir(mode=0o700)
        for info in infos:
            with archive.open(info) as src, (destination / info.filename).open("xb") as dst:
                while block := src.read(1024 * 1024):
                    dst.write(block)


PROBE = '''import json,os,sys
from alembic.config import Config
from alembic.script import ScriptDirectory
from server.deployment_provenance import load_json,verify_tree
m=load_json('/app/deployment-source-manifest.json')
u=os.getuid()
assert u==10001
status=open('/proc/1/status').read().splitlines()
assert [x.split()[1:] for x in status if x.startswith('Uid:')]==[['10001']*4]
h=ScriptDirectory.from_config(Config('/app/server/alembic.ini')).get_heads()
assert h==[m['schema_revision']]
v=verify_tree('/app',m,u,sys.argv[1])
print(json.dumps(dict(source_id=m['source_id'],manifest_sha256=v,schema_revision=m['schema_revision'],uid=u)))
'''
SCHEMA = '''import json
from sqlalchemy import create_engine,text
from server.app import DATABASE_URL
with create_engine(DATABASE_URL).connect() as c:
 c.execute(text('SET TRANSACTION READ ONLY'))
 print(json.dumps([r[0] for r in c.execute(text('SELECT version_num FROM alembic_version'))]))
'''
HEALTH = '''import urllib.request
for p in ('live','ready'):
 assert urllib.request.urlopen('http://127.0.0.1:8080/health/'+p,timeout=3).status==200
'''
# This reads only health/auth status, never response bodies; token stays in container.
AUTH = '''import os,urllib.request
r=urllib.request.Request('http://127.0.0.1:8080/v1/me',headers={'Authorization':'Bearer '+os.environ['WOONA_PROMOTION_SMOKE_TOKEN']})
assert urllib.request.urlopen(r,timeout=3).status==200
'''


def inspect_container(cid):
    # Select fields; full inspect contains secrets and must never enter evidence.
    return decode(run(["docker", "inspect", "--format",
                       '[{{json .Id}},{{json .Image}},{{json .State.Status}},{{json .RestartCount}}]', cid]))


def snapshot():
    ids = run(COMPOSE + ["-f", "-", "ps", "--all", "--format", "json"], data=compose_input())
    # Compose emits one object per line (older versions may emit an array).
    text = ids.decode().strip()
    rows = json.loads(text) if text.startswith("[") else [decode(line.encode()) for line in text.splitlines() if line]
    result = {}
    for row in rows:
        service = row["Service"]
        require(service not in result, "scaled or duplicate service rejected")
        result[service] = inspect_container(row["ID"])
    require(all(s in result for s in SERVICES), "required production services missing")
    return result


def probe(cid, source):
    return decode(run(["docker", "exec", cid, "python", "-B", "-c", PROBE, source]))


def validate_plan(plan):
    require(isinstance(plan, dict) and set(plan) == {"services", "schema_revision",
            "rollback_schema_compatible", "storage_compatible", "reviewed_source", "observation_seconds", "compose_sha256"},
            "invalid protected review plan")
    require(isinstance(plan["services"], dict) and set(plan["services"]) == set(SERVICES),
            "exact reviewed service baselines required")
    for service in SERVICES:
        baseline = plan["services"][service]
        require(isinstance(baseline, dict) and set(baseline) == {"current_image", "current_source", "rollback_image"},
                "invalid service baseline fields")
        require(isinstance(baseline["current_image"], str) and DIGEST.fullmatch(baseline["current_image"]) and
                isinstance(baseline["rollback_image"], str) and DIGEST.fullmatch(baseline["rollback_image"]) and
                isinstance(baseline["current_source"], str) and SOURCE.fullmatch(baseline["current_source"]),
                "invalid service baseline identity")
        require(baseline["rollback_image"] == baseline["current_image"], "reviewed role rollback must match current image")
    require(isinstance(plan["reviewed_source"], str) and SOURCE.fullmatch(plan["reviewed_source"]), "invalid plan identity")
    require(plan["rollback_schema_compatible"] is True and plan["storage_compatible"] is True and
            plan["schema_revision"] == "0009", "separate owner compatibility plan required")
    require(type(plan["observation_seconds"]) is int and 30 <= plan["observation_seconds"] <= 300,
            "bounded worker observation required")
    require(isinstance(plan["compose_sha256"], dict) and set(plan["compose_sha256"]) ==
            {"compose.yaml", "compose.production.yaml", "compose.label.yaml"} and
            all(DIGEST.fullmatch(v) for v in plan["compose_sha256"].values()), "reviewed Compose identity required")


def remote(payload, apply=False):
    plan = payload["plan"]
    validate_plan(plan)
    require(payload["source"] == plan["reviewed_source"], "source not reviewed by environment owner")
    for name, digest in plan["compose_sha256"].items():
        path = Path(ROOT) / name
        require(path.is_file() and not path.is_symlink(), "unsafe production Compose file")
        with path.open("rb") as stream:
            require(sha(stream) == digest, "production Compose differs from reviewed configuration")
    before = snapshot()
    for service in SERVICES:
        item = before[service]
        baseline = plan["services"][service]
        require(item[1] == baseline["current_image"] and item[2] == "running", "runtime baseline mismatch")
        observed = probe(item[0], baseline["current_source"])
        require(observed["schema_revision"] == plan["schema_revision"], "runtime schema mismatch")
    require(decode(run(["docker", "exec", before["api"][0], "python", "-B", "-c", SCHEMA])) ==
            [plan["schema_revision"]], "database schema mismatch; separate owner migration plan required")
    run(["docker", "exec", before["api"][0], "python", "-B", "-c", HEALTH])
    for rollback_image in sorted({baseline["rollback_image"] for baseline in plan["services"].values()}):
        rollback = run(["docker", "image", "inspect", "--format", "{{.Id}}", rollback_image]).decode().strip()
        require(rollback == rollback_image, "reviewed local rollback image unavailable")
    if not apply:
        return {"status": "preflight-only", "schema": plan["schema_revision"], "services": list(SERVICES)}
    # docker load is the first remote mutation. Archive arrives only after preflight.
    loaded = subprocess.run(["docker", "image", "load"], stdin=sys.stdin.buffer,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300, check=False)
    require(loaded.returncode == 0, "consumer image load failed")
    bridge = payload["bridge"]
    image = None
    # Stores may index config, platform-manifest, or Buildx image-index IDs.
    # Inspect only identities independently proven by the archive, never a tag.
    identities = {bridge["config"]: "configuration", bridge["manifest"]: "platform-manifest"}
    if bridge.get("producer_kind") == "image-index":
        identities[bridge["producer"]] = "image-index"
    for lookup in identities:
        try:
            image = run(["docker", "image", "inspect", "--format", "{{.Id}}", lookup]).decode().strip()
        except Rejected:
            continue
        require(image in identities, "consumer identity not proven by archive")
        break
    require(image is not None, "loaded consumer identity unavailable")
    observed = decode(run(["docker", "run", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL",
                           "--entrypoint", "python", image, "-B", "-c", PROBE, payload["source"]]))
    require(observed == payload["observation"], "consumer tree/UID/schema mismatch")
    override = {"services": {
        "api": {"image": image, "entrypoint": ["uvicorn"], "command": ["server.app:app", "--host", "0.0.0.0", "--port", "8080"],  # nosec B104: container-only; reviewed Compose publishes loopback
                "environment": {"WOONA_PROMOTION_SMOKE_TOKEN": "${WOONA_PROMOTION_SMOKE_TOKEN}"}},
        "label_sync": {"image": image, "entrypoint": ["python"], "command": ["-B", "-m", "server.label_sync"]}}}
    require(snapshot() == before, "runtime changed after preflight; separate review required")
    run(COMPOSE + ["-f", "-", "up", "-d", "--no-build", "--no-deps", "--pull", "never",
                   "--wait", "--wait-timeout", "90", "--timeout", "30", *SERVICES],
        data=compose_input(override["services"]), timeout=150)
    # No automatic rollback. A failure stops clients; operator reviews current schema first.
    deadline = time.monotonic() + plan["observation_seconds"]
    after = snapshot()
    while True:
        current = snapshot()
        require(set(current) == set(before), "production service set changed")
        for service, item in current.items():
            if service not in SERVICES:
                require(item[0] == before[service][0], "unrelated container changed")
            else:
                require(item[0] == after[service][0] and item[1] == image and item[2] == "running" and item[3] == 0,
                        "worker/API not stable during observation")
                require(probe(item[0], payload["source"]) == observed, "running source verification failed")
        run(["docker", "exec", current["api"][0], "python", "-B", "-c", HEALTH])
        require(decode(run(["docker", "exec", current["api"][0], "python", "-B", "-c", SCHEMA])) ==
                [plan["schema_revision"]], "post-deploy schema changed")
        if time.monotonic() >= deadline:
            break
        time.sleep(5)
    # Only use a real, explicitly configured container token; no fallback/debug token.
    auth = run(["docker", "exec", current["api"][0], "python", "-B", "-c",
                "import os; print('configured' if os.environ.get('WOONA_PROMOTION_SMOKE_TOKEN') else 'absent')"]).strip()
    if auth == b"configured":
        run(["docker", "exec", current["api"][0], "python", "-B", "-c", AUTH])
    return {"status": "applied-observed", "source": payload["source"], "image": image,
            "consumer_kind": identities[image],
            "schema": plan["schema_revision"], "worker": "running-stable-not-functional-proof",
            "authenticated_smoke": "passed" if auth == b"configured" else "not-configured",
            "unrelated_container_ids": "unchanged", "rollback": "not-exercised-no-automatic-action"}


def require_environment_approval():
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    require(run_id.isdecimal(), "current workflow run identity missing")
    reviews = github(f"/actions/runs/{run_id}/approvals")
    require(isinstance(reviews, list), "environment approval evidence missing")
    relevant = [r for r in reviews if any(e.get("name") == "production" for e in r.get("environments", []))]
    require(relevant and any(r.get("state") == "approved" for r in relevant) and
            not any(r.get("state") == "rejected" for r in relevant), "production environment approval required")


def promote(args):
    require(os.environ.get("GITHUB_REPOSITORY") == REPO and os.environ.get("GITHUB_REF") == "refs/heads/main" and
            os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch", "trusted main dispatch required")
    # Environment names alone do not prove approval: an unprotected environment
    # auto-starts jobs. Require actual GitHub approval history, fail closed on 403.
    require_environment_approval()
    artifact = trusted_metadata(args.run_id, args.artifact_id, args.source)
    root = Path(args.work)
    unpack_artifact(Path(args.bundle), root, artifact["digest"])
    manifest = decode((root / "source-manifest.json").read_bytes())
    binding = decode((root / "image-binding.json").read_bytes())
    # Reuse canonical source-manifest and observation implementation, not a second validator.
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from server.deployment_provenance import compare_observation
    compare_observation(manifest, binding, args.source, binding["image_digest"])
    checksum = (root / "SHA256SUMS").read_text()
    require(re.fullmatch(r"[0-9a-f]{64}  server-image.tar\n", checksum), "invalid archive checksum file")
    bridge = image_binding(root / "server-image.tar", "sha256:" + checksum[:64], binding["image_digest"])
    plan = decode(os.environ["SERVER_PROMOTION_PLAN"].encode())
    validate_plan(plan)
    require(plan["reviewed_source"] == args.source and manifest["schema_revision"] == plan["schema_revision"],
            "candidate not compatible with owner review")
    observation = {k: v for k, v in binding.items() if k != "image_digest"}
    payload = {"source": args.source, "bridge": bridge, "plan": plan, "observation": observation}
    # Fixed host, no agent forwarding, no dynamic keyscan/TOFU, secrets never in argv.
    ssh = ["ssh", "-T", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
           "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes",
           "-o", "UserKnownHostsFile=" + os.environ["SERVER_KNOWN_HOSTS_FILE"], "-o", "IdentitiesOnly=yes",
           "-o", "ForwardAgent=no", "-i", os.environ["SERVER_SSH_KEY_FILE"], TARGET]
    code = base64.b64encode(Path(__file__).read_bytes()).decode()
    encoded = base64.b64encode(canonical(payload)).decode()
    command = ("python3 -B -c \"import base64;exec(base64.b64decode('" + code + "'))\" remote " + encoded)
    if args.apply:
        command += " --apply"
    with (root / "server-image.tar").open("rb") as stream:
        result = subprocess.run(ssh + [command], stdin=stream if args.apply else subprocess.DEVNULL,
                                capture_output=True, timeout=900, check=False)
    require(result.returncode == 0 and len(result.stdout) <= LIMIT, "remote promotion rejected (output suppressed)")
    evidence = decode(result.stdout)
    evidence.update(run_id=args.run_id, artifact_id=args.artifact_id, source=args.source,
                    archive=bridge["archive"], configuration_digest=bridge["config"], platform_manifest=bridge["manifest"],
                    producer_image=bridge["producer"], producer_kind=bridge["producer_kind"])
    Path(args.evidence).write_bytes(canonical(evidence))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--artifact-id", type=int, required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        promote(args)
    except Exception:
        Path(args.evidence).write_bytes(canonical({"status": "rejected", "apply_requested": args.apply,
                                                 "production_state": "not-assumed-rollback-not-automatic"}))
        print("Promotion rejected; no credentials or command output retained.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "remote":
        try:
            print(canonical(remote(decode(base64.b64decode(sys.argv[2])), "--apply" in sys.argv[3:])).decode(), end="")
        except Exception:
            print("Promotion stopped; owner review required.", file=sys.stderr)
            sys.exit(1)
    else:
        sys.exit(main())
