"""Inspect an exact Woona build; optionally assign it to explicit existing internal groups.

Default operation is read-only. No tester invitations, external distribution,
review submission, localization updates, or app configuration writes exist here.
"""
import base64
import json
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


BUNDLE_ID = "com.woona.apps"
API = "https://api.appstoreconnect.apple.com"
ID_PATTERN = re.compile(r"[A-Za-z0-9-]+")


class SafetyError(RuntimeError):
    pass


class AppleRequestError(RuntimeError):
    """Sanitized endpoint diagnostics; never include URL queries, headers or bodies."""


def identifier(value):
    if not isinstance(value, str) or not ID_PATTERN.fullmatch(value):
        raise SafetyError("Invalid App Store Connect resource identifier")
    return value


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def jose_signature(der):
    # OpenSSL emits ASN.1 DER; App Store Connect expects two fixed-width integers.
    if len(der) < 6 or der[0] != 48 or der[1] != len(der) - 2:
        raise SafetyError("Invalid ES256 signature sequence")
    parts, pos = [], 2
    for _ in range(2):
        if pos + 2 > len(der) or der[pos] != 2:
            raise SafetyError("Invalid ES256 signature integer")
        length = der[pos + 1]
        value = der[pos + 2:pos + 2 + length]
        if len(value) != length or not value or value[0] & 128:
            raise SafetyError("Invalid ES256 signature value")
        value = value.lstrip(b"\0")
        if len(value) > 32:
            raise SafetyError("Invalid ES256 component size")
        parts.append(value.rjust(32, b"\0"))
        pos += 2 + length
    if pos != len(der):
        raise SafetyError("Trailing ES256 signature data")
    return b"".join(parts)


def token(key_path, key_id, issuer):
    now = int(time.time())
    header = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 600,
                             "aud": "appstoreconnect-v1"}).encode())
    signing = (header + "." + payload).encode()
    signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key_path)],
                               input=signing, capture_output=True, check=True).stdout
    return signing.decode() + "." + b64(jose_signature(signature))


class AppleClient:
    def __init__(self, key_path, key_id, issuer, *, allow_assignment=False):
        self.key_path, self.key_id, self.issuer = key_path, key_id, issuer
        self.allow_assignment = allow_assignment

    def _request(self, method, path, query=None, payload=None):
        # Restrict the only write operation even if a future caller passes a new path.
        if method != "GET" and not (
            method == "POST" and self.allow_assignment
            and re.fullmatch(r"/v1/betaGroups/[A-Za-z0-9-]+/relationships/builds", path)
            and isinstance(payload, dict) and set(payload) == {"data"}
            and isinstance(payload["data"], list) and len(payload["data"]) == 1
            and payload["data"][0].get("type") == "builds"
            and set(payload["data"][0]) == {"id", "type"}
            and ID_PATTERN.fullmatch(payload["data"][0].get("id", ""))
        ):
            raise SafetyError("Unsupported App Store Connect write")
        if not path.startswith("/v1/") or "?" in path or "#" in path or ".." in path:
            raise SafetyError("Invalid App Store Connect path")
        url = API + path + ("?" + urlencode(query) if query else "")
        data = json.dumps(payload).encode() if payload is not None else None
        request = Request(url, data=data, method=method, headers={
            "Authorization": "Bearer " + token(self.key_path, self.key_id, self.issuer),
            "Content-Type": "application/json",
        })
        try:
            with urlopen(request, timeout=30) as response:
                body = response.read()
                return json.loads(body) if body else None
        except HTTPError as error:
            raise AppleRequestError("App Store Connect " + method + " " + path + " HTTP " + str(error.code)) from None

    def get(self, path, query=None):
        return self._request("GET", path, query)

    def assign_build(self, group_id, build_id):
        return self._request("POST", "/v1/betaGroups/" + identifier(group_id) + "/relationships/builds",
                             payload={"data": [{"type": "builds", "id": identifier(build_id)}]})


def collection(response, kind):
    if response.get("links", {}).get("next"):
        raise SafetyError("Incomplete paginated response; refusing to infer a unique target")
    rows = response.get("data")
    if not isinstance(rows, list) or any(not isinstance(row, dict) or row.get("type") != kind for row in rows):
        raise SafetyError("Unexpected App Store Connect collection")
    total = response.get("meta", {}).get("paging", {}).get("total")
    if total is not None and (type(total) is not int or total != len(rows)):
        raise SafetyError("Incomplete App Store Connect collection")
    ids = [identifier(row.get("id")) for row in rows]
    if len(set(ids)) != len(ids):
        raise SafetyError("Duplicate App Store Connect resource identifiers")
    return rows


