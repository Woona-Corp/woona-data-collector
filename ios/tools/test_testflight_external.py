"""No-network external TestFlight status tests."""
import unittest

from test_testflight_internal import FakeApple
from testflight_external import inspect_external


class ExternalTestFlightTests(unittest.TestCase):
    def setUp(self):
        self.client = FakeApple()
        self.client.review_state = "APPROVED"
        self.client.external_state = "IN_BETA_TESTING"
        original_get = self.client.get

        def get(path, query=None):
            if path == "/v1/builds":
                response = original_get(path, query)
                for item in response["included"]:
                    if item["type"] == "buildBetaDetails":
                        item["attributes"]["externalBuildState"] = self.client.external_state
                return response
            if path == "/v1/builds/build-150/betaAppReviewSubmission":
                return {"data": {"type": "betaAppReviewSubmissions", "id": "review-1",
                                 "attributes": {"betaReviewState": self.client.review_state}}}
            return original_get(path, query)

        self.client.get = get

    def test_approved_assigned_external_build_is_available_without_private_testers(self):
        self.client.assigned.add("external-1")
        report = inspect_external(self.client, "app-1", "1.5.0", "15001")
        self.assertTrue(report["available_for_external_testers"])
        self.assertEqual("APPROVED", report["beta_review_state"])
        self.assertEqual([{"id": "external-1", "assigned": True,
                           "public_link_enabled": None, "public_link": None}], report["external_groups"])
        self.assertNotIn("Private", str(report))
        self.assertEqual([], self.client.writes)

    def test_unassigned_or_unreviewed_build_is_not_available(self):
        self.client.review_state = "WAITING_FOR_REVIEW"
        report = inspect_external(self.client, "app-1", "1.5.0", "15001")
        self.assertFalse(report["available_for_external_testers"])
        self.assertEqual([], self.client.writes)


if __name__ == "__main__":
    unittest.main()
