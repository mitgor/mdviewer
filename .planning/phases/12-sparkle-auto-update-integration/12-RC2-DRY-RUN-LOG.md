# v2.2.0-rc.2 Dry-Run Log (TEMPLATE — awaiting operator execution)

**Status:** TEMPLATE. Fill in every slot marked `<…>` or `<TBD>` as you
execute the dry-run. When the run is complete, remove this "(TEMPLATE —
awaiting operator execution)" suffix from the heading, set `Outcome` to
`OK` / `PARTIAL` / `FAIL`, and commit with a trailing
`docs(12-03): record v2.2.0-rc.2 dry-run evidence` message.

This log mirrors Phase 11's CI-13 dry-run-log pattern but scopes the
evidence to the Sparkle pipeline (Plan 12-01 app integration + Plan 12-02
CI appcast generation + Plan 12-03 real EdDSA key). It is the explicit
pre-release gate for the first Sparkle-enabled build — Task 7 of Plan
12-03.

---

**Executed:** `<YYYY-MM-DD>`
**Operator:** `<github-username>` (@`<gh-handle>`)
**Workflow run URL:** `<https://github.com/mitgor/mdviewer/actions/runs/XXXXXXXXXX>`

## Outcome

`<OK | PARTIAL | FAIL>` — `<one-paragraph summary: what ran, what passed,
what didn't, whether v2.2.0-final is cleared to ship.>`

---

## Prerequisites check (Step 7.1 — before tag push)

Paste the output of each command, or mark `CONFIRMED ✓` if the line
matched expectations.

```text
# Plan 1 committed.
$ grep -q 'package: Sparkle' project.yml && echo OK
<TBD>

# Plan 2 committed (scripts + workflow edits).
$ test -x Scripts/verify_bundle.sh && echo OK
<TBD>
$ test -x Scripts/generate_appcast.sh && echo OK
<TBD>
$ grep -q 'Verify bundle layout' .github/workflows/release.yml && echo OK
<TBD>
$ grep -q 'Generate EdDSA-signed appcast' .github/workflows/release.yml && echo OK
<TBD>

# Plan 3 Tasks 1-6 committed.
$ /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" MDViewer/Info.plist
<TBD — expect 220>
$ /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" MDViewer/Info.plist
<TBD — expect c7OOb7oj9UNlcQyjkANR7cPqfC+n/5r4EbvVIynhGWI=>
$ test -f docs/release/sparkle-setup.md && echo OK
<TBD>
$ ! grep -q 'DOCUMENT HERE WHEN BACKUP IS CREATED' docs/release/ci-secrets.md && echo OK
<TBD>

# SPARKLE_ED_PRIVATE_KEY secret installed.
$ gh secret list --repo mitgor/mdviewer | grep SPARKLE_ED_PRIVATE_KEY
<TBD — expect "SPARKLE_ED_PRIVATE_KEY  Updated YYYY-MM-DD">

# Main branch is clean.
$ git status --porcelain
<TBD — expect empty output>
```

All prerequisites must pass before tagging. If any fail: STOP and
diagnose; do not proceed to Step 7.2.

---

## Step 7.2 — Tag push

```text
# Tag from main at <expected SHA of Task 6 commit or later>:
$ git tag v2.2.0-rc.2
$ git push origin v2.2.0-rc.2

# Workflow watch:
$ gh run watch --repo mitgor/mdviewer
```

- **Tag SHA:** `<git rev-parse v2.2.0-rc.2>`
- **Push confirmed:** `<yes | no>`
- **Workflow triggered:** `<yes | no>`
- **Workflow run URL:** `<URL>`
- **Workflow total duration:** `<MM:SS>` (target: 25–30 minutes)

---

## Step 7.3 — Failure modes observed during watch

Tick any that occurred and paste diagnostic lines. If none, write `none`.

- [ ] `verify_bundle.sh` step failed → bundle layout regression (two
      Sparkle.frameworks, mismatched team IDs, missing XPCs).
      Paste the `::error::` line:
      ```
      <paste or "n/a">
      ```
