#!/usr/bin/env python3
"""
Update text fields of an iOS App version on App Store Connect for a
given localization page, via the official App Store Connect API.
Supported fields:

    --promotional-text  Promotional Text       (max 170 chars)
    --description       Description             (max 4000 chars)
    --keywords          Keywords (comma-list)   (max 100 chars)
    --whats-new         What's New in This Version (max 4000 chars)

You can pass any combination of these flags. Only the fields you
provide are pushed; the others remain unchanged on App Store Connect.

Usage:
    python3 update_app_store_listing.py <version> --locale <code> [options]

The --locale flag is mandatory whenever you actually want to PATCH
anything. If you omit it, the script prints the list of locale codes
configured on that version (queried live from the API) and exits — so
you can copy/paste the right code for the next run.

Examples:
    # List the locales configured on version 1.2:
    python3 update_app_store_listing.py 1.2

    # Set the French promotional text:
    python3 update_app_store_listing.py 1.2 --locale fr-FR \\
        --promotional-text "Capturez tout ce que vous partagez…"

    # English description + keywords at once:
    python3 update_app_store_listing.py 1.2 --locale en-US \\
        --description "Captured collects and organizes everything you share…" \\
        --keywords "bookmark,save,read,later,clipboard,icloud,ai,widget"

    # Release notes from a file (shell substitution):
    python3 update_app_store_listing.py 1.2 --locale en-US \\
        --whats-new "$(cat release-notes-1.2.txt)"

Dry-run (no PATCH):
    python3 update_app_store_listing.py 1.2 --locale fr-FR --dry-run \\
        --promotional-text "…" --keywords "…"

Required environment variables (one-time setup):
    ASC_KEY_ID       The Key ID of your App Store Connect API key.
                     App Store Connect → Users and Access → Integrations
                     → Keys → column "ID" (10-char string like "ABCD123EFG").
    ASC_ISSUER_ID    The Issuer ID shown at the top of the Keys page
                     (UUID like "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx").
    ASC_PRIVATE_KEY  Path to the .p8 private key file downloaded when
                     you created the API key. Apple only lets you
                     download this once — keep it safe.

Optional environment variable:
    ASC_APP_ID       The app's numeric ID. Defaults to Captured's ID
                     (6763560506). Find yours in any App Store Connect
                     URL: appstoreconnect.apple.com/apps/<APP_ID>/...

Dependencies:
    pip install requests pyjwt cryptography

Notes:
    - Promotional Text can be edited at ANY time without resubmitting
      the app — Apple displays the latest version to App Store visitors.
    - Description, Keywords and What's New are part of the version
      metadata: changes are sent for review when you next submit the
      version. They can be edited freely while the version is in
      "Prepare for Submission" state (no review needed yet).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone

try:
    import jwt
    import requests
except ImportError as exc:
    sys.exit(
        f"ERROR: missing dependency ({exc.name!r}).\n"
        "Run: pip install requests pyjwt cryptography"
    )


# Captured's App ID, taken from the App Store Connect URL
# (appstoreconnect.apple.com/apps/6763560506/distribution/...). Override
# via the ASC_APP_ID environment variable if you ever run this script
# against a different app.
DEFAULT_APP_ID = "6763560506"

API_BASE = "https://api.appstoreconnect.apple.com/v1"

# Apple's documented hard limits on each text field. Source:
# https://developer.apple.com/help/app-store-connect/reference/app-store-product-page
FIELD_LIMITS = {
    "promotionalText": 170,
    "description": 4000,
    "keywords": 100,
    "whatsNew": 4000,
}

# Mapping CLI flag dest → API attribute name.
CLI_TO_API = {
    "promotional_text": "promotionalText",
    "description": "description",
    "keywords": "keywords",
    "whats_new": "whatsNew",
}

# Apple requires JWT exp ≤ 20 min in the future.
JWT_LIFETIME_SECONDS = 1200


def make_jwt() -> str:
    """Build a short-lived JWT signed with the developer's ES256 key."""
    key_id = os.environ.get("ASC_KEY_ID")
    issuer_id = os.environ.get("ASC_ISSUER_ID")
    key_path = os.environ.get("ASC_PRIVATE_KEY")

    missing = [name for name, val in [
        ("ASC_KEY_ID", key_id),
        ("ASC_ISSUER_ID", issuer_id),
        ("ASC_PRIVATE_KEY", key_path),
    ] if not val]
    if missing:
        sys.exit(
            "ERROR: missing required environment variable(s): "
            + ", ".join(missing)
            + "\nSee the docstring at the top of this script for setup."
        )

    if not os.path.isfile(key_path):
        sys.exit(f"ERROR: private key file not found: {key_path}")

    with open(key_path, "r", encoding="utf-8") as fh:
        private_key_pem = fh.read()

    now = int(time.time())
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + JWT_LIFETIME_SECONDS,
        "aud": "appstoreconnect-v1",
    }
    token = jwt.encode(
        payload,
        private_key_pem,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )
    # PyJWT ≥ 2 returns a str; PyJWT 1.x returned bytes.
    return token if isinstance(token, str) else token.decode("utf-8")


