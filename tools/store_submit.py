"""Submit an MSIX to the Microsoft Store via the submission API.

Runs in CI (``publish-store`` job) and locally — standard library only::

    python tools/store_submit.py Strakalari-0.2.0.msix --commit
    python tools/store_submit.py Strakalari-0.2.0.msix --discard   # dry run

Credentials come from args or ``STORE_*`` env vars: tenant, client-id,
client-secret (Azure AD app, see docs/STORE.md) and app-id (Partner
Center application ID).

Flow: access token -> verify app -> create draft submission (cloned from
the last published one, so listings/pricing stay untouched) -> upload a
ZIP holding the package to the submission's blob URL -> replace the
package set -> commit (or discard the draft with --discard). Certification
itself takes hours; this script only waits until the commit is ACCEPTED
(PreProcessing), then the Store mails the certification result.

The API only works for apps whose FIRST submission was completed by hand
in Partner Center (docs/STORE.md).
"""

from __future__ import annotations

import argparse
import io
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

TOKEN_URL = "https://login.microsoftonline.com/{tenant}/oauth2/token"
API_BASE = "https://manage.devcenter.microsoft.com/v1.0/my"
RESOURCE = "https://manage.devcenter.microsoft.com"

#: Submission states after a successful commit (CommitStarted -> PreProcessing -> ...).
COMMITTED_STATES = ("preprocessing", "certification", "release",
                    "pendingpublication", "publishing", "published")


class SubmissionError(Exception):
    pass


def _request(method: str, url: str, token: str | None = None,
             data: bytes | None = None,
             headers: dict | None = None) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=data, method=method)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def _json(method: str, url: str, token: str,
          payload: dict | None = None) -> dict:
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    status, body = _request(method, url, token, data, headers)
    try:
        parsed = json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        parsed = {"_raw": body.decode("utf-8", "replace")[:2000]}
    if status >= 400:
        raise SubmissionError(
            f"{method} {url} -> HTTP {status}: "
            f"{json.dumps(parsed)[:2000]}"
        )
    return parsed if isinstance(parsed, dict) else {"_raw": parsed}


