# `update_app_store_listing.py` — usage guide

Companion documentation for the script
[`update_app_store_listing.py`](./update_app_store_listing.py) at the
root of this repository. Intended for both human developers and AI
agents who need to drive the script without re-reading its source.

---

## 1. What the script does

A single-purpose CLI that talks to the **App Store Connect REST API**
to read or write the four editable text fields of one localization
page on one iOS App version of the Captured app (or any other app of
the team, via override).

Supported fields, with Apple's hard limits:

| CLI flag              | App Store Connect label            | API attribute      | Max chars |
| --------------------- | ---------------------------------- | ------------------ | --------- |
| `--promotional-text`  | Promotional Text                   | `promotionalText`  | 170       |
| `--description`       | Description                        | `description`      | 4 000     |
| `--keywords`          | Keywords (comma-separated)         | `keywords`         | 100       |
| `--whats-new`         | What's New in This Version         | `whatsNew`         | 4 000     |

Promotional Text can be re-edited at any time without resubmitting
the app for review. Description, Keywords, and What's New are
version metadata: changes are sent for review at the next app
submission, but can be edited freely while the version is in
`PREPARE_FOR_SUBMISSION` state.

---

## 2. Prerequisites

### 2.1 Python dependencies

```bash
pip3 install --user requests pyjwt cryptography
```

The script auto-detects missing modules and prints a `pip install`
hint if any of them is absent.

### 2.2 App Store Connect API key (one-time setup)

1. Log in to https://appstoreconnect.apple.com → **Users and Access**
   → **Integrations** → **App Store Connect API** → tab **Team Keys**.
2. **Generate API Key**. Suggested role: **Developer** (sufficient
   for PATCH on localizations) or **App Manager**.
3. Apple lets you download the private key `.p8` file **only once**.
   Save it in a safe place, e.g. `~/.appstore/AuthKey_XXXXXXXXXX.p8`.
4. Note the **Key ID** (column `ID`, 10 alphanumeric chars, matches
   the filename) and the **Issuer ID** (UUID at the top of the page).

### 2.3 Environment variables

The script reads three required env vars:

| Variable           | What it is                                          |
| ------------------ | --------------------------------------------------- |
| `ASC_KEY_ID`       | Key ID (10 chars, e.g. `8534RFTT7P`)                |
| `ASC_ISSUER_ID`    | Issuer ID (UUID)                                    |
| `ASC_PRIVATE_KEY`  | Absolute path to the `.p8` file                     |

Optional:

| Variable      | Default          | Notes                                       |
| ------------- | ---------------- | ------------------------------------------- |
| `ASC_APP_ID`  | `6763560506`     | Captured's App ID. Override for other apps. |

A convenient pattern is to keep them in
`~/.appstore/setvars.sh` and source it before each invocation. If
the file uses bare assignments (no `export`), wrap the sourcing in
`set -a` / `set +a` to auto-export. Example invocation:

```bash
set -a; . ~/.appstore/setvars.sh; set +a
python3 ./update_app_store_listing.py 1.2 --locale fr-FR --show
```

If the file already uses `export VAR=…` lines, the `set -a`/`set +a`
wrapper is redundant; a plain `. ~/.appstore/setvars.sh` suffices.

---

## 3. CLI shape

```
update_app_store_listing.py <version> [--locale CODE]
                            [--show]
                            [--dump FILE]
                            [--restore FILE]
                            [--promotional-text TEXT]
                            [--description TEXT]
                            [--keywords TEXT]
                            [--whats-new TEXT]
                            [--app-id ID]
                            [--dry-run]
```

| Positional       | What it is                                                                                                                         |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `<version>`      | `CFBundleShortVersionString` of the target version (e.g. `1.2`, `2.0`). Must already exist on App Store Connect for the target app. |

### 3.1 Five operating modes

The script dispatches between five mutually exclusive modes based on
the flags supplied:

| Mode        | Triggered by                                            | Effect                                                                                                  |
| ----------- | ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| **list**    | `<version>` only (no other mode flag)                  | Auths + prints every locale code configured on that version, then exits. Read-only.                     |
| **show**    | `<version> --locale CODE --show`                       | Auths + dumps the four current field values in full (no truncation) for that locale, then exits. Read-only. |
| **dump**    | `<version> --dump FILE`                                | Auths + serializes every locale's four fields into a JSON file (or stdout with `-`). Read-only. Schema below. |
| **restore** | `<version> --restore FILE`                             | Auths + reads JSON + PATCHes every locale it contains. Respects `--dry-run`. Schema below.              |
| **set**     | `<version> --locale CODE` + ≥1 content flag             | Auths + prints a before/after diff + PATCHes that one locale. Respects `--dry-run`.                     |

### 3.2 Mutually exclusive combinations (the script will reject them)

- `--dump` together with `--restore`, `--show`, `--locale`, or any
  content flag (dump targets ALL locales).
- `--restore` together with `--dump`, `--show`, `--locale`, or any
  content flag (restore drives locales from the JSON file).
- `--show` together with any content flag.
- `--show` without `--locale`.
- Any content flag whose value exceeds its character limit.
- `--locale` with no content flags and no `--show`.

### 3.3 Flag reference

| Flag                     | Optional | Mode triggered     | Notes                                                                                       |
| ------------------------ | -------- | ------------------ | ------------------------------------------------------------------------------------------- |
| `--locale CODE`          | yes      | enables show / set | Apple locale code: `en-US`, `fr-FR`, `de-DE`, `zh-Hans`, `ja`, etc. Absent → list mode.     |
| `--show`                 | yes      | show               | Read-only dump for one locale. Requires `--locale`. Cannot mix with content flags.           |
| `--dump FILE`            | yes      | dump               | Write a JSON of every locale/field to `FILE` (use `-` for stdout). Read-only.               |
| `--restore FILE`         | yes      | restore            | PATCH every locale present in `FILE`. JSON shape must match `--dump`'s output.              |
| `--promotional-text T`   | yes      | set                | Edits Promotional Text. Live-editable on App Store at any time.                             |
| `--description T`        | yes      | set                | Edits Description. Becomes part of next submission.                                         |
| `--keywords T`           | yes      | set                | Comma-separated. ASCII or Chinese comma both accepted.                                      |
| `--whats-new T`          | yes      | set                | Edits What's New. Use `"$(cat file.txt)"` for multi-line text.                              |
| `--app-id ID`            | yes      | any                | Overrides `ASC_APP_ID` env var and the built-in default.                                    |
| `--dry-run`              | yes      | set / restore      | Runs the full plan but skips the final PATCH(es). Useful to verify auth + diff first.       |

---

## 4. Examples

### 4.1 Discover which locales are configured on version 1.2

```bash
python3 ./update_app_store_listing.py 1.2
```

Sample output:
```
Version '1.2' has 50 localization page(s) configured:
  ar-SA
  bn-BD
  ca
  …
  zh-Hans
  zh-Hant
```

### 4.2 Inspect the current French page

```bash
python3 ./update_app_store_listing.py 1.2 --locale fr-FR --show
```

Prints each of the four fields with its current length and full
contents (or `(empty)` if unset).

### 4.3 Set the French Promotional Text (live update)

```bash
python3 ./update_app_store_listing.py 1.2 --locale fr-FR \
    --promotional-text "Capturez et organisez tout ce que vous partagez — désormais avec synchronisation iCloud."
```

### 4.4 Set Description + Keywords for the U.S. English page

```bash
python3 ./update_app_store_listing.py 1.2 --locale en-US \
    --description "Captured collects and organizes everything you share — links, photos, videos, files — with AI descriptions, OCR, audio transcription, and per-folder iCloud sync." \
    --keywords "bookmark,save,read,later,link,url,photo,clipboard,inbox,folder,icloud,sync,ai,ocr,widget,offline"
```

### 4.5 Push release notes from a file

```bash
python3 ./update_app_store_listing.py 1.2 --locale en-US \
    --whats-new "$(cat release-notes-1.2.txt)"
```

### 4.6 Dry-run all four fields before committing