def find_version(session: requests.Session, app_id: str, version_string: str) -> dict:
    """Look up the AppStoreVersion record whose versionString matches."""
    url = f"{API_BASE}/apps/{app_id}/appStoreVersions"
    params = {
        "filter[versionString]": version_string,
        "fields[appStoreVersions]": "versionString,appStoreState,platform",
        "limit": 200,
    }
    resp = session.get(url, params=params)
    if resp.status_code >= 400:
        sys.exit(f"ERROR: GET appStoreVersions failed: HTTP {resp.status_code}\n{resp.text}")
    data = resp.json().get("data", [])
    # Restrict to iOS platform — an app can host both iOS and Mac versions.
    ios_versions = [v for v in data if v.get("attributes", {}).get("platform") == "IOS"]
    if not ios_versions:
        all_versions = [v["attributes"].get("versionString") for v in data]
        sys.exit(
            f"ERROR: no iOS AppStoreVersion with versionString={version_string!r} "
            f"found on app {app_id}. Versions matching the filter: {all_versions}"
        )
    if len(ios_versions) > 1:
        # In practice Apple only allows ONE editable iOS version at a time
        # per versionString, so this shouldn't happen — but warn loudly.
        states = [v["attributes"].get("appStoreState") for v in ios_versions]
        print(
            f"WARN: {len(ios_versions)} iOS versions match {version_string!r} "
            f"(states={states}); using the first.",
            file=sys.stderr,
        )
    return ios_versions[0]


def fetch_all_localizations(session: requests.Session, version_id: str) -> list[dict]:
    """List every AppStoreVersionLocalization attached to this version,
    requesting all four editable text fields so the caller can both
    enumerate available locales AND show current values when patching."""
    url = f"{API_BASE}/appStoreVersions/{version_id}/appStoreVersionLocalizations"
    params = {
        "limit": 200,
        "fields[appStoreVersionLocalizations]":
            "locale,promotionalText,description,keywords,whatsNew",
    }
    resp = session.get(url, params=params)
    if resp.status_code >= 400:
        sys.exit(
            f"ERROR: GET appStoreVersionLocalizations failed: "
            f"HTTP {resp.status_code}\n{resp.text}"
        )
    return resp.json().get("data", [])


def pick_localization(localizations: list[dict], locale: str) -> dict:
    """Filter the list of localizations by locale code, abort on miss."""
    for loc in localizations:
        if loc.get("attributes", {}).get("locale") == locale:
            return loc
    available = sorted(l["attributes"].get("locale", "?") for l in localizations)
    sys.exit(
        f"ERROR: locale {locale!r} is not configured on this version. "
        f"Available locales: {available}"
    )


def patch_localization(
    session: requests.Session, loc_id: str, attributes: dict
) -> None:
    url = f"{API_BASE}/appStoreVersionLocalizations/{loc_id}"
    body = {
        "data": {
            "type": "appStoreVersionLocalizations",
            "id": loc_id,
            "attributes": attributes,
        }
    }
    resp = session.patch(url, json=body)
    if resp.status_code >= 400:
        sys.exit(
            f"ERROR: PATCH appStoreVersionLocalizations failed: "
            f"HTTP {resp.status_code}\n{resp.text}"
        )


