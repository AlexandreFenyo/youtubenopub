#!/usr/bin/env python3
"""
Copy the Promotional Text field of every locale present in a previous
version dump (default: appstore-1.1.json) into another version on
App Store Connect (default: 1.2). All other fields (Description,
Keywords, What's New) are left untouched on the target version.

This is a thin wrapper around update_app_store_listing.py: it builds a
derived JSON in which every locale's Promotional Text is set to the
1.1 value and the three other fields are `null` (= "leave untouched"),
then hands it to `update_app_store_listing.py --restore`.

Usage:
    # Defaults: source = appstore-1.1.json, target version = 1.2
    python3 copy_promotional_text.py

    # Dry-run first to see what would be patched
    python3 copy_promotional_text.py --dry-run

    # Different source / target
    python3 copy_promotional_text.py --source appstore-1.0.json --target-version 1.3

Prerequisites:
    Same as update_app_store_listing.py: ASC_KEY_ID, ASC_ISSUER_ID,
    ASC_PRIVATE_KEY env vars set. See update_app_store_listing.md
    section 2 for the one-time setup.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile

DEFAULT_SOURCE = "appstore-1.1.json"
DEFAULT_TARGET_VERSION = "1.2"
HELPER_SCRIPT = "update_app_store_listing.py"


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Propagate Promotional Text from one version's JSON dump to "
            "another version on App Store Connect, for every locale that "
            "had a non-empty value in the source. Other fields on the "
            "target are left untouched."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Example: copy promo text from 1.1 into 1.2 (the defaults):\n"
            "  python3 copy_promotional_text.py --dry-run\n"
            "  python3 copy_promotional_text.py"
        ),
    )
    parser.add_argument(
        "--source",
        default=DEFAULT_SOURCE,
        help=(
            f"Path to the JSON dump of the source version "
            f"(default: {DEFAULT_SOURCE}). Must be an output of "
            f"update_app_store_listing.py --dump or a hand-crafted file "
            f"matching that schema."
        ),
    )
    parser.add_argument(
        "--target-version",
        default=DEFAULT_TARGET_VERSION,
        help=(
            f"CFBundleShortVersionString of the destination version on "
            f"App Store Connect (default: {DEFAULT_TARGET_VERSION})."
        ),
    )
    parser.add_argument(
        "--app-id",
        help=(
            "Override the destination app id. Forwarded to "
            "update_app_store_listing.py --app-id. If omitted, the "
            "helper uses its own default / the ASC_APP_ID env var."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Forward --dry-run to update_app_store_listing.py (no PATCH).",
    )
    parser.add_argument(
        "--keep-tempfile",
        action="store_true",
        help=(
            "Don't delete the temporary derived JSON after the run. "
            "Useful to inspect what got handed to --restore."
        ),
    )
    args = parser.parse_args()

    if not os.path.isfile(args.source):
        sys.exit(f"ERROR: source file not found: {args.source}")

    with open(args.source, "r", encoding="utf-8") as fh:
        try:
            src = json.load(fh)
        except json.JSONDecodeError as exc:
            sys.exit(f"ERROR: invalid JSON in {args.source}: {exc}")

    src_locales = src.get("localizations") or {}
    if not isinstance(src_locales, dict) or not src_locales:
        sys.exit(
            f"ERROR: {args.source} has no 'localizations' object, or it "
            f"is empty."
        )

    src_version = src.get("versionString")
    if src_version and src_version == args.target_version:
        sys.exit(
            f"ERROR: source and target are the same version ({src_version!r}). "
            "Nothing to copy."
        )

    # Build the derived JSON. Skip locales with empty/null promo text —
    # there's nothing to copy there, and forwarding null would be a
    # no-op anyway (cf. § 6.2 in update_app_store_listing.md).
    derived_locs: dict[str, dict] = {}
    skipped_empty: list[str] = []
    for code, fields in src_locales.items():
        if not isinstance(fields, dict):
            continue
        promo = fields.get("promotionalText")
        if not promo:  # None or empty string
            skipped_empty.append(code)
            continue
        derived_locs[code] = {
            "promotionalText": promo,
            "description": None,
            "keywords": None,
            "whatsNew": None,
        }

    if not derived_locs:
        sys.exit(
            f"ERROR: no locale in {args.source} has a non-empty "
            "promotionalText to copy."
        )

    # Echo what's about to happen — so the user sees the per-locale
    # plan even before update_app_store_listing.py prints its own.
    print(
        f"→ Will copy promotionalText from {args.source} "
        f"(version {src_version!r}) into version "
        f"{args.target_version!r}, for {len(derived_locs)} locale(s):"
    )
    for code in sorted(derived_locs):
        promo_len = len(derived_locs[code]["promotionalText"])
        print(f"  {code}: {promo_len} chars")
    if skipped_empty:
        print(
            f"  (skipped {len(skipped_empty)} locale(s) with empty source: "
            f"{sorted(skipped_empty)})"
        )

    derived = {
        "appId": src.get("appId"),
        "versionString": args.target_version,
        "platform": src.get("platform", "IOS"),
        "exportedAt": src.get("exportedAt"),
        "exportedBy": (
            f"copy_promotional_text.py (derived from {args.source}, "
            f"originally {src.get('exportedBy', 'unknown')})"
        ),
        "localizations": derived_locs,
    }

    # Write the derived JSON to a temp file in the same directory as
    # the source — easier to inspect and consistent with relative paths.
    tmp_dir = os.path.dirname(os.path.abspath(args.source)) or "."
    fd, tmp_path = tempfile.mkstemp(
        prefix=f"copy-promo-to-{args.target_version}-",
        suffix=".json",
        dir=tmp_dir,
    )
    os.close(fd)
    with open(tmp_path, "w", encoding="utf-8") as fh:
        json.dump(derived, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    helper_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), HELPER_SCRIPT
    )
    if not os.path.isfile(helper_path):
        os.unlink(tmp_path)
        sys.exit(f"ERROR: helper script not found: {helper_path}")

    cmd = [
        sys.executable,
        helper_path,
        args.target_version,
        "--restore",
        tmp_path,
    ]
    if args.app_id:
        cmd.extend(["--app-id", args.app_id])
    if args.dry_run:
        cmd.append("--dry-run")

    print(f"→ Invoking helper: {' '.join(cmd)}\n")

    try:
        result = subprocess.run(cmd)
        rc = result.returncode
    finally:
        if args.keep_tempfile:
            print(f"\n(keeping temp file: {tmp_path})")
        else:
            os.unlink(tmp_path)

    sys.exit(rc)


if __name__ == "__main__":
    main()
