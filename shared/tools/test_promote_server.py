"""Hermetic promotion tests. No real SSH, Docker daemon, credentials or data."""
import argparse
import base64
import copy
import gzip
import hashlib
import io
import json
import os
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import promote_server as p

SOURCE = "a" * 40
OLD_SOURCE = "b" * 40
OLD_IMAGE = "sha256:" + "c" * 64


def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def synthetic(path, *, compressed=False, mutate=None, extra=None, wrapped=False):
    layer = b"synthetic layer contents"
    config = {"os": "linux", "architecture": "amd64", "rootfs": {"type": "layers", "diff_ids": [digest(layer)]}}
    if mutate:
        mutate(config)
    config_raw = p.canonical(config)
    if compressed:
        layer = gzip.compress(layer)
    blobs = {}

    def descriptor(raw, kind):
        identity = digest(raw)
        blobs["blobs/sha256/" + identity[7:]] = raw
        return {"digest": identity, "size": len(raw), "mediaType": "application/vnd.oci.image." + kind}

    cfg = descriptor(config_raw, "config.v1+json")
    layers = [descriptor(layer, "layer.v1.tar" + ("+gzip" if compressed else ""))]
    manifest = descriptor(p.canonical({"schemaVersion": 2, "config": cfg, "layers": layers}), "manifest.v1+json")
    producer = manifest["digest"]
    root_manifest = manifest
    if wrapped:
        image = dict(manifest, platform={"os": "linux", "architecture": "amd64"})
        attestation = descriptor(p.canonical({"schemaVersion": 2, "config": cfg, "layers": []}), "manifest.v1+json")
        attestation.update(platform={"os": "unknown", "architecture": "unknown"},
                           annotations={"vnd.docker.reference.type": "attestation-manifest",
                                        "vnd.docker.reference.digest": manifest["digest"]})
        wrapper = descriptor(p.canonical({"schemaVersion": 2, "manifests": [image, attestation]}), "index.v1+json")
        producer = wrapper["digest"]
        root_manifest = wrapper
    blobs["oci-layout"] = p.canonical({"imageLayoutVersion": "1.0.0"})
    blobs["index.json"] = p.canonical({"schemaVersion": 2, "manifests": [root_manifest]})
    with tarfile.open(path, "w") as archive:
        for name, raw in blobs.items():
            info = tarfile.TarInfo(name)
            info.size = len(raw)
            archive.addfile(info, io.BytesIO(raw))
        if extra:
            info = tarfile.TarInfo(extra[0])
            info.type = extra[1]
            archive.addfile(info, io.BytesIO())
    return digest(path.read_bytes()), cfg["digest"], producer


def plan():
    return {"services": {service: {"current_image": OLD_IMAGE, "current_source": OLD_SOURCE,
                                   "rollback_image": OLD_IMAGE} for service in p.SERVICES},
            "schema_revision": "0009", "rollback_schema_compatible": True, "storage_compatible": True,
            "reviewed_source": SOURCE, "observation_seconds": 30,
            "compose_sha256": {n: digest(b"reviewed") for n in
                               ("compose.yaml", "compose.production.yaml", "compose.label.yaml")}}