```bash
python3 ./update_app_store_listing.py 1.2 --locale en-US --dry-run \
    --promotional-text "…" \
    --description "…" \
    --keywords "…" \
    --whats-new "$(cat release-notes-1.2.txt)"
```

The script prints the before/after diff for each field and exits
without PATCHing.

### 4.7 Dump every locale to a JSON snapshot

```bash
python3 ./update_app_store_listing.py 1.2 --dump asc-listing-1.2.json
```

Or to stdout (useful for piping into `jq`):

```bash
python3 ./update_app_store_listing.py 1.2 --dump - | jq '.localizations | keys'
```

### 4.8 Edit the JSON, then restore

After running `--dump`, open the resulting JSON in any text editor,
modify the values you want — for instance, the `keywords` field of
five locales — then push everything back in a single command:

```bash
python3 ./update_app_store_listing.py 1.2 --restore asc-listing-1.2.json --dry-run
python3 ./update_app_store_listing.py 1.2 --restore asc-listing-1.2.json
```

Restore is **atomic per locale** (each locale is one PATCH), but
**not atomic across locales** (failures on one don't roll back
previous successes — see § 8 Behavioral notes).

### 4.9 Same command against a different app

```bash
python3 ./update_app_store_listing.py 3.5 --app-id 1234567890 \
    --locale en-US --show
```

---

## 5. Output format

### list mode
```
→ Looking up iOS version '<v>' on app <app_id>…
  found version id=<uuid> state=<state>
→ Fetching configured localizations…

Version '<v>' has N localization page(s) configured:
  <code1>
  <code2>
  …
Re-run with --locale <code> to update a specific page, e.g.:
  python3 update_app_store_listing.py <v> --locale <code1> --promotional-text "…"
```

### show mode
```
→ Looking up iOS version '<v>' on app <app_id>…
  found version id=<uuid> state=<state>
→ Fetching configured localizations…
→ Locating '<locale>' localization…
  found localization id=<uuid>

Current values for version '<v>', locale '<locale>':

--- promotionalText (<len>/170 chars) ---
<full value or "(empty)">

--- description (<len>/4000 chars) ---
<full value or "(empty)">

--- keywords (<len>/100 chars) ---
<full value or "(empty)">

--- whatsNew (<len>/4000 chars) ---
<full value or "(empty)">
```

### set mode
```
→ Looking up iOS version '<v>' on app <app_id>…
  found version id=<uuid> state=<state>
→ Fetching configured localizations…
→ Locating '<locale>' localization…
  found localization id=<uuid>
→ Planned changes:
  promotionalText (<new_len>/170 chars, was <old_len>):
      before: '<truncated old value>'
      after : '<truncated new value>'
  …
→ Patching N field(s) on locale '<locale>'…
✅ Done. Listing updated on App Store Connect.
```

Replace the last two lines with:
```
→ DRY RUN: no PATCH issued. Re-run without --dry-run to apply.
```
when `--dry-run` is passed.

### dump mode
```
→ Looking up iOS version '<v>' on app <app_id>…
  found version id=<uuid> state=<state>
→ Fetching configured localizations…
→ Dumping N locale(s) to '<path>'…
  wrote N locale(s) to <path>
```

### restore mode
```
→ Looking up iOS version '<v>' on app <app_id>…
  found version id=<uuid> state=<state>
→ Fetching configured localizations…
→ Restore plan: N locale(s) to PATCH:
  <code1> → description(1483), keywords(84) [total 1567 chars]
  <code2> → promotionalText(65), description(1853), keywords(96) [total 2014 chars]
  …
→ Patching <code1> (2 field(s))…
→ Patching <code2> (3 field(s))…
✅ Done. Restored N locale(s) on App Store Connect.
```

With `--dry-run`, the per-locale PATCH lines are replaced by:
```
→ DRY RUN: no PATCH issued. Re-run without --dry-run to apply.
```

If the JSON references locales not configured on the version, a
warning lists them before the plan:
```
  WARN: 3 locale(s) in JSON not configured on version '<v>': ['xx-XX', …] — skipping.
```

---

## 6. JSON dump format