def dump_to_json(
    version_string: str,
    app_id: str,
    localizations: list[dict],
    output_path: str,
) -> None:
    """Serialize every locale's four editable text fields into a JSON
    document and write it to `output_path` (or stdout if "-").

    Output format is documented in update_app_store_listing.md
    (section "JSON dump format")."""
    payload = {
        "appId": app_id,
        "versionString": version_string,
        "platform": "IOS",
        "exportedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "exportedBy": "update_app_store_listing.py",
        "localizations": {},
    }
    # Sort locales for stable diffs across consecutive dumps.
    for loc in sorted(localizations, key=lambda l: l["attributes"].get("locale", "")):
        code = loc["attributes"].get("locale")
        if not code:
            continue
        payload["localizations"][code] = {
            api_attr: loc["attributes"].get(api_attr)
            for api_attr in ("promotionalText", "description", "keywords", "whatsNew")
        }

    serialized = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    if output_path == "-":
        sys.stdout.write(serialized)
        return
    with open(output_path, "w", encoding="utf-8") as fh:
        fh.write(serialized)
    n = len(payload["localizations"])
    print(f"  wrote {n} locale(s) to {output_path}")


def restore_from_json(
    session: requests.Session,
    version_string: str,
    app_id: str,
    localizations: list[dict],
    input_path: str,
    dry_run: bool,
) -> None:
    """Read a JSON file previously produced by --dump (or hand-edited
    in the same shape) and PATCH each locale it contains."""
    if not os.path.isfile(input_path):
        sys.exit(f"ERROR: restore file not found: {input_path}")
    with open(input_path, "r", encoding="utf-8") as fh:
        try:
            payload = json.load(fh)
        except json.JSONDecodeError as exc:
            sys.exit(f"ERROR: invalid JSON in {input_path}: {exc}")

    # Safety: refuse to restore if the file is for a different app or
    # version than what the user passed on the CLI. Forces explicit
    # intent if the file was renamed or moved between contexts.
    file_app = payload.get("appId")
    file_version = payload.get("versionString")
    if file_app and file_app != app_id:
        sys.exit(
            f"ERROR: appId mismatch — JSON says {file_app!r}, CLI / env "
            f"resolves to {app_id!r}. Use --app-id to override if intended."
        )
    if file_version and file_version != version_string:
        sys.exit(
            f"ERROR: versionString mismatch — JSON says {file_version!r}, "
            f"CLI says {version_string!r}."
        )

    locs_in_file = payload.get("localizations") or {}
    if not isinstance(locs_in_file, dict) or not locs_in_file:
        sys.exit(
            f"ERROR: JSON has no 'localizations' object, or it is empty: "
            f"{input_path}"
        )

    # Build a quick {code → resource id} lookup from the App Store
    # Connect side, so each PATCH knows where to land.
    code_to_loc = {
        l["attributes"].get("locale"): l for l in localizations
        if l["attributes"].get("locale")
    }

    # Validate every requested locale and field BEFORE issuing any PATCH,
    # so we never end up with a partial restore that silently dropped some
    # locales due to typos or oversize content.
    plan: list[tuple[str, str, dict]] = []  # (code, loc_id, attributes)
    skipped: list[str] = []
    for code, fields in locs_in_file.items():
        if code not in code_to_loc:
            skipped.append(code)
            continue
        if not isinstance(fields, dict):
            sys.exit(
                f"ERROR: locale {code!r} in JSON must map to an object of "
                f"fields, got {type(fields).__name__}."
            )
        attributes: dict[str, str] = {}
        for api_attr, value in fields.items():
            if api_attr not in FIELD_LIMITS:
                # Unknown field — ignore (forward-compat / typo tolerance).
                continue
            if value is None:
                # null in JSON = "leave the field untouched". Skip.
                continue
            if not isinstance(value, str):
                sys.exit(
                    f"ERROR: {code}/{api_attr} must be a string or null, "
                    f"got {type(value).__name__}."
                )
            limit = FIELD_LIMITS[api_attr]
            if len(value) > limit:
                sys.exit(
                    f"ERROR: {code}/{api_attr} is {len(value)} chars, "
                    f"max allowed is {limit}."
                )
            attributes[api_attr] = value
        if not attributes:
            # Empty plan for this locale — all values were null. Skip.
            continue
        plan.append((code, code_to_loc[code]["id"], attributes))

    if skipped:
        print(
            f"  WARN: {len(skipped)} locale(s) in JSON not configured on "
            f"version {version_string!r}: {sorted(skipped)} — skipping.",
            file=sys.stderr,
        )
    if not plan:
        sys.exit("ERROR: nothing to restore — the JSON had no actionable values.")

    print(f"→ Restore plan: {len(plan)} locale(s) to PATCH:")
    for code, _, attrs in plan:
        size = sum(len(v) for v in attrs.values())
        fields_summary = ", ".join(f"{k}({len(v)})" for k, v in attrs.items())
        print(f"  {code} → {fields_summary} [total {size} chars]")

    if dry_run:
        print("→ DRY RUN: no PATCH issued. Re-run without --dry-run to apply.")
        return

    for code, loc_id, attrs in plan:
        print(f"→ Patching {code} ({len(attrs)} field(s))…")
        patch_localization(session, loc_id, attrs)
    print(f"✅ Done. Restored {len(plan)} locale(s) on App Store Connect.")


