"""Read-only Linux/POSIX source inventory and deployment evidence checks (stdlib only).

No Docker, subprocesses, environment lookup, network, database or storage access.
The three public COPY scopes are deliberately fixed; see DEPLOYMENT_PROVENANCE.md.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import PurePosixPath
import re
import stat
import sys

SCOPES = ("server", "docs/target-server-plan/models", "testdata")
SUFFIXES = {".py", ".ini", ".mako", ".toml", ".lock", ".sh", ".yaml", ".json", ".sql", ".md"}
SPECIAL_NAMES = {"Dockerfile", "Caddyfile", "Caddyfile.label"}
HASH = re.compile(r"[0-9a-f]{64}\Z")
SOURCE = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?\Z")
REVISION = re.compile(r"[A-Za-z0-9_]{1,80}\Z")


class Rejected(ValueError):
    """Safe diagnostic: never includes file contents or untrusted values."""


def require(condition, message):
    if not condition:
        raise Rejected(message)


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode("ascii")


def manifest_id(manifest):
    validate_manifest(manifest)
    return hashlib.sha256(canonical(manifest)).hexdigest()


def public_path(path):
    require(isinstance(path, str) and path and "\\" not in path, "invalid public path")
    parts = path.split("/")
    require(all(p and p not in {".", ".."} and not p.startswith(".") for p in parts), "invalid public path")
    require(any(path.startswith(scope + "/") for scope in SCOPES), "path outside public scopes")
    require(PurePosixPath(path).suffix in SUFFIXES or parts[-1] in SPECIAL_NAMES, "unsupported public input")
    require(not any(p in {"data", "storage", "credentials", "secrets", "__pycache__"} for p in parts), "non-public input")
    return path


def exact_keys(value, keys):
    require(isinstance(value, dict) and set(value) == set(keys), "invalid object fields")


def validate_manifest(value):
    exact_keys(value, ("format", "source_id", "schema_revision", "files"))
    require(type(value["format"]) is int and value["format"] == 1, "unsupported manifest format")
    require(isinstance(value["source_id"], str) and SOURCE.fullmatch(value["source_id"]), "invalid source id")
    require(isinstance(value["schema_revision"], str) and REVISION.fullmatch(value["schema_revision"]), "invalid schema revision")
    files = value["files"]
    require(isinstance(files, dict) and bool(files), "empty or invalid file inventory")
    require(all(isinstance(p, str) for p in files), "invalid public path")
    require(all(any(p.startswith(s + "/") for p in files) for s in SCOPES), "missing public scope")
    for path, entry in files.items():
        public_path(path)
        exact_keys(entry, ("sha256", "size"))
        require(isinstance(entry["sha256"], str) and HASH.fullmatch(entry["sha256"]), "invalid file hash")
        require(type(entry["size"]) is int and entry["size"] >= 0, "invalid file size")


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def load_json(path):
    # Explicit regular JSON evidence only; no symlinks, FIFOs or config discovery.
    path = os.fspath(path)
    require(".." not in path.split("/"), "evidence traversal rejected")
    parent, name = os.path.split(path)
    require(name.endswith(".json") and not name.startswith("."), "evidence must be a public JSON file")
    with directory(parent or ".") as parent_fd:
        with relative_fd(parent_fd, name) as fd:
            require(stat.S_ISREG(os.fstat(fd).st_mode), "evidence must be regular")
            with os.fdopen(os.dup(fd), "rb") as stream:
                raw = stream.read(4 * 1024 * 1024 + 1)
    require(len(raw) <= 4 * 1024 * 1024, "evidence file too large")
    return json.loads(raw, object_pairs_hook=_pairs)


@contextmanager
def directory(root):
    # Walk all components without following even intermediate symlinks.
    path = os.path.abspath(root)
    require(".." not in os.fspath(root).split("/"), "root traversal rejected")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.split("/"):
            if part:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = child
        yield fd
    finally:
        os.close(fd)


@contextmanager
def relative_fd(root_fd, path, is_directory=False):
    fd = os.dup(root_fd)
    try:
        parts = path.split("/")
        for i, part in enumerate(parts):
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            if i < len(parts) - 1 or is_directory:
                flags |= os.O_DIRECTORY
            child = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = child
        yield fd
    finally:
        os.close(fd)


def readable(info, uid, is_directory=False):
    # Conservative: no supplementary groups, ACLs, capabilities or root override.
    shift = 6 if info.st_uid == uid else 0
    needed = 5 if is_directory else 4
    return ((stat.S_IMODE(info.st_mode) >> shift) & needed) == needed


def inventory(root_fd, uid=None):
    found = set()

    def walk(fd, prefix):
        if uid is not None:
            require(readable(os.fstat(fd), uid, True), "public directory not readable/searchable by runtime UID")
        with os.scandir(fd) as entries:
            for entry in sorted(entries, key=lambda e: e.name):
                info = entry.stat(follow_symlinks=False)
                require(not stat.S_ISLNK(info.st_mode), "symlink in public scope")
                # Python bytecode is not a build input. Never traverse or hash it.
                if entry.name == "__pycache__" and stat.S_ISDIR(info.st_mode):
                    continue
                path = prefix + "/" + entry.name
                if stat.S_ISDIR(info.st_mode):
                    require(not entry.name.startswith(".") and entry.name not in {"data", "storage", "credentials", "secrets"}, "non-public directory in public scope")
                    with relative_fd(fd, entry.name, True) as child:
                        walk(child, path)
                else:
                    require(stat.S_ISREG(info.st_mode), "non-regular public input")
                    public_path(path)
                    if uid is not None:
                        require(readable(info, uid), "public input not readable by runtime UID")
                    found.add(path)

    if uid is not None:
        require(readable(os.fstat(root_fd), uid, True), "public root not readable/searchable by runtime UID")
    for scope in SCOPES:
        # Check every intermediate directory, not just each COPY destination.
        parts = scope.split("/")
        for i in range(1, len(parts)):
            with relative_fd(root_fd, "/".join(parts[:i]), True) as parent:
                if uid is not None:
                    require(readable(os.fstat(parent), uid, True), "public parent not searchable by runtime UID")
        with relative_fd(root_fd, scope, True) as fd:
            walk(fd, scope)
    return found


def hash_file(root_fd, path):
    with relative_fd(root_fd, path) as fd:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode), "non-regular public input")
        digest = hashlib.sha256()
        size = 0
        while block := os.read(fd, 1024 * 1024):
            size += len(block)
            digest.update(block)
        after = os.fstat(fd)
        require((before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_size, after.st_mtime_ns, after.st_ctime_ns) and size == after.st_size,
                "input changed while hashing")
        return {"sha256": digest.hexdigest(), "size": size}


def create_manifest(root, inputs, source_id, schema_revision):
    require(isinstance(inputs, list) and bool(inputs), "reviewed inputs must be a nonempty JSON array")
    for path in inputs:
        public_path(path)
    require(len(set(inputs)) == len(inputs), "duplicate reviewed input")
    value = {"format": 1, "source_id": source_id, "schema_revision": schema_revision,
             "files": {p: {"sha256": "0" * 64, "size": 0} for p in inputs}}
    validate_manifest(value)
    with directory(root) as fd:
        require(inventory(fd) == set(inputs), "missing or extra public inputs; review inventory")
        value["files"] = {p: hash_file(fd, p) for p in sorted(inputs)}
    return value


def verify_tree(root, manifest, uid=None, expected_source_id=None):
    validate_manifest(manifest)
    if expected_source_id is not None:
        require(isinstance(expected_source_id, str) and SOURCE.fullmatch(expected_source_id), "invalid expected source id")
        require(manifest["source_id"] == expected_source_id, "source id mismatch")
    if uid is not None:
        require(type(uid) is int and uid > 0, "invalid runtime UID")
    with directory(root) as fd:
        require(inventory(fd, uid) == set(manifest["files"]), "missing or extra public inputs")
        for path, expected in manifest["files"].items():
            require(hash_file(fd, path) == expected, "public input hash/size mismatch")
    return manifest_id(manifest)


def compare_observation(manifest, observed, expected_source, expected_image, expected_uid=10001):
    validate_manifest(manifest)
    exact_keys(observed, ("image_digest", "source_id", "manifest_sha256", "schema_revision", "uid"))
    require(isinstance(expected_image, str) and expected_image.startswith("sha256:") and
            HASH.fullmatch(expected_image[7:]), "invalid expected image digest")
    require(type(expected_uid) is int and expected_uid > 0, "invalid expected UID")
    require(manifest["source_id"] == expected_source == observed["source_id"], "source id mismatch")
    require(observed["image_digest"] == expected_image, "image digest mismatch")
    require(observed["manifest_sha256"] == manifest_id(manifest), "manifest identity mismatch")
    require(observed["schema_revision"] == manifest["schema_revision"], "schema revision incompatible; no migration attempted")
    require(type(observed["uid"]) is int and observed["uid"] == expected_uid, "runtime UID mismatch")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("manifest", help="emit canonical manifest for explicit reviewed inputs")
    create.add_argument("--root", required=True)
    create.add_argument("--inputs", required=True, help="reviewed JSON array; outside COPY scopes")
    create.add_argument("--source-id", required=True, help="reviewed full Git commit id; not inferred")
    create.add_argument("--schema-revision", required=True)
    verify = commands.add_parser("verify", help="verify public bytes; optionally conservative UID readability")
    verify.add_argument("--root", required=True)
    verify.add_argument("--manifest", required=True)
    verify.add_argument("--uid", type=int)
    verify.add_argument("--expected-source-id", help="require exact full source id before reading public bytes")
    compare = commands.add_parser("compare", help="compare explicit read-only deployment observations")
    compare.add_argument("--manifest", required=True)
    compare.add_argument("--observed", required=True)
    compare.add_argument("--expected-source-id", required=True)
    compare.add_argument("--expected-image-digest", required=True)
    compare.add_argument("--expected-uid", type=int, default=10001)
    args = parser.parse_args(argv)
    try:
        if args.command == "manifest":
            result = create_manifest(args.root, load_json(args.inputs), args.source_id, args.schema_revision)
        elif args.command == "verify":
            result = {"ok": True, "manifest_sha256": verify_tree(args.root, load_json(args.manifest), args.uid, args.expected_source_id)}
        else:
            manifest = load_json(args.manifest)
            compare_observation(manifest, load_json(args.observed), args.expected_source_id,
                                args.expected_image_digest, args.expected_uid)
            result = {"ok": True, "manifest_sha256": manifest_id(manifest)}
        sys.stdout.buffer.write(canonical(result))
        return 0
    except Rejected as error:
        # All Rejected messages are fixed strings, never evidence values or paths.
        print(f"provenance check rejected: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, TypeError, RecursionError):
        # Do not echo parser/file errors, evidence values, paths, or sensitive content.
        print("provenance check rejected: invalid or inaccessible evidence/inputs", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