def resource(response, kind):
    row = response.get("data", {})
    if not isinstance(row, dict) or row.get("type") != kind:
        raise SafetyError("Unexpected App Store Connect resource")
    identifier(row.get("id"))
    return row


def included_resource(build, relationship, kind, *, optional=False):
    reference = build.get("relationships", {}).get(relationship, {}).get("data", {})
    # Apple can expose a processing build before its optional beta detail exists.
    # Required app/version identity always fails closed; an absent beta detail
    # only means internal availability cannot yet be confirmed.
    if optional and (reference is None or reference == {}):
        return {}
    if not isinstance(reference, dict):
        raise SafetyError("Included " + relationship + " cannot be confirmed")
    matches = [item for item in build.get("_included", [])
               if item.get("type") == kind and item.get("id") == reference.get("id")]
    if reference.get("type") != kind or len(matches) != 1:
        raise SafetyError("Included " + relationship + " cannot be confirmed")
    identifier(matches[0].get("id"))
    return matches[0]


def exact_build(client, app_id, version, build_number):
    result = client.get("/v1/builds", {
        "filter[app]": app_id, "filter[version]": build_number,
        "filter[preReleaseVersion.version]": version,
        "include": "app,preReleaseVersion,buildBetaDetail,betaGroups", "limit": 200,
    })
    rows = collection(result, "builds")
    if not rows:
        return None
    if len(rows) != 1:
        raise SafetyError("Exact build query is ambiguous")
    build = {**rows[0], "_included": result.get("included", [])}
    release = included_resource(build, "preReleaseVersion", "preReleaseVersions")
    if (build.get("attributes", {}).get("version") != build_number
            or release.get("attributes", {}).get("version") != version
            or release.get("attributes", {}).get("platform") != "IOS"):
        raise SafetyError("Build does not match the exact requested iOS version and number")
    owner = included_resource(build, "app", "apps")
    if owner["id"] != app_id or owner.get("attributes", {}).get("bundleId") != BUNDLE_ID:
        raise SafetyError("Build belongs to another app")
    return build


def validate_group(client, app_id, group_id):
    # This app-scoped collection proves ownership without requiring a separate
    # related-resource endpoint that some Developer keys cannot read.
    groups = collection(client.get("/v1/apps/" + app_id + "/betaGroups", {"limit": 200}), "betaGroups")
    matches = [group for group in groups if group["id"] == group_id]
    if len(matches) != 1 or matches[0].get("attributes", {}).get("isInternalGroup") is not True:
        raise SafetyError("Assignment target is not an existing internal group")


def inspect(client, app_id, version, build_number):
    build = exact_build(client, app_id, version, build_number)
    if build is None:
        return None
    groups = collection(client.get("/v1/apps/" + app_id + "/betaGroups", {"limit": 200}), "betaGroups")
    internal = [group for group in groups if group.get("attributes", {}).get("isInternalGroup") is True]
    if not internal:
        raise SafetyError("Woona has no existing internal tester groups")
    relationship = build.get("relationships", {}).get("betaGroups", {})
    assigned = collection(relationship, "betaGroups")
    assigned_ids = {group["id"] for group in assigned}
    details = included_resource(build, "buildBetaDetail", "buildBetaDetails", optional=True)
    report_groups = []
    for group in internal:
        testers = client.get("/v1/betaGroups/" + group["id"] + "/betaTesters", {"limit": 1})
        count = testers.get("meta", {}).get("paging", {}).get("total")
        if not isinstance(count, int) or isinstance(count, bool) or count < 0:
            count = len(collection(testers, "betaTesters"))
        report_groups.append({"id": group["id"], "tester_count": count, "assigned": group["id"] in assigned_ids})
    attrs = build.get("attributes", {})
    expired, processing = attrs.get("expired"), attrs.get("processingState")
    internal_state = details.get("attributes", {}).get("internalBuildState")
    available = (processing == "VALID" and expired is False and internal_state == "IN_BETA_TESTING"
                 and any(group["assigned"] and group["tester_count"] > 0 for group in report_groups))
    return {"bundle_id": BUNDLE_ID, "version": version, "build_number": build_number, "build_id": build["id"],
            "processing_state": processing, "expired": expired, "internal_build_state": internal_state,
            "internal_groups": report_groups, "available_for_internal_testers": available,
            "physical_installation_verified": False}