The file produced by `--dump` (and consumed by `--restore`) is a
single JSON object. Top-level keys:

| Key              | Type   | Notes                                                                            |
| ---------------- | ------ | -------------------------------------------------------------------------------- |
| `appId`          | string | Apple's numeric App ID. Checked on restore against the CLI / env.                |
| `versionString`  | string | `CFBundleShortVersionString` (e.g. `"1.2"`). Checked on restore against the CLI. |
| `platform`       | string | Always `"IOS"` for now (the script only targets iOS versions).                   |
| `exportedAt`     | string | ISO-8601 UTC timestamp of the dump. Informational only.                          |
| `exportedBy`     | string | Always `"update_app_store_listing.py"`. Informational only.                      |
| `localizations`  | object | Keyed by Apple locale code (`en-US`, `fr-FR`, `zh-Hans`…). See below.            |

Each `localizations[<code>]` is an object with exactly four keys —
the four editable text fields — each either a **string** with the
current value, or **`null`** if unset:

| Key                 | Type             | Notes                                                |
| ------------------- | ---------------- | ---------------------------------------------------- |
| `promotionalText`   | `string \| null` | ≤ 170 characters when present.                       |
| `description`       | `string \| null` | ≤ 4 000 characters when present.                     |
| `keywords`          | `string \| null` | ≤ 100 characters when present, comma-separated list. |
| `whatsNew`          | `string \| null` | ≤ 4 000 characters when present.                     |

### 6.1 Example (truncated to two locales)

```json
{
  "appId": "6763560506",
  "versionString": "1.2",
  "platform": "IOS",
  "exportedAt": "2026-05-15T09:40:36Z",
  "exportedBy": "update_app_store_listing.py",
  "localizations": {
    "en-US": {
      "promotionalText": "Capture and organize everything you share — now with iCloud sync.",
      "description": "Captured collects and organizes everything you share…",
      "keywords": "bookmark,save,read,later,link,url,photo,clipboard,inbox,folder,icloud,sync,ai,ocr,widget,offline",
      "whatsNew": null
    },
    "fr-FR": {
      "promotionalText": null,
      "description": "Marre de perdre les liens qu'on vous envoie…",
      "keywords": "favori,sauvegarder,lire,lien,url,photo,presse-papier,boîte,dossier,icloud,sync,ia,ocr,widget",
      "whatsNew": null
    }
  }
}
```

### 6.2 Editing rules for `--restore`

When the script restores a JSON document, each locale's PATCH body
is built field by field with these rules:

- **`null` is "leave the current value untouched"** — the script
  does NOT send `null` to the API (Apple's API would interpret it
  ambiguously, and clearing required fields like `description` is
  rejected). Use `null` for any field you didn't mean to change.
- **Empty string `""`** is **forwarded as-is** to Apple. Apple may
  reject empty for required fields (`description`, `keywords`). Use
  `null` if your intent is "no change", `""` only if your intent is
  "clear this optional field" (e.g. `promotionalText`, `whatsNew`).
- **String length** is validated against the field's limit
  (§ 1) before any HTTP call.
- **Unknown keys** inside a locale object are silently ignored
  (forward-compatibility — Apple may add fields without breaking
  older JSON dumps).
- **Unknown locale codes** (present in JSON but not configured on
  the App Store Connect version) trigger a warning and are
  skipped — no error, since reverting partial state would be worse
  than just informing the operator.

### 6.3 Authoring a partial JSON by hand

You don't have to start from a `--dump`. A minimal valid file that
only updates two locales' keywords looks like:

```json
{
  "versionString": "1.2",
  "localizations": {
    "en-US": {
      "promotionalText": null,
      "description": null,
      "keywords": "bookmark,save,read,later,…",
      "whatsNew": null
    },
    "fr-FR": {
      "promotionalText": null,
      "description": null,
      "keywords": "favori,sauvegarder,lire,…",
      "whatsNew": null
    }
  }
}
```