def shorten(s: str, n: int = 80) -> str:
    """Render a value compactly for the human-readable diff output."""
    if s is None:
        return "(empty)"
    flat = s.replace("\n", "\\n")
    if len(flat) <= n:
        return repr(flat)
    return repr(flat[: n - 1] + "…")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Update the App Store Connect text fields (Promotional Text, "
            "Description, Keywords, What's New) for an iOS version, in a "
            "given localization page (e.g. en-US, fr-FR, de-DE, zh-Hans)."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  # 1) Discover the locales configured on version 1.2:\n"
            "  python3 update_app_store_listing.py 1.2\n"
            "\n"
            "  # 2) Update the French promotional text:\n"
            "  python3 update_app_store_listing.py 1.2 --locale fr-FR \\\n"
            '    --promotional-text "Capturez tout ce que vous partagez…"'
        ),
    )
    parser.add_argument(
        "version",
        help='CFBundleShortVersionString of the target version (e.g. "1.2").',
    )
    parser.add_argument(
        "--locale",
        help=(
            "Apple locale code identifying the localization page to update "
            "(e.g. en-US, fr-FR, de-DE, ja, zh-Hans). Mandatory for any "
            "PATCH. If omitted, the script lists the locale codes "
            "currently configured on this version, queried live from "
            "App Store Connect, and exits."
        ),
    )
    parser.add_argument(
        "--promotional-text",
        help=f"New Promotional Text (max {FIELD_LIMITS['promotionalText']} chars).",
    )
    parser.add_argument(
        "--description",
        help=f"New Description (max {FIELD_LIMITS['description']} chars).",
    )
    parser.add_argument(
        "--keywords",
        help=(
            f"New Keywords (comma-separated, max {FIELD_LIMITS['keywords']} chars). "
            "Apple's English-comma or Chinese-comma rule applies."
        ),
    )
    parser.add_argument(
        "--whats-new",
        help=(
            f"New What's New in This Version text "
            f"(max {FIELD_LIMITS['whatsNew']} chars). For multi-line text, use "
            '`--whats-new "$(cat notes.txt)"`.'
        ),
    )
    parser.add_argument(
        "--app-id",
        default=os.environ.get("ASC_APP_ID", DEFAULT_APP_ID),
        help=(
            f"Numeric App ID on App Store Connect. Default: {DEFAULT_APP_ID} "
            "(Captured). Override via this flag or the ASC_APP_ID env var."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "Do everything except the final PATCH: authenticate, locate the "
            "version, locate the locale, print the diff between current and "
            "proposed values, and stop. Useful for verifying credentials and "
            "arguments without touching the App Store Connect record."
        ),
    )
    parser.add_argument(
        "--show",
        action="store_true",
        help=(
            "Read-only mode. Print the current values of Promotional Text, "
            "Description, Keywords and What's New for the given --locale, "
            "then exit. Cannot be combined with content flags."
        ),
    )
    parser.add_argument(
        "--dump",
        metavar="FILE",
        help=(
            "Dump the four editable fields for every locale configured on "
            "the version into a JSON file at FILE (use '-' for stdout). "
            "Read-only — no PATCH. JSON format is documented in "
            "update_app_store_listing.md."
        ),
    )
    parser.add_argument(
        "--restore",
        metavar="FILE",
        help=(
            "Restore mode. Read a JSON file (produced by --dump or matching "
            "its schema) and PATCH every locale it contains for the given "
            "version. Respects --dry-run. Aborts if the file's appId / "
            "versionString don't match the CLI."
        ),
    )
    args = parser.parse_args()

    # Collect the {API attr → new value} pairs the user asked to update.
    updates: dict[str, str] = {}
    for cli_dest, api_attr in CLI_TO_API.items():
        val = getattr(args, cli_dest)
        if val is None:
            continue
        limit = FIELD_LIMITS[api_attr]
        if len(val) > limit:
            sys.exit(
                f"ERROR: --{cli_dest.replace('_', '-')} is {len(val)} chars, "
                f"max allowed is {limit}."
            )
        updates[api_attr] = val

    # Mutually exclusive modes — each pairs with a specific set of
    # other flags. Validate up front so the user sees the error before
    # any network call happens.
    if args.dump and args.restore:
        sys.exit("ERROR: --dump and --restore are mutually exclusive.")
    if args.dump and (args.show or updates or args.locale):
        sys.exit(
            "ERROR: --dump targets ALL locales; remove --show, --locale, "
            "and any content flags."
        )
    if args.restore and (args.show or updates or args.locale):
        sys.exit(
            "ERROR: --restore drives locales from the JSON file; remove "
            "--show, --locale, and any content flags."
        )
    if args.show and updates:
        sys.exit(
            "ERROR: --show is read-only and cannot be combined with content "
            "flags (--promotional-text, --description, --keywords, --whats-new)."
        )
    if args.show and not args.locale:
        sys.exit("ERROR: --show requires --locale <code>.")

    token = make_jwt()
    session = requests.Session()
    session.headers.update({
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    })

    print(f"→ Looking up iOS version {args.version!r} on app {args.app_id}…")
    version = find_version(session, args.app_id, args.version)
    version_id = version["id"]
    state = version["attributes"].get("appStoreState", "?")
    print(f"  found version id={version_id} state={state}")

    print("→ Fetching configured localizations…")
    localizations = fetch_all_localizations(session, version_id)
    available_locales = sorted(
        l["attributes"].get("locale", "?") for l in localizations
    )

    # --dump: serialize all locales/fields to a JSON file (or stdout).
    if args.dump:
        print(f"→ Dumping {len(localizations)} locale(s) to {args.dump!r}…")
        dump_to_json(args.version, args.app_id, localizations, args.dump)
        return

    # --restore: read JSON, plan PATCH for each locale it contains.
    if args.restore:
        restore_from_json(
            session,
            args.version,
            args.app_id,
            localizations,
            args.restore,
            args.dry_run,
        )
        return

    # No --locale → informational listing mode, then exit.
    if not args.locale:
        print(
            f"\nVersion {args.version!r} has {len(available_locales)} "
            "localization page(s) configured:"
        )
        for code in available_locales:
            print(f"  {code}")
        print(
            "\nRe-run with --locale <code> to update a specific page, "
            "e.g.:\n"
            f"  python3 {os.path.basename(sys.argv[0])} {args.version} "
            f"--locale {available_locales[0] if available_locales else 'en-US'} "
            "--promotional-text \"…\""
        )
        return

    print(f"→ Locating {args.locale!r} localization…")
    loc = pick_localization(localizations, args.locale)
    loc_id = loc["id"]
    print(f"  found localization id={loc_id}")
    attrs_now = loc.get("attributes", {})

    # --show: dump current values in full and exit.
    if args.show:
        print(f"\nCurrent values for version {args.version!r}, locale "
              f"{args.locale!r}:\n")
        for api_attr in ["promotionalText", "description", "keywords", "whatsNew"]:
            limit = FIELD_LIMITS[api_attr]
            val = attrs_now.get(api_attr) or ""
            print(f"--- {api_attr} ({len(val)}/{limit} chars) ---")
            print(val if val else "(empty)")
            print()
        return

    if not updates:
        sys.exit(
            "ERROR: nothing to do — provide at least one of "
            "--promotional-text, --description, --keywords, --whats-new, "
            "or use --show to read current values."
        )

    # Show a per-field before/after summary.
    print("→ Planned changes:")
    attrs_now = loc.get("attributes", {})
    for api_attr, new_val in updates.items():
        before = attrs_now.get(api_attr)
        before_len = len(before) if before else 0
        new_len = len(new_val)
        limit = FIELD_LIMITS[api_attr]
        print(
            f"  {api_attr} ({new_len}/{limit} chars, "
            f"was {before_len}):"
        )
        print(f"      before: {shorten(before)}")
        print(f"      after : {shorten(new_val)}")

    if args.dry_run:
        print("→ DRY RUN: no PATCH issued. Re-run without --dry-run to apply.")
        return

    print(f"→ Patching {len(updates)} field(s) on locale {args.locale!r}…")
    patch_localization(session, loc_id, updates)
    print("✅ Done. Listing updated on App Store Connect.")


if __name__ == "__main__":
    main()
