"""
Day 7: Access hygiene agent.

A small, read only "AI agent" style automation that reviews Peachtree identities
in Entra ID and writes a report. The interesting part is not what it does, it is
HOW it signs in:

  BEFORE (local run):   a client secret held only in the terminal session -> a password that can leak
  AFTER  (GitHub run):  workload identity federation (OIDC) -> no stored secret at all

The code is the same in both cases. Only the credential source changes:
  - If AZURE_CLIENT_SECRET is set, it uses ClientSecretCredential (the "before" picture)
  - Otherwise it uses AzureCliCredential, which picks up the short lived token that
    the azure/login step created from the GitHub OIDC token (the "after" picture)

Graph application permissions it needs (read only, nothing that writes):
  User.Read.All      read users and the synced dknSourceCompany extension
  AuditLog.Read.All  read signInActivity (needs Entra ID P1 or P2; see fallback below)

Usage:
  python access_hygiene_agent.py --report evidence/day7_agent_report.csv
  python access_hygiene_agent.py --prove-read-only <userObjectId>
"""

from __future__ import annotations

import argparse
import csv
import os
import sys
from datetime import datetime, timezone

import requests
from azure.identity import AzureCliCredential, ClientSecretCredential

GRAPH = "https://graph.microsoft.com/v1.0"
GRAPH_SCOPE = "https://graph.microsoft.com/.default"
STALE_DAYS = 30
ATTRIBUTE = "dknSourceCompany"


def get_token() -> tuple[str, str]:
    """Return (access_token, how_we_signed_in)."""
    tenant = os.environ.get("AZURE_TENANT_ID")
    client = os.environ.get("AZURE_CLIENT_ID")
    secret = os.environ.get("AZURE_CLIENT_SECRET")

    if secret:
        cred = ClientSecretCredential(tenant_id=tenant, client_id=client, client_secret=secret)
        mode = "client_secret (stored password, the BEFORE picture)"
    else:
        cred = AzureCliCredential()
        mode = "federated credential via azure/login (no stored secret, the AFTER picture)"

    token = cred.get_token(GRAPH_SCOPE).token
    return token, mode


def graph_get(token: str, url: str) -> requests.Response:
    return requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=30)


def find_extension_name(token: str) -> str | None:
    """Synced AD attributes get a generated name like extension_<appid>_dknSourceCompany."""
    resp = requests.post(
        f"{GRAPH}/directoryObjects/getAvailableExtensionProperties",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json={"isSyncedFromOnPremises": True},
        timeout=30,
    )
    resp.raise_for_status()
    for prop in resp.json().get("value", []):
        if prop.get("name", "").endswith(f"_{ATTRIBUTE}"):
            return prop["name"]
    return None


def list_users(token: str, ext_name: str | None) -> tuple[list[dict], bool]:
    """Return (users, sign_in_data_available)."""
    base_fields = "id,displayName,userPrincipalName,accountEnabled,onPremisesSyncEnabled,createdDateTime"
    if ext_name:
        base_fields += f",{ext_name}"

    def fetch_all(select: str) -> list[dict]:
        users, url = [], f"{GRAPH}/users?$select={select}&$top=100"
        while url:
            resp = graph_get(token, url)
            resp.raise_for_status()
            body = resp.json()
            users.extend(body.get("value", []))
            url = body.get("@odata.nextLink")
        return users

    # signInActivity needs a P1/P2 license in the tenant. Free tenants get a 403.
    # That is a real snag worth a screenshot, so fall back instead of crashing.
    try:
        return fetch_all(base_fields + ",signInActivity"), True
    except requests.HTTPError as err:
        if err.response is not None and err.response.status_code == 403:
            print("signInActivity not available (tenant license). Falling back to account checks only.")
            return fetch_all(base_fields), False
        raise


def days_since(iso: str | None) -> int | None:
    if not iso:
        return None
    stamp = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    return (datetime.now(timezone.utc) - stamp).days


def scrub_upn(upn: str | None) -> str | None:
    """Keep the username, hide the tenant domain. Reports land in the repo and in
    workflow artifacts, and the tenant domain identifies the lab tenant."""
    if not upn or "@" not in upn:
        return upn
    return upn.split("@", 1)[0] + "@<tenant>"


def build_report(users: list[dict], ext_name: str | None, has_sign_in: bool) -> list[dict]:
    rows = []
    for u in users:
        company = u.get(ext_name) if ext_name else None
        if company != "Peachtree":
            continue

        last_sign_in = (u.get("signInActivity") or {}).get("lastSignInDateTime") if has_sign_in else None
        idle = days_since(last_sign_in)

        findings = []
        if not u.get("accountEnabled"):
            findings.append("Disabled account still in tenant")
        if has_sign_in and last_sign_in is None:
            findings.append("Never signed in")
        elif idle is not None and idle > STALE_DAYS:
            findings.append(f"No sign in for {idle} days")
        if not u.get("onPremisesSyncEnabled"):
            findings.append("Cloud only, not from AD")

        rows.append({
            "displayName": u.get("displayName"),
            "userPrincipalName": scrub_upn(u.get("userPrincipalName")),
            "sourceCompany": company,
            "accountEnabled": u.get("accountEnabled"),
            "lastSignIn": last_sign_in or ("unknown (no license)" if not has_sign_in else "never"),
            "findings": "; ".join(findings) if findings else "OK",
        })
    return rows


def prove_read_only(token: str, user_id: str) -> int:
    """Try a write. A correctly scoped agent MUST get 403 Forbidden."""
    resp = requests.patch(
        f"{GRAPH}/users/{user_id}",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json={"jobTitle": "changed by agent"},
        timeout=30,
    )
    print(f"Write attempt returned HTTP {resp.status_code}")
    if resp.status_code == 403:
        print("PASS: the agent cannot change users. Least privilege is working.")
        return 0
    print("FAIL: the agent was allowed to write. Remove write permissions from the app registration.")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Read only access hygiene agent")
    parser.add_argument("--report", default="evidence/day7_agent_report.csv")
    parser.add_argument("--prove-read-only", metavar="USER_OBJECT_ID")
    args = parser.parse_args()

    token, mode = get_token()
    print(f"Signed in using: {mode}")

    if args.prove_read_only:
        return prove_read_only(token, args.prove_read_only)

    ext_name = find_extension_name(token)
    # The generated name embeds the sync app's ID. Run logs can become public, so print a masked form.
    shown = f"extension_<app_id>_{ATTRIBUTE}" if ext_name else "NOT FOUND (check Day 4 directory extension sync)"
    print(f"Source company attribute: {shown}")

    users, has_sign_in = list_users(token, ext_name)
    rows = build_report(users, ext_name, has_sign_in)

    os.makedirs(os.path.dirname(args.report) or ".", exist_ok=True)
    fields = ["displayName", "userPrincipalName", "sourceCompany", "accountEnabled", "lastSignIn", "findings"]
    with open(args.report, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)

    flagged = sum(1 for r in rows if r["findings"] != "OK")
    print(f"Reviewed {len(rows)} Peachtree identities, {flagged} flagged. Report: {args.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