class ArchiveTests(unittest.TestCase):
    def test_raw_and_compressed_identity_bridge(self):
        for compressed in (False, True):
            with self.subTest(compressed=compressed), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "image.tar"
                checksum, config, manifest = synthetic(path, compressed=compressed)
                self.assertEqual(p.image_binding(path, checksum, config),
                                 {"archive": checksum, "config": config, "manifest": manifest,
                                  "producer": config, "producer_kind": "configuration"})
                manifest_producer = p.image_binding(path, checksum, manifest)
                self.assertEqual(manifest_producer["producer_kind"], "platform-manifest")
                self.assertEqual(manifest_producer["config"], config)

    def test_buildx_wrapper_with_linked_attestation(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "image.tar"
            checksum, config, index = synthetic(path, compressed=True, wrapped=True)
            result = p.image_binding(path, checksum, index)
            self.assertEqual(result["producer"], index)
            self.assertEqual(result["producer_kind"], "image-index")
            self.assertEqual(result["config"], config)
            self.assertNotEqual(result["manifest"], index)
            self.assertEqual(p.image_binding(path, checksum, config)["producer_kind"], "configuration")

    def test_wrong_archive_or_producer(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "image.tar"
            checksum, config, _ = synthetic(path)
            for archive, producer in ((OLD_IMAGE, config), (checksum, OLD_IMAGE)):
                with self.subTest(archive=archive), self.assertRaises(p.Rejected):
                    p.image_binding(path, archive, producer)

    def test_unsafe_paths_links_duplicates_special_files(self):
        for name, kind in (("../escape", tarfile.REGTYPE), ("/escape", tarfile.REGTYPE),
                           ("a/../../escape", tarfile.REGTYPE), ("a\\escape", tarfile.REGTYPE),
                           ("symlink", tarfile.SYMTYPE), ("hardlink", tarfile.LNKTYPE),
                           ("fifo", tarfile.FIFOTYPE), ("index.json", tarfile.REGTYPE)):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "image.tar"
                checksum, config, _ = synthetic(path, extra=(name, kind))
                with self.assertRaises(p.Rejected):
                    p.image_binding(path, checksum, config)
                self.assertFalse((Path(tmp) / "escape").exists())

    def test_platform_diff_and_config_rejected(self):
        mutations = [lambda c: c.update(architecture="arm64"),
                     lambda c: c["rootfs"].update(diff_ids=[OLD_IMAGE]),
                     lambda c: c.update(os="windows"),
                     lambda c: c["rootfs"].update(type="other")]
        for mutate in mutations:
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "image.tar"
                checksum, config, _ = synthetic(path, mutate=mutate)
                with self.assertRaises(p.Rejected):
                    p.image_binding(path, checksum, config)

    def test_corrupted_blob_rejected_even_with_new_outer_checksum(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "image.tar"
            _, config, _ = synthetic(path)
            path.write_bytes(path.read_bytes().replace(b"synthetic layer contents", b"changedXX layer contents"))
            with self.assertRaises(p.Rejected):
                p.image_binding(path, digest(path.read_bytes()), config)

    def test_artifact_zip_rejects_unknown_traversal_duplicate_and_symlink(self):
        for name, mode in (("../escape", 0), ("unknown", 0), ("image-binding.json", 0o120777)):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                bundle = Path(tmp) / "artifact.zip"
                with zipfile.ZipFile(bundle, "w") as archive:
                    info = zipfile.ZipInfo(name)
                    info.external_attr = mode << 16
                    archive.writestr(info, "secret")
                with self.assertRaises(p.Rejected):
                    p.unpack_artifact(bundle, Path(tmp) / "out", digest(bundle.read_bytes()))
                self.assertFalse((Path(tmp) / "out").exists())

    def test_duplicate_json(self):
        with self.assertRaises(p.Rejected):
            p.decode(b'{"id":1,"id":2}')


class TrustTests(unittest.TestCase):
    def metadata(self):
        self.run_info = {"repository": {"full_name": p.REPO}, "head_repository": {"full_name": p.REPO},
                    "id": 12, "head_sha": SOURCE, "head_branch": "main", "event": "push", "status": "completed",
                    "conclusion": "success", "path": ".github/workflows/mobile.yml", "run_attempt": 1}
        self.jobs = {"total_count": 1, "jobs": [{"name": "server", "conclusion": "success"}]}
        self.artifact = {"id": 34, "name": "server-verified-image", "expired": False,
                         "workflow_run": {"id": 12, "head_sha": SOURCE}, "digest": OLD_IMAGE}

        def api(path):
            if "/jobs?" in path:
                return self.jobs
            return self.artifact if "/artifacts/" in path else self.run_info
        return api

    def test_trusted_success(self):
        api = self.metadata()
        self.assertEqual(p.trusted_metadata(12, 34, SOURCE, api), self.artifact)

    def test_reject_wrong_run_repository_source_ref_event_workflow_attempt_status(self):
        for key, value in (("repository", {"full_name": "evil/repo"}),
                           ("head_repository", {"full_name": "evil/repo"}), ("id", 11),
                           ("head_sha", OLD_SOURCE), ("head_branch", "feature"), ("event", "pull_request"),
                           ("status", "in_progress"), ("conclusion", "failure"),
                           ("path", ".github/workflows/evil.yml"), ("run_attempt", 2)):
            with self.subTest(key=key):
                api = self.metadata()
                self.run_info[key] = value
                with self.assertRaises(p.Rejected):
                    p.trusted_metadata(12, 34, SOURCE, api)

    def test_reject_artifact_mismatch_and_failed_skipped_server(self):
        for key, value in (("id", 35), ("name", "server-image-provenance"), ("expired", True),
                           ("workflow_run", {"id": 11, "head_sha": SOURCE}), ("digest", "missing")):
            with self.subTest(key=key):
                api = self.metadata()
                self.artifact[key] = value
                with self.assertRaises(p.Rejected):
                    p.trusted_metadata(12, 34, SOURCE, api)
        for result in ("skipped", "failure", "cancelled", None):
            api = self.metadata()
            self.jobs["jobs"][0]["conclusion"] = result
            with self.assertRaises(p.Rejected):
                p.trusted_metadata(12, 34, SOURCE, api)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        for name in plan()["compose_sha256"]:
            (Path(self.tmp.name) / name).write_bytes(b"reviewed")
        root = patch.object(p, "ROOT", self.tmp.name)
        root.start()
        self.addCleanup(root.stop)
        self.before = {s: [s + "-old", OLD_IMAGE, "running", 0] for s in (*p.SERVICES, "postgres", "caddy")}
        self.new_image = "sha256:" + "d" * 64
        self.after = copy.deepcopy(self.before)
        for s in p.SERVICES:
            self.after[s] = [s + "-new", self.new_image, "running", 0]
        self.observed = {"source_id": SOURCE, "manifest_sha256": "e" * 64, "schema_revision": "0009", "uid": 10001}
        self.payload = {"plan": plan(), "source": SOURCE, "bridge": {"config": self.new_image, "manifest": OLD_IMAGE, "producer": self.new_image},
                        "observation": self.observed}
        self.commands = []

    def command(self, args, **kwargs):
        self.commands.append((args, kwargs))
        if p.SCHEMA in args:
            return b'["0009"]'
        if "inspect" in args:
            return args[-1].encode()
        if "run" in args:
            return p.canonical(self.observed)
        if any("configured' if" in x for x in args):
            return b"absent\n"
        return b""

    def test_snapshot_uses_real_env_files_and_ignores_unrelated_team_env(self):
        calls = []

        def compose_and_inspect(args, **kwargs):
            calls.append((args, kwargs))
            if "ps" in args:
                return b'{"Service":"api","ID":"api-old"}\n{"Service":"label_sync","ID":"worker-old"}\n'
            return p.canonical([args[-1], OLD_IMAGE, "running", 0])

        with patch.object(p, "run", side_effect=compose_and_inspect):
            result = p.snapshot()
        args, kwargs = calls[0]
        self.assertEqual(args, p.COMPOSE + ["-f", "-", "ps", "--all", "--format", "json"])
        self.assertEqual([args[index + 1] for index, value in enumerate(args) if value == "--env-file"],
                         ["/opt/woona/shared/.env", "/opt/woona/shared/.env.label"])
        self.assertEqual(kwargs["data"], b"services:\n  filebrowser:\n    env_file: !reset []\n"
                                         b"  cloudbeaver:\n    env_file: !reset []\n")
        self.assertEqual(set(result), set(p.SERVICES))

    def test_dry_run_never_loads_starts_or_writes(self):
        with patch.object(p, "snapshot", return_value=self.before), patch.object(p, "probe", return_value=self.observed), \
                patch.object(p, "run", side_effect=self.command), patch.object(p.subprocess, "run") as process:
            result = p.remote(self.payload)
        self.assertEqual(result["status"], "preflight-only")
        process.assert_not_called()
        self.assertTrue(all(args[:2] == ["docker", "exec"] or args[:3] == ["docker", "image", "inspect"]
                            for args, _ in self.commands))
        self.assertIn((["docker", "image", "inspect", "--format", "{{.Id}}", OLD_IMAGE], {}), self.commands)
        self.assertEqual(sum(args[:3] == ["docker", "image", "inspect"] for args, _ in self.commands), 1)

    def test_mixed_role_baselines_preflight_and_apply_one_candidate(self):
        worker_image = "sha256:" + "1" * 64
        worker_source = "2" * 40
        self.payload["plan"]["services"]["label_sync"] = {
            "current_image": worker_image, "current_source": worker_source, "rollback_image": worker_image}
        self.before["label_sync"][1] = worker_image

        def role_probe(cid, source):
            expected = worker_source if cid == "label_sync-old" else OLD_SOURCE if cid == "api-old" else SOURCE
            self.assertEqual(source, expected)
            return dict(self.observed, source_id=source)

        def load(*args, **kwargs):
            inspected = [argv[-1] for argv, _ in self.commands if argv[:3] == ["docker", "image", "inspect"]]
            self.assertEqual(inspected, sorted([OLD_IMAGE, worker_image]))
            return subprocess.CompletedProcess([], 0)

        for apply in (False, True):
            self.commands.clear()
            snapshots = [self.before, self.before, self.after, self.after] if apply else [self.before]
            with self.subTest(apply=apply), patch.object(p, "snapshot", side_effect=snapshots), \
                    patch.object(p, "probe", side_effect=role_probe) as probes, patch.object(p, "run", side_effect=self.command), \
                    patch.object(p.subprocess, "run", side_effect=load) as process, \
                    patch.object(p.time, "monotonic", side_effect=[0, 31]):
                result = p.remote(self.payload, apply=apply)
            self.assertEqual(probes.call_args_list[0].args, ("api-old", OLD_SOURCE))
            self.assertEqual(probes.call_args_list[1].args, ("label_sync-old", worker_source))
            inspected = [argv[-1] for argv, _ in self.commands if argv[:3] == ["docker", "image", "inspect"]]
            self.assertEqual(inspected[:2], sorted([OLD_IMAGE, worker_image]))
            if apply:
                process.assert_called_once()
                self.assertEqual(result["image"], self.new_image)
                replacement = next(kwargs["data"].decode() for argv, kwargs in self.commands if "up" in argv)
                self.assertEqual(replacement.count(f'image: "{self.new_image}"'), 2)
            else:
                process.assert_not_called()
                self.assertEqual(len(inspected), 2)
                self.assertEqual(result["status"], "preflight-only")

    def test_each_mixed_role_rollback_must_exist_exactly_before_load(self):
        worker_image = "sha256:" + "1" * 64
        self.payload["plan"]["services"]["label_sync"]["current_image"] = worker_image
        self.payload["plan"]["services"]["label_sync"]["rollback_image"] = worker_image
        self.before["label_sync"][1] = worker_image
        for missing in (OLD_IMAGE, worker_image):
            def mismatch(args, *, missing=missing, **kwargs):
                if args[:3] == ["docker", "image", "inspect"] and args[-1] == missing:
                    return self.new_image.encode()
                return self.command(args, **kwargs)

            with self.subTest(missing=missing), patch.object(p, "snapshot", return_value=self.before), \
                    patch.object(p, "probe", return_value=self.observed), patch.object(p, "run", side_effect=mismatch), \
                    patch.object(p.subprocess, "run") as process, self.assertRaises(p.Rejected):
                p.remote(self.payload, apply=True)
            process.assert_not_called()
            self.assertFalse(any("up" in args for args, _ in self.commands))

    def test_missing_local_rollback_stops_before_image_load_or_replacement(self):
        def absent(args, **kwargs):
            if "inspect" in args and args[-1] == OLD_IMAGE:
                raise p.Rejected('external command failed (output suppressed)')
            return self.command(args, **kwargs)

        with patch.object(p, "snapshot", return_value=self.before), patch.object(p, "probe", return_value=self.observed), \
                patch.object(p, "run", side_effect=absent), patch.object(p.subprocess, "run") as process, \
                self.assertRaises(p.Rejected):
            p.remote(self.payload, apply=True)
        process.assert_not_called()
        self.assertFalse(any('up' in args for args, _ in self.commands))

    def test_runtime_changed_during_load_aborts_before_replacement_without_rollback(self):
        live = copy.deepcopy(self.before)

        def load(*args, **kwargs):
            live["api"][0] = "api-parallel-manual-deployment"
            return subprocess.CompletedProcess([], 0)

        with patch.object(p, "snapshot", side_effect=lambda: copy.deepcopy(live)) as snapshots, \
                patch.object(p, "probe", return_value=self.observed), patch.object(p, "run", side_effect=self.command), \
                patch.object(p.subprocess, "run", side_effect=load) as process, \
                self.assertRaisesRegex(p.Rejected, "runtime changed after preflight; separate review required"):
            p.remote(self.payload, apply=True)
        process.assert_called_once()
        self.assertEqual(process.call_args.args[0], ["docker", "image", "load"])
        self.assertEqual(snapshots.call_count, 2)
        self.assertTrue(any(args[:2] == ["docker", "run"] and p.PROBE in args for args, _ in self.commands))
        self.assertEqual(sum(args[:3] == ["docker", "image", "inspect"] and args[-1] == OLD_IMAGE
                             for args, _ in self.commands), 1)
        self.assertFalse(any(set(args) & {"up", "down", "stop", "restart", "rm", "downgrade"}
                             for args, _ in self.commands))

    def test_authenticated_smoke_uses_existing_me_endpoint(self):
        self.assertIn("http://127.0.0.1:8080/v1/me", p.AUTH)
        self.assertNotIn("/v1/accounts", p.AUTH)

    def test_apply_scoped_no_build_no_dependencies_direct_uvicorn_and_observe(self):
        with patch.object(p, "snapshot", side_effect=[self.before, self.before, self.after, self.after]), \
                patch.object(p, "probe", return_value=self.observed), patch.object(p, "run", side_effect=self.command), \
                patch.object(p.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                patch.object(p.time, "monotonic", side_effect=[0, 31]):
            result = p.remote(self.payload, apply=True)
        self.assertEqual(result["status"], "applied-observed")
        up = [(a, k) for a, k in self.commands if "up" in a]
        self.assertEqual(len(up), 1)
        args, kwargs = up[0]
        for flag in ("--no-build", "--no-deps", "--pull", "never", "--wait-timeout", "--timeout"):
            self.assertIn(flag, args)
        self.assertEqual(args[-2:], list(p.SERVICES))
        override = kwargs["data"].decode()
        self.assertTrue(override.startswith(p.compose_input().decode()))
        self.assertIn('entrypoint: ["uvicorn"]', override)
        self.assertIn("  label_sync:\n", override)
        self.assertNotIn("alembic", override)

    def test_consumer_store_transition_uses_only_proven_manifest_lookup(self):
        self.payload["bridge"]["config"] = "sha256:" + "f" * 64
        self.payload["bridge"]["manifest"] = self.new_image

        def consumer(args, **kwargs):
            if "inspect" in args and args[-1] == self.payload["bridge"]["config"]:
                raise p.Rejected("external command failed (output suppressed)")
            return self.command(args, **kwargs)

        with patch.object(p, "snapshot", side_effect=[self.before, self.before, self.after, self.after]), \
                patch.object(p, "probe", return_value=self.observed), patch.object(p, "run", side_effect=consumer), \
                patch.object(p.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                patch.object(p.time, "monotonic", side_effect=[0, 31]):
            result = p.remote(self.payload, apply=True)
        self.assertEqual(result["consumer_kind"], "platform-manifest")

    def test_consumer_store_transition_uses_proven_buildx_index_lookup(self):
        self.payload["bridge"].update(config="sha256:" + "f" * 64,
                                      manifest="sha256:" + "e" * 64,
                                      producer=self.new_image, producer_kind="image-index")

        def consumer(args, **kwargs):
            if "inspect" in args and args[-1] in (self.payload["bridge"]["config"],
                                                  self.payload["bridge"]["manifest"]):
                raise p.Rejected("external command failed (output suppressed)")
            return self.command(args, **kwargs)

        with patch.object(p, "snapshot", side_effect=[self.before, self.before, self.after, self.after]), \
                patch.object(p, "probe", return_value=self.observed), patch.object(p, "run", side_effect=consumer), \
                patch.object(p.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                patch.object(p.time, "monotonic", side_effect=[0, 31]):
            result = p.remote(self.payload, apply=True)
        self.assertEqual(result["consumer_kind"], "image-index")

    def test_candidate_uid_source_or_schema_mismatch_stops_before_replacement(self):
        for key, wrong in (("uid", 0), ("source_id", OLD_SOURCE), ("schema_revision", "0010")):
            bad = dict(self.observed, **{key: wrong})

            def consumer(args, *, bad=bad, **kwargs):
                if "run" in args:
                    return p.canonical(bad)
                return self.command(args, **kwargs)

            with self.subTest(key=key), patch.object(p, "snapshot", return_value=self.before), \
                    patch.object(p, "probe", return_value=self.observed), patch.object(p, "run", side_effect=consumer), \
                    patch.object(p.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), self.assertRaises(p.Rejected):
                p.remote(self.payload, apply=True)
            self.assertFalse(any("up" in args for args, _ in self.commands))

    def test_wrong_schema_or_current_image_stops_before_mutation(self):
        for wrong_schema in (False, True):
            before = copy.deepcopy(self.before)
            if not wrong_schema:
                before["api"][1] = self.new_image
            with self.subTest(schema=wrong_schema), patch.object(p, "snapshot", return_value=before), \
                    patch.object(p, "probe", return_value=self.observed), \
                    patch.object(p, "run", return_value=b'["0010"]'), patch.object(p.subprocess, "run") as process:
                with self.assertRaises(p.Rejected):
                    p.remote(self.payload, apply=True)
                process.assert_not_called()

    def test_unrelated_container_changed_or_worker_restarted_fail_no_rollback(self):
        for service in ("postgres", "label_sync"):
            changed = copy.deepcopy(self.after)
            if service == "postgres":
                changed[service][0] = "changed"
            else:
                changed[service][3] = 1
            with self.subTest(service=service), patch.object(p, "snapshot", side_effect=[self.before, self.before, self.after, changed]), \
                    patch.object(p, "probe", return_value=self.observed), patch.object(p, "run", side_effect=self.command), \
                    patch.object(p.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                    patch.object(p.time, "monotonic", return_value=0), self.assertRaises(p.Rejected):
                p.remote(self.payload, apply=True)
            self.assertFalse(any("down" in a or "rm" in a or "downgrade" in a for a, _ in self.commands))

    def test_bad_consumer_identity_does_not_replace_services(self):
        with patch.object(p, "snapshot", return_value=self.before), patch.object(p, "probe", return_value=self.observed), \
                patch.object(p, "run", side_effect=lambda a, **k: b'"sha256:bad"' if "inspect" in a and a[-1] != OLD_IMAGE else self.command(a, **k)), \
                patch.object(p.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), self.assertRaises(p.Rejected):
            p.remote(self.payload, apply=True)
        self.assertFalse(any("up" in a for a, _ in self.commands))

    def test_plan_migration_or_unreviewed_rollback_rejected(self):
        for key, value in (("schema_revision", "0010"), ("rollback_schema_compatible", False),
                           ("storage_compatible", False), ("rollback_image", self.new_image),
                           ("observation_seconds", 0), ("compose_sha256", {})):
            value_plan = plan()
            value_plan[key] = value
            with self.subTest(key=key), self.assertRaises(p.Rejected):
                p.validate_plan(value_plan)

    def test_strict_service_and_role_fieldsets_and_identities(self):
        malformed_services = [None, [], {}, {"api": plan()["services"]["api"]},
                              dict(plan()["services"], worker=plan()["services"]["label_sync"]),
                              {"api": plan()["services"]["api"], "unknown": plan()["services"]["label_sync"]}]
        for services in malformed_services:
            value_plan = plan()
            value_plan["services"] = services
            with self.subTest(services=services), self.assertRaises(p.Rejected):
                p.validate_plan(value_plan)
        for service in p.SERVICES:
            for field in ("current_image", "current_source", "rollback_image"):
                for wrong in (None, 123, True, "", "latest", "sha256:bad", self.new_image if field == "rollback_image" else "x" * 40):
                    value_plan = plan()
                    value_plan["services"][service][field] = wrong
                    with self.subTest(service=service, field=field, wrong=wrong), self.assertRaises(p.Rejected):
                        p.validate_plan(value_plan)
                value_plan = plan()
                del value_plan["services"][service][field]
                with self.subTest(service=service, missing=field), self.assertRaises(p.Rejected):
                    p.validate_plan(value_plan)
            for malformed in (None, [], dict(plan()["services"][service], unexpected=True)):
                value_plan = plan()
                value_plan["services"][service] = malformed
                with self.subTest(service=service, malformed=malformed), self.assertRaises(p.Rejected):
                    p.validate_plan(value_plan)
        for legacy_field, value in (("current_image", OLD_IMAGE), ("current_source", OLD_SOURCE), ("rollback_image", OLD_IMAGE)):
            value_plan = plan()
            value_plan[legacy_field] = value
            with self.subTest(legacy_field=legacy_field), self.assertRaises(p.Rejected):
                p.validate_plan(value_plan)

    def test_command_errors_redacted(self):
        with patch.object(p.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, b"secret", b"token=private")):
            with self.assertRaisesRegex(p.Rejected, "output suppressed") as error:
                p.run(["docker", "anything"])
            self.assertNotIn("private", str(error.exception))


class EntrypointTests(unittest.TestCase):
    def test_real_bundle_to_mocked_pinned_ssh_no_rebuild_and_no_archive_dryrun(self):
        for apply in (False, True):
            with self.subTest(apply=apply), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                archive = root / "image.tar"
                checksum, producer, _ = synthetic(archive)
                manifest = {"format": 1, "source_id": SOURCE, "schema_revision": "0009", "files": {
                    name: {"sha256": "0" * 64, "size": 0} for name in
                    ("server/app.py", "docs/target-server-plan/models/model.json", "testdata/test.json")}}
                manifest_hash = hashlib.sha256(p.canonical(manifest)).hexdigest()
                binding = {"source_id": SOURCE, "manifest_sha256": manifest_hash, "schema_revision": "0009",
                           "uid": 10001, "image_digest": producer}
                bundle = root / "bundle.zip"
                with zipfile.ZipFile(bundle, "w") as z:
                    z.write(archive, "server-image.tar")
                    z.writestr("SHA256SUMS", checksum[7:] + "  server-image.tar\n")
                    for name, value in (("source-manifest.json", manifest), ("image-binding.json", binding),
                                        ("reviewed-inputs.json", list(manifest["files"])), ("tree-verification.json", {})):
                        z.writestr(name, p.canonical(value))
                args = argparse.Namespace(run_id=12, artifact_id=34, source=SOURCE, bundle=str(bundle),
                                          work=str(root / "out"), evidence=str(root / "evidence.json"), apply=apply)
                env = {"GITHUB_REPOSITORY": p.REPO, "GITHUB_REF": "refs/heads/main",
                       "GITHUB_EVENT_NAME": "workflow_dispatch", "SERVER_PROMOTION_PLAN": json.dumps(plan()),
                       "SERVER_KNOWN_HOSTS_FILE": str(root / "known-hosts"), "SERVER_SSH_KEY_FILE": str(root / "key")}
                result = subprocess.CompletedProcess([], 0, p.canonical({"status": "test-result"}), b"")
                with patch.dict(os.environ, env), patch.object(p, "require_environment_approval"), \
                        patch.object(p, "trusted_metadata", return_value={"digest": digest(bundle.read_bytes())}), \
                        patch.object(p.subprocess, "run", return_value=result) as ssh:
                    p.promote(args)
                call = ssh.call_args
                command = call.args[0]
                self.assertEqual(command[0], "ssh")
                self.assertIn("StrictHostKeyChecking=yes", command)
                self.assertIn("IdentitiesOnly=yes", command)
                self.assertEqual(command[-2], p.TARGET)
                self.assertEqual("--apply" in command[-1], apply)
                payload = p.decode(base64.b64decode(command[-1].split(" remote ")[1].split()[0]))
                self.assertEqual(payload["bridge"]["producer"], producer)
                self.assertEqual(call.kwargs["stdin"] == subprocess.DEVNULL, not apply)
                evidence = json.loads(Path(args.evidence).read_text())
                self.assertEqual(evidence["producer_kind"], "configuration")
                self.assertNotIn("SERVER_SSH", Path(args.evidence).read_text())

    def test_actual_production_approval_required_not_just_environment_name(self):
        for reviews, accepted in (([], False), ([{"state": "approved", "environments": [{"name": "staging"}]}], False),
                                  ([{"state": "approved", "environments": [{"name": "production"}]}], True),
                                  ([{"state": "rejected", "environments": [{"name": "production"}]}], False)):
            with self.subTest(reviews=reviews), patch.dict(os.environ, {"GITHUB_RUN_ID": "123"}), \
                    patch.object(p, "github", return_value=reviews):
                if accepted:
                    p.require_environment_approval()
                else:
                    with self.assertRaises(p.Rejected):
                        p.require_environment_approval()

    def test_fork_or_nonmain_rejected_before_any_command(self):
        with patch.dict(os.environ, {"GITHUB_REPOSITORY": "evil/repo"}), patch.object(p.subprocess, "run") as process:
            with self.assertRaises(p.Rejected):
                p.promote(argparse.Namespace())
            process.assert_not_called()


class WorkflowTests(unittest.TestCase):
    def test_trusted_dispatch_pins_environment_and_default_preflight(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/deploy-server.yml").read_text()
        for expected in ("workflow_dispatch:", "default: false", "environment: production", "persist-credentials: false",
                         "cancel-in-progress: false", "queue: max", "StrictHostKeyChecking=yes"):
            self.assertIn(expected, workflow + Path(p.__file__).read_text())
        for forbidden in ("workflow_run:", "pull_request_target:", "contents: write", "ssh-keyscan", "docker build"):
            self.assertNotIn(forbidden, workflow)


if __name__ == "__main__":
    unittest.main()