def run(client, version, build_number, *, assign_internal=False, group_ids=(), attempts=45, pause=time.sleep):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", version) or not re.fullmatch(r"[0-9]+", build_number):
        raise SafetyError("Explicit numeric marketing version and exact build number are required")
    if type(assign_internal) is not bool:
        raise SafetyError("Assignment must be explicitly true or false")
    targets = tuple(identifier(value) for value in group_ids)
    if len(set(targets)) != len(targets) or (assign_internal and not targets):
        raise SafetyError("Assignment requires explicit unique internal group IDs")
    apps = collection(client.get("/v1/apps", {"filter[bundleId]": BUNDLE_ID}), "apps")
    if len(apps) != 1 or apps[0].get("attributes", {}).get("bundleId") != BUNDLE_ID:
        raise SafetyError("Expected exactly the com.woona.apps application")
    app_id = apps[0]["id"]
    assigned_once = False
    target_build_id = None
    for attempt in range(attempts):
        report = inspect(client, app_id, version, build_number)
        if report is not None:
            if target_build_id is not None and report["build_id"] != target_build_id:
                raise SafetyError("Exact build identity changed during assignment")
            if report["processing_state"] in ("FAILED", "INVALID") or report["expired"] is not False:
                raise SafetyError("Build failed processing, expired, or expiration cannot be confirmed")
            if report["processing_state"] == "VALID":
                report["assignment_requested"] = assign_internal
                report["target_internal_group_ids"] = list(targets)
                if not assign_internal:
                    return report
                target_build_id = report["build_id"]
                if report["internal_build_state"] not in ("READY_FOR_BETA_TESTING", "IN_BETA_TESTING"):
                    raise SafetyError("Apple internal beta state is not ready for assignment")
                groups = {group["id"]: group for group in report["internal_groups"]}
                if any(group_id not in groups for group_id in targets):
                    raise SafetyError("An explicit target is not one of Woona's existing internal groups")
                # Validate every target before the first write; also revalidate immediately before each POST.
                for group_id in targets:
                    validate_group(client, app_id, group_id)
                if not assigned_once:
                    for group_id in targets:
                        if groups[group_id]["assigned"]:
                            continue
                        current = exact_build(client, app_id, version, build_number)
                        if (current is None or current["id"] != report["build_id"]
                                or current.get("attributes", {}).get("processingState") != "VALID"
                                or current.get("attributes", {}).get("expired") is not False):
                            raise SafetyError("Build eligibility changed before assignment")
                        validate_group(client, app_id, group_id)
                        client.assign_build(group_id, report["build_id"])
                    assigned_once = True
                    # Always read back membership and Apple beta state after a mutation.
                    continue
                if (all(groups[group_id]["assigned"] for group_id in targets)
                        and report["internal_build_state"] == "IN_BETA_TESTING"
                        and any(groups[group_id]["tester_count"] > 0 for group_id in targets)):
                    return report
        if attempt + 1 < attempts:
            pause(20)
    raise TimeoutError("Exact build processing or internal tester availability did not become ready")


def main():
    assign_value = os.environ.get("ASSIGN_INTERNAL", "false")
    if assign_value not in ("true", "false"):
        raise SafetyError("ASSIGN_INTERNAL must be exactly true or false")
    assign = assign_value == "true"
    groups = tuple(item.strip() for item in os.environ.get("INTERNAL_GROUP_IDS", "").split(",") if item.strip())
    with tempfile.TemporaryDirectory() as directory:
        key = Path(directory) / "key.p8"
        key.write_text(os.environ["ASC_PRIVATE_KEY"])
        key.chmod(0o600)
        client = AppleClient(key, os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], allow_assignment=assign)
        report = run(client, os.environ["CHECK_VERSION"].strip(), os.environ["CHECK_BUILD"].strip(),
                     assign_internal=assign, group_ids=groups)
    Path("testflight-internal-status.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)


if __name__ == "__main__":
    try:
        main()
    except AppleRequestError as error:
        raise SystemExit(str(error)) from None
