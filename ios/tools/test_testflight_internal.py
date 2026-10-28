"""No-network policy and read-back tests for internal-only TestFlight operations."""
import copy
import json
import unittest
from unittest.mock import patch

from testflight_internal import AppleClient, SafetyError, jose_signature, run


def row(kind, identity, **attrs):
    return {"type": kind, "id": identity, "attributes": attrs}


class FakeApple:
    def __init__(self):
        self.app = row("apps", "app-1", bundleId="com.woona.apps")
        self.build = row("builds", "build-150", version="15001", processingState="VALID", expired=False)
        self.build["relationships"] = {"preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": "release-15"}}}
        self.release = row("preReleaseVersions", "release-15", version="1.5.0", platform="IOS")
        self.groups = [row("betaGroups", "internal-1", isInternalGroup=True, name="Private group"),
                       row("betaGroups", "external-1", isInternalGroup=False, name="External group")]
        self.assigned = set()
        self.writes = []
        self.gets = []
        self.extra_build = False
        self.app_owner = self.app
        self.group_owner = self.app
        self.group_validation_count = 0
        self.turn_external_at = None
        self.next_link = None
        self.list_total = None
        self.internal_state_override = None
        self.readback_lies = False
        self.processing_sequence = []

    def get(self, path, query=None):
        self.gets.append((path, query))
        if path == "/v1/apps":
            return {"data": [copy.deepcopy(self.app)]}
        if path == "/v1/builds":
            if self.processing_sequence:
                self.build["attributes"]["processingState"] = self.processing_sequence.pop(0)
            data = [copy.deepcopy(self.build)] if self.build is not None else []
            if self.extra_build:
                data.append(row("builds", "another-build"))
            return {"data": data, "included": [copy.deepcopy(self.release)], "links": {"next": self.next_link},
                    "meta": {"paging": {"total": self.list_total}}}
        if path == "/v1/builds/build-150/app":
            return {"data": copy.deepcopy(self.app_owner)}
        if path == "/v1/apps/app-1/betaGroups":
            return {"data": copy.deepcopy(self.groups)}
        if path == "/v1/builds/build-150/betaGroups":
            return {"data": [copy.deepcopy(g) for g in self.groups if g["id"] in self.assigned]}
        if path == "/v1/builds/build-150/buildBetaDetail":
            state = "IN_BETA_TESTING" if self.assigned else "READY_FOR_BETA_TESTING"
            state = self.internal_state_override or state
            return {"data": row("buildBetaDetails", "detail-1", internalBuildState=state)}
        for group in self.groups:
            if path == "/v1/betaGroups/" + group["id"]:
                self.group_validation_count += 1
                answer = copy.deepcopy(group)
                if self.turn_external_at == self.group_validation_count:
                    answer["attributes"]["isInternalGroup"] = False
                return {"data": answer}
            if path == "/v1/betaGroups/" + group["id"] + "/app":
                return {"data": copy.deepcopy(self.group_owner)}
            if path == "/v1/betaGroups/" + group["id"] + "/betaTesters":
                return {"data": [row("betaTesters", "tester-1", email="private@example.invalid", firstName="Private")],
                        "meta": {"paging": {"total": 2}}}
        raise AssertionError("Unexpected GET " + path)

    def assign_build(self, group_id, build_id):
        self.writes.append(("POST", "/v1/betaGroups/" + group_id + "/relationships/builds",
                            {"data": [{"type": "builds", "id": build_id}]}))
        if not self.readback_lies:
            self.assigned.add(group_id)