def get_token(tenant: str, client_id: str, client_secret: str) -> str:
    body = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": client_id,
        "client_secret": client_secret,
        "resource": RESOURCE,
    }).encode("ascii")
    status, raw = _request(
        "POST", TOKEN_URL.format(tenant=tenant), data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        parsed = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        parsed = {}
    if status >= 400 or "access_token" not in parsed:
        raise SubmissionError(
            f"token request -> HTTP {status}: {json.dumps(parsed)[:1000]} "
            "(check STORE_TENANT_ID / STORE_CLIENT_ID / STORE_CLIENT_SECRET)"
        )
    return parsed["access_token"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("msix", help="MSIX package to submit")
    parser.add_argument("--tenant", default=os.environ.get("STORE_TENANT_ID", ""))
    parser.add_argument("--client-id", default=os.environ.get("STORE_CLIENT_ID", ""))
    parser.add_argument("--client-secret", default=os.environ.get("STORE_CLIENT_SECRET", ""))
    parser.add_argument("--app-id", default=os.environ.get("STORE_APP_ID", ""))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--commit", action="store_true",
                      help="commit the submission for certification (default)")
    mode.add_argument("--discard", action="store_true",
                      help="upload + validate, then delete the draft (dry run)")
    args = parser.parse_args()
    do_commit = not args.discard

    for name in ("tenant", "client_id", "client_secret", "app_id"):
        if not getattr(args, name):
            raise SystemExit(
                f"missing --{name.replace('_', '-')} "
                f"(or STORE_{name.upper()} env). See docs/STORE.md."
            )
    if not os.path.isfile(args.msix):
        raise SystemExit(f"package not found: {args.msix}")

    print("1/6 getting access token ...")
    token = get_token(args.tenant, args.client_id, args.client_secret)

    print("2/6 verifying application ...")
    app = _json("GET", f"{API_BASE}/applications/{args.app_id}", token)
    print(f"    app: {app.get('primaryName')} "
          f"(package identity: {app.get('packageFamilyName')})")
    if not app.get("lastPublishedApplicationSubmission"):
        raise SubmissionError(
            "the app has no published submission yet: the API can only update "
            "an app whose first submission was done by hand in Partner Center "
            "(docs/STORE.md).")
    pending = app.get("pendingApplicationSubmission")
    if pending:
        raise SubmissionError(
            f"a draft submission ({pending.get('id')}) is already open in "
            "Partner Center: finish or delete it there, then re-run the job.")

    print("3/6 creating draft submission ...")
    submission = _json(
        "POST", f"{API_BASE}/applications/{args.app_id}/submissions", token)
    sub_id = submission.get("id")
    if not sub_id:
        raise SubmissionError(
            f"submission has no id: {json.dumps(submission)[:1000]}")
    print(f"    submission id: {sub_id}")
    upload_url = submission.get("fileUploadUrl")
    if not upload_url:
        raise SubmissionError(
            "submission has no fileUploadUrl; keys: "
            + ", ".join(sorted(submission.keys()))
            + ". The API shape may have changed — see docs/STORE.md.")

    try:
        print("4/6 uploading package ...")
        file_name = os.path.basename(args.msix)
        # The blob takes a ZIP of all new files; applicationPackages below
        # names the package by its path inside that ZIP.
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", zipfile.ZIP_STORED) as archive:
            archive.write(args.msix, file_name)
        archive_bytes = buffer.getvalue()
        print(f"    {len(archive_bytes) / (1024 * 1024):.1f} MB -> blob storage")
        status, body = _request(
            "PUT", upload_url, data=archive_bytes,
            headers={"x-ms-blob-type": "BlockBlob",
                     "Content-Type": "application/octet-stream"},
        )
        if status >= 400:
            raise SubmissionError(
                f"package upload -> HTTP {status}: "
                f"{body.decode('utf-8', 'replace')[:1000]}")

        print("5/6 updating submission packages ...")
        detail = _json(
            "GET",
            f"{API_BASE}/applications/{args.app_id}/submissions/{sub_id}",
            token,
        )
        packages = list(detail.get("applicationPackages") or [])
        for package in packages:
            package["fileStatus"] = "PendingDelete"
        packages.append({"fileName": file_name, "fileStatus": "PendingUpload"})
        detail["applicationPackages"] = packages
        # PUT back everything else untouched (listings, pricing, ...).
        detail.pop("fileUploadUrl", None)
        _json(
            "PUT",
            f"{API_BASE}/applications/{args.app_id}/submissions/{sub_id}",
            token, detail,
        )
        print(f"    replaced {len(packages) - 1} old package(s) with {file_name}")

        if not do_commit:
            print("6/6 dry run: discarding draft submission ...")
            status, body = _request(
                "DELETE",
                f"{API_BASE}/applications/{args.app_id}/submissions/{sub_id}",
                token,
            )
            if status >= 400:
                raise SubmissionError(
                    f"discard -> HTTP {status}: "
                    f"{body.decode('utf-8', 'replace')[:500]}")
            print("    draft discarded — upload + metadata validated OK")
            return 0

        print("6/6 committing submission for certification ...")
        commit = _json(
            "POST",
            f"{API_BASE}/applications/{args.app_id}/submissions/{sub_id}/commit",
            token,
        )
        print(f"    commit status: {commit.get('status')}")
        for _ in range(20):
            time.sleep(30)
            state = _json(
                "GET",
                f"{API_BASE}/applications/{args.app_id}/submissions/{sub_id}/status",
                token,
            )
            status_value = str(state.get("status") or "")
            print(f"    poll: {status_value}")
            if status_value.lower() in COMMITTED_STATES:
                print("Commit accepted. Certification takes hours — the result "
                      "arrives by mail and in Partner Center.")
                return 0
            if "fail" in status_value.lower() or "cancel" in status_value.lower():
                raise SubmissionError(
                    f"submission {status_value}: "
                    f"{json.dumps(state.get('statusDetails') or state)[:1500]}")
        raise SubmissionError(
            f"commit still not accepted after 10 minutes (last status: "
            f"{status_value}); check submission {sub_id} in Partner Center.")
    except BaseException:
        if do_commit:
            print("Submission FAILED before commit finished. The draft "
                  f"submission {sub_id} is left in Partner Center — delete "
                  "it there before retrying.", file=sys.stderr)
        raise


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SubmissionError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from None