The `appId` key can be omitted (no app-id check then); the
`versionString` key is recommended for safety but not strictly
required (the CLI's positional `<version>` is always authoritative).

---

## 7. Common errors and how to recover

| Symptom                                                                                                  | Likely cause                                                                                                       | Fix                                                                                          |
| -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| `ERROR: missing dependency ('jwt').`                                                                     | `pyjwt` not installed.                                                                                             | `pip3 install --user requests pyjwt cryptography`                                            |
| `ERROR: missing required environment variable(s): ASC_KEY_ID, …`                                         | Env vars not exported.                                                                                             | Source `setvars.sh` with `set -a` wrapper, or `export` directly.                             |
| `ERROR: private key file not found: …`                                                                   | `ASC_PRIVATE_KEY` path wrong.                                                                                      | Correct the path. Files are `.p8`, downloaded once from App Store Connect.                   |
| `HTTP 401 — Authentication credentials are missing or invalid.`                                          | Key ID / Issuer ID mismatched or expired key.                                                                      | Verify `ASC_KEY_ID` matches the filename `AuthKey_<KEY_ID>.p8`. Re-issue the key if revoked. |
| `ERROR: no iOS AppStoreVersion with versionString=… found`                                               | Version doesn't exist on App Store Connect yet, or exists only on macOS.                                           | Create the version draft in App Store Connect first, or correct the version string.          |
| `ERROR: locale 'xx-XX' is not configured on this version.`                                               | Locale page not added.                                                                                             | List available locales (no `--locale`), then call again with one of those.                   |
| `ERROR: --promotional-text is N chars, max allowed is 170.`                                              | Text too long.                                                                                                     | Shorten the text. Counts characters (Unicode codepoints, ≈ glyphs).                          |
| `ERROR: --show is read-only and cannot be combined with content flags.`                                  | Misuse of CLI.                                                                                                     | Remove `--show` to set values, or remove content flags to read them.                         |
| `ERROR: --dump and --restore are mutually exclusive.`                                                    | Both flags supplied.                                                                                               | Pick one mode per invocation.                                                                |
| `ERROR: --dump targets ALL locales; remove --show, --locale, and any content flags.`                     | Mode mixing.                                                                                                       | Remove the offending flags.                                                                  |
| `ERROR: --restore drives locales from the JSON file; remove …`                                           | Mode mixing.                                                                                                       | Remove the offending flags.                                                                  |
| `ERROR: restore file not found: <path>`                                                                  | Path passed to `--restore` is wrong or relative to wrong cwd.                                                      | Use an absolute path, or `ls` first to verify.                                               |
| `ERROR: invalid JSON in <path>: …`                                                                       | The file is corrupt or hand-edited improperly.                                                                     | Re-dump or validate with `python3 -m json.tool < file`.                                      |
| `ERROR: appId mismatch — JSON says X, CLI resolves to Y.`                                                | The dump came from a different app, or `ASC_APP_ID` is wrong.                                                      | Use `--app-id X` to override, or fix the env var.                                            |
| `ERROR: versionString mismatch — JSON says X, CLI says Y.`                                               | The dump is for a different version than what you're restoring to.                                                 | Re-dump, or pass `<version>` matching the JSON.                                              |
| `ERROR: nothing to restore — the JSON had no actionable values.`                                         | Every locale's fields are `null`.                                                                                  | Edit the JSON to have at least one non-null string somewhere.                                |
| `HTTP 4xx` on PATCH                                                                                      | Field validation failure on Apple's side (e.g. forbidden keyword, version not editable).                           | Read the JSON error body printed to stderr; fix the offending field.                         |

---

## 8. API surface used (for AI agents inspecting integration choices)

The script touches only three endpoints, all on
`https://api.appstoreconnect.apple.com/v1`:

1. **`GET /apps/<app_id>/appStoreVersions`**  
   Filtered by `versionString` and `platform=IOS`. Returns the
   `appStoreVersion` record whose UUID is needed for the next call.
2. **`GET /appStoreVersions/<version_id>/appStoreVersionLocalizations`**  
   Lists all locale pages for the version, including current values of
   `promotionalText`, `description`, `keywords`, `whatsNew`.
3. **`PATCH /appStoreVersionLocalizations/<loc_id>`**  
   Updates the four fields atomically. Body is a JSON:API document of
   type `appStoreVersionLocalizations`. Only the attributes supplied
   are sent; others are left untouched.

Authentication is a JWT signed with the developer's ES256 `.p8`
private key, including `kid` (Key ID) in the header and `iss` (Issuer
ID), `iat`, `exp` (≤ 20 min), `aud=appstoreconnect-v1` in the
payload. Token lifetime is set to 20 min.

---

## 9. Behavioral notes

- **Atomic PATCH per locale.** All updates for one locale land in a
  single API call; if Apple rejects one field, none of that
  locale's fields are applied. In `--restore` mode each locale is
  one such atomic PATCH, but the run as a whole is **not** atomic
  across locales — a failure mid-restore leaves earlier locales
  applied. Use `--dry-run` first.
- **No automatic translation.** If you set `--locale fr-FR
  --promotional-text "Hello"`, that English string lands as-is on
  the French page. The script does not translate.
- **Diff is informational only.** The before/after diff shown in set
  mode is computed locally from the latest GET response. It does not
  represent a transactional check: an intervening edit by another
  actor could change values between the diff and the PATCH.
- **`set` mode targets one locale; `restore` mode targets many.**
  To update one or two locales ad-hoc, use `--locale CODE` with
  content flags. To update many at once (or to round-trip the
  listing through a text editor), use `--dump` then `--restore`.
- **No write to the running app version.** Only the `inflight`
  version (state `PREPARE_FOR_SUBMISSION` or later editable states)
  is mutable via the API in this manner. Trying to mutate a
  `READY_FOR_SALE` version yields an Apple-side 409.
- **`null` in JSON restore means "leave untouched"** — see § 6.2.
- **Unknown locales in JSON are skipped with a warning** —
  the restore plan only includes locales that exist on the App
  Store Connect side.

---

## 10. Quick reference: minimal one-liners

```bash
# Discover locales
python3 ./update_app_store_listing.py 1.2

# Read everything for one locale
python3 ./update_app_store_listing.py 1.2 --locale fr-FR --show

# Update promo text only
python3 ./update_app_store_listing.py 1.2 --locale fr-FR \
    --promotional-text "…"

# Update everything at once (dry-run first)
python3 ./update_app_store_listing.py 1.2 --locale en-US --dry-run \
    --promotional-text "…" \
    --description "…" \
    --keywords "…" \
    --whats-new "$(cat notes.txt)"

# Snapshot the whole listing to a JSON file…
python3 ./update_app_store_listing.py 1.2 --dump asc-listing-1.2.json

# …edit the JSON in your text editor, then push it back
python3 ./update_app_store_listing.py 1.2 --restore asc-listing-1.2.json --dry-run
python3 ./update_app_store_listing.py 1.2 --restore asc-listing-1.2.json
```

---

## 11. Workflow: rolling a listing from version N to N+1

When you ship version N and start preparing N+1, you typically want to:

1. **Carry over** Description, Keywords (and optionally Promotional
   Text) that you've polished on N.
2. **Promote** the release notes from N (`whatsNew`) into the body of
   the Description on N+1, because by the time N+1 ships, those
   features are no longer "new" — they're part of what the app does.
3. **Leave `whatsNew` empty** on N+1, so you can write fresh release
   notes for the new release.

The recommended sequence below uses **N = 1.1** and **N+1 = 1.2** as
the running example. Substitute your own version strings.

### 11.1 Dump version N

```bash
python3 ./update_app_store_listing.py 1.1 --dump appstore-1.1.json
```

This produces `appstore-1.1.json` with the four editable fields for
every locale configured on version 1.1.

### 11.2 (Optional) Copy Promotional Text from N to N+1

If version N+1 was created from scratch (or via "Create New Version"
in App Store Connect) and inherited blank Promotional Text values,
use the helper that wraps `update_app_store_listing.py --restore`:

```bash
python3 ./copy_promotional_text.py --source appstore-1.1.json --target-version 1.2 --dry-run
python3 ./copy_promotional_text.py --source appstore-1.1.json --target-version 1.2
```

This only touches `promotionalText` on every locale; the other three
fields remain whatever they currently are on N+1.

### 11.3 Roll the dump JSON to target N+1 (merge `whatsNew` → description)

Read `appstore-1.1.json`, drop the first two paragraphs of `whatsNew`
per locale (the header — e.g. "What's New in This Version" — and the
short intro paragraph), append the remaining feature sections to
`description`, clear `whatsNew`, and retarget `versionString` to the
new version. Write the result to `appstore-1.2.json`.

If you do this often, lift this snippet into a dedicated helper. The
inline form below is concise enough to keep handy:

```bash
python3 - <<'PY'
import json, re

SRC = 'appstore-1.1.json'
DST = 'appstore-1.2.json'
TARGET = '1.2'
DESC_LIMIT = 4000

with open(SRC, encoding='utf-8') as fh:
    d = json.load(fh)

over = []
for code, fields in d['localizations'].items():
    desc = (fields.get('description') or '').rstrip()
    whats = (fields.get('whatsNew') or '').strip()
    if whats:
        paragraphs = [p.strip() for p in re.split(r'\n\s*\n', whats) if p.strip()]
        features = paragraphs[2:]  # drop header + intro paragraph
        if features:
            desc = desc + '\n\n' + '\n\n'.join(features)
    if len(desc) > DESC_LIMIT:
        over.append((code, len(desc)))
    fields['description'] = desc
    fields['whatsNew'] = None

d['versionString'] = TARGET
d['exportedBy'] = f'derived from {SRC} — whatsNew merged into description'

if over:
    print(f'WARNING: {len(over)} locale(s) exceed {DESC_LIMIT} chars — '
          f'hand-trim before restore: {over}')

with open(DST, 'w', encoding='utf-8') as fh:
    json.dump(d, fh, ensure_ascii=False, indent=2)
    fh.write('\n')

print(f'Wrote {DST}')
PY
```

**Why drop the first two paragraphs?** Because the `whatsNew` content
on App Store Connect conventionally starts with a "What's New" header
line and a short marketing intro paragraph that don't belong in the
permanent app Description — only the per-feature sections do. Adjust
the slice if your `whatsNew` follows a different convention.

**Synthesis if oversize.** If the script prints a `WARNING: N
locale(s) exceed 4000 chars`, hand-edit those locales in
`appstore-1.2.json` (shorten the description body) before continuing.

### 11.4 Restore N+1 from the rolled JSON

```bash
# Verify what would be PATCHed:
python3 ./update_app_store_listing.py 1.2 --restore appstore-1.2.json --dry-run

# Apply for real:
python3 ./update_app_store_listing.py 1.2 --restore appstore-1.2.json
```

The restore step pushes the merged `description` and the original
`keywords` to N+1 for every locale. `whatsNew` is `null` in the JSON,
so the script leaves it untouched on App Store Connect — useful if
you've already drafted fresh release notes for N+1 (otherwise it
remains empty and you fill it manually in step 11.5).

### 11.5 Finalize on App Store Connect

- Visit the version's page on App Store Connect, locale by locale,
  and proofread the merged Description (the spliced section from
  `whatsNew` may need a one-line cleanup at the seam).
- Write the **What's New in This Version** field for N+1, describing
  the new features being shipped this time.
- When ready, click **Add for Review** / **Submit for Review**.

### 11.6 One-shot summary

```bash
# Set up auth
set -a; . ~/.appstore/setvars.sh; set +a

# 1) Snapshot N
python3 ./update_app_store_listing.py 1.1 --dump appstore-1.1.json

# 2) Carry over Promotional Text (optional)
python3 ./copy_promotional_text.py --target-version 1.2

# 3) Merge whatsNew into description, retarget to N+1
python3 - <<'PY'
# (snippet from 11.3 above)
PY

# 4) Push to N+1
python3 ./update_app_store_listing.py 1.2 --restore appstore-1.2.json --dry-run
python3 ./update_app_store_listing.py 1.2 --restore appstore-1.2.json
```