- [ ] `generate_appcast.sh` step failed at "generate_appcast not found"
      → SPM didn't resolve during build_and_sign.
      Paste the failing line + the SPM cache-key context:
      ```
      <paste or "n/a">
      ```
- [ ] `generate_appcast.sh` step failed at "missing EdDSA signature"
      → SPARKLE_ED_PRIVATE_KEY newline corruption or wrong key.
      Paste the failing line:
      ```
      <paste or "n/a">
      ```
- [ ] Notarize step failed (unrelated to Sparkle; same diagnostic as
      Phase 11).
      Paste the failing line:
      ```
      <paste or "n/a">
      ```
- [ ] Other failure:
      ```
      <describe + paste + root cause>
      ```

If any step failed: record it here, set `Outcome` to `PARTIAL` or `FAIL`,
and STOP. Do not proceed to Step 7.4.

---

## Step 7.4 — Draft release verification

### 7.4a — Release metadata

```text
$ gh release view v2.2.0-rc.2 --repo mitgor/mdviewer --json isDraft,isPrerelease,assets | jq '.'
<TBD — paste full output>
```

Expected:
- `isDraft = true`
- `isPrerelease = true`
- `assets` includes `MDViewer-2.2.0-rc.2.dmg` AND `appcast.xml`

### 7.4b — Asset SHAs + sizes

```text
$ mkdir -p /tmp/rc2 && cd /tmp/rc2
$ gh release download v2.2.0-rc.2 --repo mitgor/mdviewer
$ shasum -a 256 MDViewer-2.2.0-rc.2.dmg appcast.xml
```

- `MDViewer-2.2.0-rc.2.dmg`
  - SHA256: `<paste>`
  - Size: `<bytes>`
- `appcast.xml`
  - SHA256: `<paste>`
  - Size: `<bytes>`

### 7.4c — Appcast element greps

Confirm the appcast carries the four required elements. Paste each
grep's output (or `MATCH` if you prefer a short form).

```text
$ grep 'sparkle:edSignature'             appcast.xml
<paste>

$ grep 'phasedRolloutInterval>43200'     appcast.xml
<paste>

$ grep 'minimumSystemVersion>13.0.0'     appcast.xml
<paste>

$ grep 'releaseNotesLink>https://github.com/mitgor/mdviewer/releases/tag/v2.2.0-rc.2'  appcast.xml
<paste>

$ grep 'enclosure.*MDViewer-2.2.0-rc.2.dmg'  appcast.xml
<paste>
```

### 7.4d — Signature validates against the real public key

If Sparkle's `sign_update --verify-update` tool is available locally:

```text
$ SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -path '*Sparkle*' | head -n1)
$ "$SIGN_UPDATE" --verify-update MDViewer-2.2.0-rc.2.dmg \
    -p c7OOb7oj9UNlcQyjkANR7cPqfC+n/5r4EbvVIynhGWI= \
    <EdDSA signature from appcast.xml>
<paste output — expect "Successfully verified" or equivalent>
```

Alternative: paste the `sparkle:edSignature` value from the appcast and
confirm (by eyeball) that it is 88-char base64. Capture the exact bytes:

- `sparkle:edSignature` value: `<paste full base64>`
- `sparkle:edSignature` length (chars): `<count>`

### 7.4e — Stapler validates the DMG

```text
$ xcrun stapler validate MDViewer-2.2.0-rc.2.dmg
<paste output — expect "The validate action worked!">
```

---

## Step 7.5 — Install the DMG and observe Sparkle's Check-for-Updates sheet

```text
$ hdiutil attach MDViewer-2.2.0-rc.2.dmg
# Drag MDViewer.app into /Applications (replace any prior copy).
$ open "/Applications/MDViewer.app"
```

In the running app: `MDViewer` menu → `Check for Updates…`

- **Sheet appeared:** `<yes | no>`
- **Sheet contents:** `<paste or describe>`
  - Typical: `"An error occurred while fetching updates. The feed returned
    a 404 error."` — expected because the rc.2 draft pre-release is NOT
    served from `/releases/latest/download/appcast.xml`. The **sheet
    appearing at all** proves Plan 1's wiring is correct against a real
    signed build.
- **Screenshot (optional):** `<path/to/screenshot.png or n/a>`

