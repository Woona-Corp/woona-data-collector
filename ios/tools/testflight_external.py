"""Read-only external TestFlight status for one exact Woona build."""
import json
import os
import tempfile
from pathlib import Path

from testflight_internal import (
    AppleClient,
    AppleRequestError,
    BUNDLE_ID,
    collection,
    exact_build,
    included_resource,
    resource,
)


def inspect_external(client, app_id, version, build_number):
    build = exact_build(client, app_id, version, build_number)
    if build is None:
        return None
    groups = collection(client.get("/v1/apps/" + app_id + "/betaGroups", {"limit": 200}), "betaGroups")
    external = [group for group in groups if group.get("attributes", {}).get("isInternalGroup") is False]
    assigned = {group["id"] for group in collection(build.get("relationships", {}).get("betaGroups", {}), "betaGroups")}
    report_groups = []
    for group in external:
        attributes = group.get("attributes", {})
        report_groups.append({
            "id": group["id"],
            "assigned": group["id"] in assigned,
            "public_link_enabled": attributes.get("publicLinkEnabled"),
            "public_link": attributes.get("publicLink"),
        })
    details = included_resource(build, "buildBetaDetail", "buildBetaDetails", optional=True)
    review_state = None
    review_id = None
    try:
        review = resource(client.get("/v1/builds/" + build["id"] + "/betaAppReviewSubmission"),
                          "betaAppReviewSubmissions")
        review_id = review["id"]
        review_state = review.get("attributes", {}).get("betaReviewState")
    except AppleRequestError as error:
        if not str(error).endswith("HTTP 404"):
            raise
    attributes = build.get("attributes", {})
    external_state = details.get("attributes", {}).get("externalBuildState")
    assigned_external = any(group["assigned"] for group in report_groups)
    available = (attributes.get("processingState") == "VALID" and attributes.get("expired") is False
                 and external_state == "IN_BETA_TESTING" and assigned_external and review_state == "APPROVED")
    return {
        "bundle_id": BUNDLE_ID,
        "version": version,
        "build_number": build_number,
        "build_id": build["id"],
        "processing_state": attributes.get("processingState"),
        "expired": attributes.get("expired"),
        "external_build_state": external_state,
        "external_groups": report_groups,
        "beta_review_submission_id": review_id,
        "beta_review_state": review_state,
        "available_for_external_testers": available,
        "physical_installation_verified": False,
    }


def main():
    key_text = os.environ["ASC_PRIVATE_KEY"].replace("\\n", "\n")
    with tempfile.TemporaryDirectory() as temporary:
        key = Path(temporary) / "key.p8"
        key.write_text(key_text)
        key.chmod(0o600)
        client = AppleClient(key, os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"])
        apps = collection(client.get("/v1/apps", {"filter[bundleId]": BUNDLE_ID}), "apps")
        if len(apps) != 1 or apps[0].get("attributes", {}).get("bundleId") != BUNDLE_ID:
            raise RuntimeError("Expected exactly the com.woona.apps application")
        report = inspect_external(client, apps[0]["id"], os.environ["CHECK_VERSION"].strip(),
                                  os.environ["CHECK_BUILD"].strip())
    if report is None:
        raise RuntimeError("Exact uploaded build was not found")
    Path("testflight-external-status.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)


if __name__ == "__main__":
    main()