class InternalTestFlightTests(unittest.TestCase):
    def setUp(self):
        self.client = FakeApple()

    def check(self, **kwargs):
        return run(self.client, "1.5.0", "15001", attempts=3, pause=lambda _: None, **kwargs)

    def assertBlocked(self, **kwargs):
        with self.assertRaises(SafetyError):
            self.check(**kwargs)
        self.assertEqual([], self.client.writes)

    def test_default_is_read_only_even_when_valid_build_is_not_assigned(self):
        report = self.check()
        self.assertFalse(report["assignment_requested"])
        self.assertFalse(report["available_for_internal_testers"])
        self.assertEqual([], self.client.writes)

    def test_read_only_confirms_exact_internal_availability_without_printing_testers(self):
        self.client.assigned.add("internal-1")
        report = self.check()
        self.assertTrue(report["available_for_internal_testers"])
        self.assertFalse(report["physical_installation_verified"])
        self.assertEqual([{ "id": "internal-1", "tester_count": 2, "assigned": True}], report["internal_groups"])
        output = json.dumps(report)
        for private in ("private@example.invalid", "Private group", "External group", "external-1"):
            self.assertNotIn(private, output)
        self.assertEqual([], self.client.writes)

    def test_assignment_only_posts_explicit_internal_build_relationship_and_reads_back(self):
        report = self.check(assign_internal=True, group_ids=("internal-1",))
        self.assertEqual([("POST", "/v1/betaGroups/internal-1/relationships/builds",
                           {"data": [{"type": "builds", "id": "build-150"}]})], self.client.writes)
        self.assertTrue(report["available_for_internal_testers"])
        self.assertGreaterEqual(self.client.group_validation_count, 2)
        self.assertEqual(2, sum(path == "/v1/builds/build-150/betaGroups" for path, _ in self.client.gets))

    def test_already_assigned_internal_build_needs_no_write(self):
        self.client.assigned.add("internal-1")
        self.assertTrue(self.check(assign_internal=True, group_ids=("internal-1",))["available_for_internal_testers"])
        self.assertEqual([], self.client.writes)

    def test_explicit_external_target_is_blocked_before_any_assignment(self):
        self.assertBlocked(assign_internal=True, group_ids=("internal-1", "external-1"))

    def test_group_becoming_external_immediately_before_post_is_blocked(self):
        self.client.turn_external_at = 2
        self.assertBlocked(assign_internal=True, group_ids=("internal-1",))

    def test_internal_group_from_another_app_is_blocked(self):
        self.client.group_owner = row("apps", "other-app", bundleId="com.woona.apps")
        self.assertBlocked(assign_internal=True, group_ids=("internal-1",))

    def test_no_internal_groups_is_blocked(self):
        self.client.groups = [self.client.groups[1]]
        self.assertBlocked()

    def test_assignment_requires_explicit_unique_group_ids(self):
        self.assertBlocked(assign_internal=True)
        self.assertBlocked(assign_internal=True, group_ids=("internal-1", "internal-1"))

    def test_duplicate_builds_are_ambiguous_and_blocked(self):
        self.client.extra_build = True
        self.assertBlocked(assign_internal=True, group_ids=("internal-1",))

    def test_truncated_build_page_is_blocked(self):
        self.client.next_link = "https://api.appstoreconnect.apple.com/v1/builds?cursor=next"
        self.assertBlocked(assign_internal=True, group_ids=("internal-1",))

    def test_missing_next_link_does_not_hide_an_incomplete_collection(self):
        self.client.list_total = 2
        self.assertBlocked(assign_internal=True, group_ids=("internal-1",))

    def test_missing_export_compliance_does_not_trigger_any_write(self):
        self.client.internal_state_override = "MISSING_EXPORT_COMPLIANCE"
        self.assertBlocked(assign_internal=True, group_ids=("internal-1",))

    def test_build_becoming_expired_immediately_before_post_is_blocked(self):
        original = self.client.get
        def expire_before_write(path, query=None):
            if path == "/v1/builds" and self.client.group_validation_count:
                self.client.build["attributes"]["expired"] = True
            return original(path, query)
        self.client.get = expire_before_write
        self.assertBlocked(assign_internal=True, group_ids=("internal-1",))

    def test_build_query_response_is_checked_against_exact_build_version_and_platform(self):
        for field, wrong in (("version", "15002"), ("expired", True), ("processingState", "INVALID")):
            with self.subTest(field=field):
                self.client = FakeApple()
                self.client.build["attributes"][field] = wrong
                self.assertBlocked(assign_internal=True, group_ids=("internal-1",))
        for field, wrong in (("version", "1.4.0"), ("platform", "MAC_OS")):
            with self.subTest(field=field):
                self.client = FakeApple()
                self.client.release["attributes"][field] = wrong
                self.assertBlocked(assign_internal=True, group_ids=("internal-1",))

    def test_wrong_app_bundle_is_blocked(self):
        self.client.app["attributes"]["bundleId"] = "com.other.app"
        self.assertBlocked(assign_internal=True, group_ids=("internal-1",))

    def test_build_app_owner_must_match(self):
        self.client.app_owner = row("apps", "foreign-app", bundleId="com.woona.apps")
        self.assertBlocked(assign_internal=True, group_ids=("internal-1",))

    def test_unknown_expiration_is_blocked(self):
        self.client.build["attributes"].pop("expired")
        self.assertBlocked(assign_internal=True, group_ids=("internal-1",))

    def test_processing_build_does_not_write_until_valid(self):
        self.client.processing_sequence = ["PROCESSING", "PROCESSING", "PROCESSING"]
        with self.assertRaises(TimeoutError):
            self.check(assign_internal=True, group_ids=("internal-1",))
        self.assertEqual([], self.client.writes)

    def test_processing_then_valid_can_be_checked_read_only(self):
        self.client.processing_sequence = ["PROCESSING", "VALID"]
        self.assertEqual("VALID", self.check()["processing_state"])
        self.assertEqual([], self.client.writes)

    def test_missing_build_does_not_select_latest_build(self):
        self.client.build = None
        with self.assertRaises(TimeoutError):
            self.check()
        self.assertEqual([], self.client.writes)

    def test_assignment_requires_apple_read_back_not_only_http_success(self):
        self.client.readback_lies = True
        with self.assertRaises(TimeoutError):
            self.check(assign_internal=True, group_ids=("internal-1",))
        self.assertEqual(1, len(self.client.writes))

    def test_explicit_numeric_inputs_and_boolean_are_required(self):
        for version, build in (("latest", "15001"), ("1.5.0", "latest"), ("1.5.0", "١٥٠٠١"), ("1.5.0\n", "15001")):
            with self.subTest(version=version, build=build), self.assertRaises(SafetyError):
                run(self.client, version, build, attempts=1)
        self.assertBlocked(assign_internal="false", group_ids=("internal-1",))

    def test_transport_refuses_writes_outside_the_single_relationship_endpoint(self):
        client = AppleClient(None, None, None, allow_assignment=True)
        forbidden = [("POST", "/v1/betaAppReviewSubmissions", {"data": []}),
                     ("POST", "/v1/betaTesters", {"data": []}),
                     ("PATCH", "/v1/builds/build-150", {}),
                     ("DELETE", "/v1/betaGroups/external-1", {}),
                     ("POST", "/v1/betaGroups/internal-1/relationships/builds", {"data": [{"type": "betaTesters", "id": "t"}]})]
        with patch("testflight_internal.urlopen", side_effect=AssertionError("Network must not be reached")):
            for method, path, payload in forbidden:
                with self.subTest(path=path), self.assertRaises(SafetyError):
                    client._request(method, path, payload=payload)
            with self.assertRaises(SafetyError):
                AppleClient(None, None, None).assign_build("internal-1", "build-150")

    def test_es256_der_integer_padding_and_invalid_sequences(self):
        der = bytes.fromhex("3006020101020102")
        self.assertEqual(b"\0" * 31 + b"\1" + b"\0" * 31 + b"\2", jose_signature(der))
        for invalid in (b"", der + b"\0", bytes.fromhex("3006020180020102")):
            with self.subTest(invalid=invalid), self.assertRaises(SafetyError):
                jose_signature(invalid)


if __name__ == "__main__":
    unittest.main()