*(Full auto-install path — Sparkle downloads + verifies + relaunches —
cannot be tested with rc.2 alone because the draft pre-release feed 404s.
That path is tested on the v2.2.0-final publish and the subsequent
v2.2.1 bump. Deferred to post-ship monitoring.)*

---

## Step 7.6 — Workflow-log privacy check

Inspect the workflow run log for any accidentally-surfaced private key
material. The SPARKLE_ED_PRIVATE_KEY is ~44 chars of base64; any
base64-looking string of that length or longer in the log that isn't a
SHA256 hash is suspicious.

```text
$ gh run view <run-id> --repo mitgor/mdviewer --log | \
    awk 'length>=44 { for(i=1;i<=NF;i++) if(length($i)>=44 && $i ~ /^[A-Za-z0-9+\/=]+$/) print }' | \
    head -20
<TBD — paste output; expect only SHA256s + the public key (which is fine)>
```

- **Private-key-looking strings in log:** `<none | describe>`
- **Confirmed: no SPARKLE_ED_PRIVATE_KEY leak:** `<yes | no>`

---

## Step 7.7 — Cleanup

- [ ] `gh release delete v2.2.0-rc.2 --repo mitgor/mdviewer --cleanup-tag --yes`
  - Output: `<paste>`
- [ ] Local `/Applications/MDViewer.app` restored to v2.1 baseline OR
      kept as rc.2 for further local testing (operator's choice).
      Current state: `<v2.1 | v2.2.0-rc.2 | removed>`

---

## Assumptions checked (from 12-RESEARCH.md §Assumptions)

| ID | Assumption | Status | Notes |
|----|------------|--------|-------|
| A1 | Sparkle 2.9.1 builds cleanly under Xcode 26.2 on macos-26 runner | `<confirmed \| issue>` | `<notes>` |
| A2 | `releaseNotesLink` renders OK in Sparkle's update sheet | `<deferred-to-v2.2.0>` | rc.2 sheet errored on 404; A2 cannot be fully verified until the final v2.2.0 publish makes `/releases/latest/` resolve. |
| A3 | CFBundleVersion=220 integer scheme is accepted by Sparkle comparator | `<confirmed \| issue>` | verify_bundle.sh's integer-regex check reports `<paste pass/fail line>`. |
| A4 | XML round-trip preserves the EdDSA signature bit-for-bit | `<confirmed \| issue>` | `sparkle:edSignature` grep succeeds AND sign_update --verify-update passes. |
| A5 | `/releases/latest/download/` excludes pre-releases (isDraft=true + isPrerelease=true) | `<confirmed \| issue>` | rc.2 draft does NOT feed the /latest/ URL — hence the 404 in Step 7.5. |
| A6 | GitHub Actions secret redaction + stdin-only transport keeps key out of logs | `<confirmed \| issue>` | Step 7.6 privacy check result. |

---

## Ready to ship v2.2.0 final?

`<yes | no>` — `<brief reasoning; if no, what blocker and which plan/phase addresses it>`

---

## Change log

- `<YYYY-MM-DD>` — `<operator>` — initial run, Outcome=`<…>`.
- `<YYYY-MM-DD>` — `<operator>` — re-run after `<fix>`, Outcome=`<…>`.

---

## Notes for future operators

- The rc.2 tag is the FIRST time Plan 1 + Plan 2 + Plan 3 all ran
  together end-to-end. Expect quirks not seen in individual unit/
  integration tests. Capture every `::error::` or `::warning::` line
  verbatim.
- The draft release is supposed to be cleaned up (Step 7.7). If you
  need to keep the assets for longer (forensics, documentation),
  download them locally first — never leave a draft pre-release tag
  lying around in GitHub UI: future operators will mistake it for
  an in-flight release.
- If A2 (`releaseNotesLink` rendering) needs to be verified before
  the v2.2.0 final publish, a temporary workaround is to manually
  attach the same `appcast.xml` to a SEPARATE, non-draft pre-release
  tag (e.g. `v0.0.0-appcast-probe`) so the feed URL resolves. NOT
  part of the standard dry-run — optional, operator judgement.
