# Feature Landscape — v2.2 Release Quality & Automation

**Domain:** Distribution / release pipeline for a quick-preview macOS app
**Researched:** 2026-04-18
**Confidence:** HIGH (Sparkle, notarytool, Homebrew docs all official); MEDIUM on Sparkle UI implications without preferences window (extrapolated from API ref + community threads)
**Scope:** Capabilities exposed by Sparkle 2.x, GitHub Actions, notarytool, and Homebrew Cask. ENABLE/SKIP/MAYBE per feature for MDViewer's one-window quick-preview model.

Guiding principle: MDViewer has **no preferences window, no persistence, no menu other than the standard menubar**. Every feature that requires per-app UI surface or persisted user choice is suspect. Defaults that "just work" win.

---

## 1. Sparkle 2.x Feature Surface

| Feature | Recommendation | Why |
|---|---|---|
| **EdDSA signature verification** (`SUPublicEDKey`) | ENABLE | Mandatory in Sparkle 2 for non-notarized payloads; the public key embeds in Info.plist, private key lives in CI secret. Zero UI cost. |
| **Apple code-sign verification** (Developer ID, automatic) | ENABLE | Free side-effect of already-signed/notarized builds; Sparkle uses it as a second factor next to EdDSA. |
| **`SUFeedURL`** (single appcast endpoint) | ENABLE | Required. Host as `appcast.xml` on `mitgor.github.io` or in `gh-pages` of the main repo — static, no infra. |
| **`SUEnableAutomaticChecks` = true** | ENABLE | Default daily check is the entire point of adding Sparkle. First launch is skipped automatically (good for a quick-preview tool — user opens, we don't interrupt). |
| **`SUScheduledCheckInterval`** (default 86400s / 1 day) | ENABLE default | Daily is correct for a viewer that may stay running for minutes only. Don't override. |
| **`SUAllowsAutomaticUpdates` = true** (silent background install) | MAYBE | Powerful, but Sparkle's first-time prompt asks the user to opt in — that prompt is the closest thing to a "preferences UI" we'll have. ENABLE if we accept one prompt on first update; SKIP if we want zero modals beyond the update sheet itself. **Recommendation:** ENABLE (one prompt on first update is acceptable). |
| **`SUAutomaticallyUpdate` = YES** (force silent, no prompt) | SKIP | Bypasses user consent; appropriate only for managed enterprise deployments. Not us. |
| **"Check for Updates…" menu item** (`SPUStandardUpdaterController.checkForUpdates:`) | ENABLE | Single `NSMenuItem` under app menu, wired to the standard controller. Zero-config, expected by macOS users, and our only manual-check entry point given no preferences pane. |
| **Standard update alert UI** (Install / Remind Me Later / Skip This Version buttons) | ENABLE | Stock Sparkle sheet — no custom UI needed. "Skip This Version" persists in Sparkle's own UserDefaults domain, so we don't have to manage state. |
| **Release notes display** (HTML or `.md` since Sparkle 2.9) | ENABLE | `releaseNotesLink` in appcast points to per-version `.html`. CI generates from CHANGELOG / GitHub release body. Killer feature — users see what they're updating to. |
| **`SURequireSignedFeed`** (sign appcast.xml itself, not just the .dmg) | MAYBE | Defends against a compromised appcast host. Adds one extra `sign_update` call in CI. Low cost — recommend ENABLE for paranoia, but SKIP is acceptable since EdDSA on the enclosure already prevents malicious payloads. |
| **`sparkle:minimumSystemVersion`** | ENABLE | Set to `13.0` to match deployment target. Prevents Sparkle from offering updates that won't launch on the user's macOS. Free. |
| **Beta channels** (`sparkle:channel="beta"` + `SUFeedChannels` in Info.plist) | SKIP | We have no beta program and no preferences UI to switch channels. Single stable channel only. Reconsider if v2.3+ adds prerelease testers. |
| **`sparkle:criticalUpdate`** (suppresses Skip / Remind buttons) | MAYBE | Reserve for security fixes only. Don't enable per default; it's a per-release flag in the appcast. Document the flag exists, use sparingly. |
| **`sparkle:phasedRolloutInterval`** (gradual rollout over 7 buckets) | MAYBE | 86400s × 7 buckets = 7-day full rollout. Useful for catching regressions. Low traffic app — set to e.g. 43200 (12h × 7 = 3.5 days). ENABLE on point releases, SKIP on patch hotfixes. **Recommendation:** ENABLE with 43200. |
| **`sparkle:informationalUpdate`** (download-only, link to website) | SKIP | We always ship a real package. No use case for "go look at this." |
| **Delta updates** (binary patches via `BSDiff`/`BinaryDelta`) | SKIP | Our `.app` is small (≤10MB shipped) and the .dmg compresses well; full-download cost is negligible. `generate_appcast` will still produce them if old archives remain in the directory — just don't host them. Reconsider if app crosses 50MB. |
| **Sandboxed-app XPC services** (`SUEnableInstallerLauncherService` etc.) | SKIP | We don't sandbox (no entitlements file). If we ever add the App Sandbox we'll need these. |
| **`SUEnableSystemProfiling`** (anonymous OS/HW telemetry to appcast) | SKIP | Sends OS version, hardware, prefs to the feed URL on every check. Privacy posture for a local viewer says no. |
| **`SUEnableJavaScript`** (in release notes WebView) | SKIP | Release notes are static — no need to expand attack surface. Disable explicitly. |
| **`SUAllowedURLSchemes`** (custom schemes in release notes) | SKIP | Plain HTTPS links are sufficient. |
| **Custom UI via `SPUUserDriver`** | SKIP | Standard driver is good. Custom UI is for apps that integrate update prompts into their main window — we don't have one. |
| **`SPUUpdaterDelegate` hooks** (e.g. `feedURLString:`, `updaterShouldRelaunchApplication:`) | MAYBE | Implement just one: `updaterMayCheckForUpdates:` returning `false` while a print/PDF export is in flight, so we don't disrupt that operation. Otherwise default behavior is fine. |
| **Gentle Reminders API** (`SPUStandardUserDriverDelegate`, Sparkle 2.2+) | MAYBE | Lets us suppress the update sheet if the user is mid-rendering and only show it when the app becomes inactive. Nice-to-have, low priority. SKIP for v2.2, reconsider in v2.3. |
| **Key rotation** (cert change, EdDSA rotation) | MAYBE (document only) | Procedural — note in release runbook that we can rotate keys but not both at once. Not a config flag; documentation item. |
| **Signed update install** (Apple-signed installers via productsign) | SKIP | We ship `.dmg` containing `.app`, not `.pkg`. Not applicable. |

**Sparkle UI implication of "no preferences window":** The standard `SPUStandardUpdaterController` does NOT require a preferences UI. The "Check for Updates…" menu item plus the modal update sheet handle the entire interaction. Sparkle stores preferences (skip-version, "automatically download" opt-in, last-check timestamp) in its own UserDefaults domain — we don't need to expose a settings pane. The one interaction that approaches "preferences" is the first-time prompt asking whether to install updates automatically; this is a single sheet, not a persistent UI surface, and is acceptable.

---

## 2. GitHub Actions Release Workflow Features

| Feature | Recommendation | Why |
|---|---|---|
| **Tag-triggered workflow** (`on: push: tags: ['v*']`) | ENABLE | Single source of truth: bump version → tag → release. Matches our existing manual flow. |
| **`xcodebuild archive` on `macos-latest` runner** | ENABLE | Free for public repos, 14 GB / 7 GB ARM runner. Check `Package.resolved` builds reproducibly. |
| **Build matrix for arm64 + x86_64** | SKIP — use **Universal Binary** instead | Matrix doubles build time and complicates appcast (two enclosures). `xcodebuild ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO` produces one universal `.app`. cmark-gfm and Sparkle both support both archs. Universal `.app` ≈ 2× single-arch in size, still trivial. |
| **Code-sign step** (`codesign --options runtime --timestamp`) | ENABLE | Hardened Runtime + secure timestamp are notarization prerequisites. Use `import-codesign-certs` action or `security import` directly with a temp keychain. |
| **Notarize step** (`xcrun notarytool submit --wait`) | ENABLE | See section 3 for flag detail. |
| **Staple ticket** (`xcrun stapler staple`) | ENABLE | Without it, Gatekeeper checks online on first launch — bad UX on flaky networks. Staple to both `.app` and `.dmg`. |
| **DMG creation** (`create-dmg` or hand-rolled `hdiutil`) | ENABLE | Hand-rolled `hdiutil` script is ~10 lines, no dependency. Background image / window layout are aesthetic — defer. |
| **Sparkle `sign_update`** for the `.dmg` | ENABLE | Run after notarization (signature is over bytes, not over notarization ticket). Output goes into appcast.xml. |
| **`generate_appcast`** (Sparkle CLI) | ENABLE | Maintains appcast.xml automatically — give it a directory of all past `.dmg`s and it produces correct XML. Cache the directory between runs (S3, GitHub Pages branch, or git-tracked). |
| **Publish appcast.xml** (GitHub Pages or release asset) | ENABLE — GitHub Pages | Pages is free, served at `mitgor.github.io/mdviewer/appcast.xml`, separates feed lifecycle from release assets. SKIP putting it inside the release assets — URL would change per release. |
| **Upload to GitHub Release** (`softprops/action-gh-release@v2`) | ENABLE | Industry standard, supports glob file lists, can auto-generate release notes. Use `generate_release_notes: true` for stock GitHub-style "what's changed". |
| **Draft release first, publish manually** | ENABLE | Safety net: CI creates draft → human reviews `.dmg` runs locally → flip to published. `softprops/action-gh-release` has `draft: true`. Critical for Sparkle — once appcast points to a release, every running install pulls it. |
| **Changelog generation from commits** | MAYBE — light touch | Two options: (a) `softprops/action-gh-release`'s `generate_release_notes: true` (uses GitHub PR titles, no config), or (b) Release Drafter (PR-label-driven, more setup). **Recommendation:** start with (a); revisit Release Drafter if release notes need categorization. SKIP conventional-commits parsers (commit history isn't strict enough). |
| **Release notes file (`.html` or `.md`) for Sparkle** | ENABLE | Generate from the GitHub release body. Sparkle 2.9+ accepts `.md`. One file per version, hosted alongside appcast.xml. |
| **Artifact retention** (workflow-uploaded build artifacts, `actions/upload-artifact`) | ENABLE | Retain `.dmg`, `.app.zip`, and notarization log for 30 days for postmortem. Don't conflate with release assets — those are permanent. |
| **dSYM upload** to a symbolication service | SKIP | We don't run a crash reporter (no Sentry, no Crashlytics). Apple ships crash reports in `~/Library/Logs/DiagnosticReports/` and the user can email them. Archive dSYMs as a build artifact (30-day retention) so we can manually symbolicate if needed. |
| **dSYM archive as build artifact** | ENABLE | `actions/upload-artifact` the `.xcarchive`'s `dSYMs/` folder. Cheap insurance. |
| **Build matrix Xcode versions** | SKIP | Single Xcode version (the runner default) is fine for a 1-developer app. Pin via `xcode-select` if reproducibility matters. |
| **Test job before release** (`xcodebuild test`) | ENABLE | Run `MDViewerTests` as a gate. If tests fail, no release. Uses same `macos-latest` runner. |
| **Lint / SwiftLint job** | SKIP | Project doesn't currently use SwiftLint. Adding it is a separate decision, not a release-pipeline concern. |
| **Slack / Discord webhook on release** | SKIP | No team to notify. |
| **Badge updates in README** (build status, latest version) | MAYBE | Build-status badge is automatic with GH Actions (`![status](url)`). Latest-version badge via shields.io's GitHub release endpoint is also free. ENABLE both — they're zero-maintenance. |
| **Auto-bump Homebrew cask** (after publish) | ENABLE | Separate step: `brew bump-cask-pr` from the workflow OR Homebrew's own livecheck picks up the new tag. See section 4. |
| **Tag protection / required reviews** | MAYBE | One-developer repo, low value. Reconsider if collaborators join. |
| **Concurrency control** (`concurrency: release-${{ ref }}`) | ENABLE | Prevents two simultaneous tag pushes from racing on the appcast file. One-line YAML. |
| **`secrets:` for Developer ID `.p12`, App Store Connect API key, EdDSA private key** | ENABLE | Encrypted GitHub Actions secrets. `.p12` base64-encoded. Document the rotation procedure. |
| **OIDC / hosted secrets manager** | SKIP | GitHub Actions secrets are sufficient at this scale. |

---

## 3. notarytool Features

`notarytool` (Xcode 13+) replaces deprecated `altool`. Subcommands: `submit`, `info`, `log`, `history`, `store-credentials`, `wait`.

| Feature | Recommendation | Why |
|---|---|---|
| **`submit --wait`** (one-shot upload + block until done) | ENABLE | Right call for CI — keeps the workflow step linear. Apple's median notarization is <5 min. |
| **`submit --timeout`** | ENABLE | Set ~30 min. Without it, a stuck submission blocks the entire job until GitHub kills it (6h default). |
| **`submit --output-format json`** | ENABLE | Parseable status + submission ID for downstream `log` calls. |
| **`submit --no-wait`** | SKIP | Async pattern only useful if you have other CI work to do in parallel — we don't. |
| **`submit --webhook`** (callback URL when done) | SKIP | Requires hosting a webhook endpoint; no infra and no value over `--wait`. |
| **`log` (fetch JSON log on failure)** | ENABLE | **Critical.** When notarization fails, the submit step's stderr says "Invalid" but doesn't say *why*. Always run `notarytool log <submissionId>` on non-zero exit and upload to artifacts. Saves hours. |
| **`info` (poll status)** | SKIP | Only needed with `--no-wait`. |
| **`history` (list past submissions)** | SKIP | Useful for debugging, but not in the hot path. Run manually when needed. |
| **`store-credentials` (Keychain profile)** | SKIP in CI | The Keychain profile is the right pattern on a developer laptop. CI uses `--key`/`--key-id`/`--issuer` flags directly with secrets. Document `store-credentials` for local-mac fallback. |
| **App Store Connect API key auth** (`-k` `-d` `-i`) | ENABLE | Strongly preferred over app-specific password. Per-key revocation, no Apple ID 2FA dance. Generate from App Store Connect → Users and Access → Keys. |
| **App-specific password auth** (`--apple-id` `--password` `--team-id`) | SKIP | Older pattern, ties auth to a personal Apple ID. Don't introduce. |
| **`--s3-acceleration`** | ENABLE default (it's on by default) | Faster uploads from CI runners far from Apple's notary endpoint. No reason to disable. |
| **Multiple submissions per build (resilience)** | SKIP | Don't pre-submit speculative builds. One submit per release tag. If it fails, fix and re-tag. |
| **Stapling after notarize (`xcrun stapler staple`)** | ENABLE | Already covered in section 2; included here because notarize-without-staple is a common bug. Always staple `.app` then re-build the `.dmg` containing the stapled `.app`, then staple the `.dmg`. |

**CI wiring sketch:**
```yaml
- name: Notarize
  id: notarize
  run: |
    set -e
    xcrun notarytool submit MDViewer.dmg \
      --key "$API_KEY_PATH" --key-id "$API_KEY_ID" --issuer "$API_ISSUER_ID" \
      --wait --timeout 30m --output-format json | tee notarize.json
    SUBMISSION_ID=$(jq -r '.id' notarize.json)
    echo "submission_id=$SUBMISSION_ID" >> "$GITHUB_OUTPUT"
- name: Fetch notarize log on failure
  if: failure()
  run: |
    xcrun notarytool log "${{ steps.notarize.outputs.submission_id }}" \
      --key "$API_KEY_PATH" --key-id "$API_KEY_ID" --issuer "$API_ISSUER_ID" \
      notarize-log.json
- uses: actions/upload-artifact@v4
  if: always()
  with: { name: notarize-log, path: notarize-log.json }
```

---

## 4. Homebrew Cask Features

Tap: `mitgor/homebrew-tap` (separate repo). Cask name: `mdviewer`.

| Feature | Recommendation | Why |
|---|---|---|
| **`version`** | ENABLE | Required. Derive from git tag (`v2.2.0` → `2.2.0`). |
| **`sha256`** | ENABLE | Required. Auto-computed by `brew bump-cask-pr` from the released `.dmg`. |
| **`url` with `verified:`** | ENABLE | Point to GitHub release asset: `https://github.com/mitgor/mdviewer/releases/download/v#{version}/MDViewer-#{version}.dmg`, `verified: "github.com/mitgor/mdviewer/"`. The `verified` key satisfies Homebrew's URL-trust audit. |
| **`name`, `desc`, `homepage`** | ENABLE | Required metadata. `desc` ≤ 80 chars, no period. |
| **`livecheck` with `strategy :github_latest`** | ENABLE | Watches the `releases/latest` API on GitHub; auto-detects new tag. The Homebrew autobump bot (or `brew bump-cask-pr` invoked by our workflow) opens a PR. |
| **`livecheck` with `strategy :sparkle`** | SKIP | `:github_latest` is more reliable for our case (single source of truth = git tag). `:sparkle` is the right strategy when there's no GitHub release but there is an appcast. We have both — GitHub release wins because it's where the .dmg lives. |
| **`livecheck` with `strategy :url`** | SKIP | Generic fallback; `:github_latest` is more specific. |
| **`auto_updates true`** | ENABLE | **Required when shipping with Sparkle.** Tells `brew upgrade` to skip MDViewer because the app updates itself. Without this, Sparkle and brew fight (see section 5). |
| **`depends_on macos: ">= :ventura"`** | ENABLE | Mirrors the app's deployment target (macOS 13). Prevents installs on older macOS. |
| **`app "MDViewer.app"`** | ENABLE | Required. Standard install location stanza. |
| **`uninstall delete:` / `quit:` / `signal:`** | MAYBE — `quit:` only | Default `app` stanza handles removal on `brew uninstall --cask`. Add `uninstall quit: "com.mdviewer.app"` so the app closes before removal. SKIP `delete:` (the `app` stanza already removes the bundle). |
| **`zap trash:`** | ENABLE | Clean uninstall on `brew uninstall --zap`. We persist: per-file window frames in `NSUserDefaults` (com.mdviewer.app.plist) and Sparkle's UserDefaults. Zap stanza:<br>`zap trash: ["~/Library/Preferences/com.mdviewer.app.plist", "~/Library/Saved Application State/com.mdviewer.app.savedState", "~/Library/Caches/com.mdviewer.app"]` |
| **`installer manual:`** | SKIP | Not applicable — we ship a `.dmg` containing a drag-installable `.app`, not a `.pkg` requiring user action. |
| **`pkg`** stanza | SKIP | We don't ship a `.pkg`. |
| **`postflight` / `uninstall_postflight`** | SKIP | No special install actions needed. |
| **`caveats`** | MAYBE | Use only if first-launch UX needs notes. Currently nothing to caveat — keep it clean. |

**Cask tap workflow:**
1. CI publishes a release.
2. Either (a) Homebrew's autobump bot picks up the new tag via `livecheck` and opens a PR to `mitgor/homebrew-tap`, OR (b) our workflow runs `brew bump-cask-pr --version <ver> --sha256 <sha> mitgor/tap/mdviewer` after release.
3. Human merges the PR (or autobump auto-merges if configured).

**Recommendation:** start with (a) — passive, zero CI maintenance. Add (b) if autobump latency (typically minutes-to-hours) is unacceptable.

---

## 5. Sparkle ↔ Homebrew Interaction

**The conflict (well-known):** Both Sparkle and `brew upgrade --cask` can update the app. If both are active and Sparkle wins, brew thinks the installed version is stale and re-installs the older `.dmg` on next `brew upgrade`. Result: app downgrades silently.

**The solution (official, settled):**

- The cask **must** declare `auto_updates true`.
- With `auto_updates true`, `brew upgrade` **never touches the app** unless the user passes `--greedy`.
- `brew upgrade --greedy` is opt-in per-user behavior; we don't need to defend against it (the user explicitly asked for it).
- `brew livecheck` will still detect new versions and open PRs to the tap, keeping the cask metadata in sync — but the user's installed bits are managed by Sparkle.

**Result:** Sparkle is the source of truth for *the bytes on disk*. Homebrew is the source of truth for *the cask metadata in the tap*. They don't fight as long as `auto_updates true` is set.

| Pattern | Recommendation | Why |
|---|---|---|
| **Sparkle owns updates, brew owns initial install + cask metadata** | ENABLE | Industry default. `auto_updates true` enforces it. |
| **Brew owns updates, Sparkle disabled for brew installs** | SKIP | Would require detecting brew-managed installs at runtime (e.g. `Bundle.main.bundleURL` under `/opt/homebrew/Caskroom`) and conditionally disabling Sparkle. Complex and surprising — users expect Sparkle when an app has it. |
| **Both update independently (no `auto_updates true`)** | SKIP — broken | Causes the silent-downgrade bug above. Don't ship without `auto_updates true`. |
| **Handshake (e.g. Sparkle delegate notifies brew of new install)** | SKIP | No supported API; would require a custom script the user installs. Out of scope. |

---

## 6. UAT / Verification Methodology

For a one-developer shop with a quick-preview app, full UAT process from enterprise checklists is overkill. The pattern that fits:

| Practice | Recommendation | Why |
|---|---|---|
| **UAT plan as markdown checklist in `.planning/`** | ENABLE | Each UAT scenario = one `.md` file under `.planning/uat/<scenario>.md` with: preconditions, steps, expected, actual, pass/fail box, notes. Lives next to the code. |
| **Numbered traceability** (each UAT case maps to a requirement) | ENABLE | UAT-2.2-01, UAT-2.2-02, etc. Cross-reference from VERIFICATION reports. Keeps the trail auditable. |
| **Pre-release UAT runbook** (one document, every release) | ENABLE | `RELEASE-CHECKLIST.md`: open 5 reference `.md` files (small, large, mermaid-heavy, table-heavy, edge-case), Cmd+P print, Cmd+E export, Cmd+M toggle, Cmd+O open dialog, drop a file on Dock icon, drop on already-running app. Should take ~5 minutes. |
| **Screenshot capture during UAT** | MAYBE | Manual screenshots stored in `.planning/uat/screenshots/<release>/`. Useful only if the diff matters — for a viewer, "does it look right" is hard to automate. Don't invest in screenshot diffing tools (`shot-scraper`, `playwright`) — overkill. |
| **Visual regression / pixel-diff tooling** | SKIP | The output is HTML rendered in WKWebView; pixel diffs would catch sub-pixel font rendering changes that aren't bugs. False-positive heavy. |
| **TestRail / Manifestly / commercial UAT tools** | SKIP | Markdown checklists in the repo cost zero and are searchable forever. |
| **Apple's TestFlight equivalent** | SKIP | Not in App Store. Use direct `.dmg` distribution to a small tester pool if needed (Sparkle beta channel). |
| **Recorded test session (screen-record)** | MAYBE | One QuickTime screen recording per release, archived in `.planning/uat/sessions/<release>.mov`. Useful for reproducing user-reported issues post-release. ENABLE for major releases, SKIP for patch releases. |
| **Crash log collection from testers** | SKIP | No tester pool. Document where to find crash logs (`~/Library/Logs/DiagnosticReports/MDViewer-*.crash`) in README so users can attach them to issues. |
| **"Smoke test" automation** (UI test for "open file → see content")** | MAYBE | XCUITest could open a fixture `.md` file and assert the WKWebView painted within 200ms. Adds CI test target. **Recommendation:** SKIP for v2.2 (UAT debt is the priority); revisit in v2.3 as part of perf-regression CI. |

**UAT scenarios for v2.2** (specific to the deferred items called out in PROJECT.md):

1. **UAT-2.2-01** — Pool replenishment under load: open 10 files in rapid succession, verify pool replenishes without UI hitch (Phase 7 deferred).
2. **UAT-2.2-02** — Streaming pipeline visual fidelity: open a 50MB markdown file, verify first-page paint < 200ms and remaining content streams in without flicker (Phase 8 deferred).
3. **UAT-2.2-03** — Sparkle update flow: install old build, point appcast at new build, trigger "Check for Updates", verify install + relaunch succeeds.
4. **UAT-2.2-04** — Brew install: `brew install --cask mitgor/tap/mdviewer`, verify .app launches, verify `brew upgrade` skips it (auto_updates true), verify `brew uninstall --zap` removes all artifacts.
5. **UAT-2.2-05** — Notarized .dmg trust: download CI-built .dmg, verify Gatekeeper accepts on first launch with no quarantine warning (stapled ticket worked).

---

## Recommended Feature Set Summary

**Enabled by default:**
- Sparkle: EdDSA, automatic checks (daily), standard UI, release notes, minimum-system-version gate, phased rollout (43200s)
- GitHub Actions: tag-triggered, universal binary, sign + notarize + staple, draft-then-publish, auto-generated GitHub release notes, dSYM as artifact, cask auto-bump
- notarytool: API-key auth, `--wait --timeout`, JSON output, log fetch on failure
- Homebrew: `auto_updates true`, `livecheck :github_latest`, full `zap` stanza, macOS 13+ requirement

**Deliberately skipped:**
- Sparkle: beta channels, delta updates, system profiling, custom UI, sandboxed XPC, JavaScript in release notes, informational updates, force-silent install
- GitHub Actions: arm64/x86_64 split matrix, dSYM upload service, Slack/Discord notify, conventional-commits parsing, Xcode matrix
- notarytool: webhook callbacks, async submit, app-specific password, history queries
- Homebrew: `:sparkle` livecheck (use `:github_latest`), `installer manual:`, `caveats`, `postflight`

**Maybe / re-evaluate post-v2.2:**
- Sparkle silent auto-install (`SUAllowsAutomaticUpdates`) — lean ENABLE
- `SURequireSignedFeed` — lean ENABLE
- Sparkle gentle reminders — defer to v2.3
- Smoke test XCUITest — defer to v2.3
- Release Drafter — only if PR-driven changelog categorization becomes valuable

---

## Anti-Features (explicitly NOT to build)

| Anti-Feature | Why Avoid | Do Instead |
|---|---|---|
| Preferences window for Sparkle settings | Violates "no preferences window" principle; Sparkle's defaults + first-update prompt are sufficient | Standard `SPUStandardUpdaterController` with daily-check default |
| In-app changelog viewer | Sparkle's release-notes sheet shows the changelog at update time; a separate viewer is redundant | Rely on Sparkle's release-notes display |
| Custom Sparkle UI / `SPUUserDriver` | We have no main window to dock the update UI into; standard sheet is correct | Standard driver |
| Telemetry / system profiling | Conflicts with privacy-first stance for a local viewer | `SUEnableSystemProfiling` = false |
| In-app "What's New" splash screen | Quick-preview tool — splash screens are hostile | Skip; Sparkle release notes cover the role |
| Multi-channel updates (beta/nightly) | No tester pool, no preferences UI to switch channels | Single stable channel |
| Auto-launch on macOS startup / menu bar resident | Quick-preview = ephemeral; persistence violates the model | Stay strictly document-launched |

---

## Sources

**Sparkle:**
- [Sparkle Project Documentation](https://sparkle-project.org/documentation/) (HIGH — official)
- [Customizing Sparkle (Info.plist keys)](https://sparkle-project.org/documentation/customization/) (HIGH — official)
- [Publishing an update (appcast.xml)](https://sparkle-project.org/documentation/publishing/) (HIGH — official)
- [Delta Updates](https://sparkle-project.org/documentation/delta-updates/) (HIGH — official)
- [SPUStandardUpdaterController API](https://sparkle-project.org/documentation/api-reference/Classes/SPUStandardUpdaterController.html) (HIGH — official API ref)
- [Gentle Update Reminders](https://sparkle-project.github.io/documentation/gentle-reminders/) (HIGH — official)
- [Sparkle GitHub repo (2.x branch)](https://github.com/sparkle-project/Sparkle/tree/2.x) (HIGH)
- [Code Signing and Notarization: Sparkle and Tears — Steinberger 2025](https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears) (MEDIUM — practitioner)

**GitHub Actions / CI:**
- [softprops/action-gh-release](https://github.com/softprops/action-gh-release) (HIGH — de facto standard)
- [Release Drafter Action](https://github.com/marketplace/actions/release-drafter) (HIGH)
- [Federico Terzi: macOS sign + notarize on Actions](https://federicoterzi.com/blog/automatic-code-signing-and-notarization-for-macos-apps-using-github-actions/) (MEDIUM — practitioner)
- [Automating Xcode Sparkle Releases with GitHub Actions](https://medium.com/@alex.pera/automating-xcode-sparkle-releases-with-github-actions-bd14f3ca92aa) (MEDIUM — practitioner)
- [GitHub Actions M1 macOS runners](https://github.com/orgs/community/discussions/69211) (HIGH)
- [macos-14 runner notes](https://github.com/actions/runner-images/issues/9741) (HIGH)

**notarytool:**
- [notarytool(1) man page](https://keith.github.io/xcode-man-pages/notarytool.1.html) (HIGH — Xcode docs mirror)
- [WWDC21 — Faster and simpler notarization](https://developer.apple.com/videos/play/wwdc2021/10261/) (HIGH — official)
- [WWDC22 — What's new in notarization](https://developer.apple.com/videos/play/wwdc2022/10109/) (HIGH — official)
- [scriptingosx: notarize CLI tool with notarytool](https://scriptingosx.com/2021/07/notarize-a-command-line-tool-with-notarytool/) (HIGH — practitioner authority)
- [Apple — Get Submission Log API](https://developer.apple.com/documentation/notaryapi/get-submission-log) (HIGH — official)

**Homebrew Cask:**
- [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook) (HIGH — official)
- [brew livecheck](https://docs.brew.sh/Brew-Livecheck) (HIGH — official)
- [Casks with Sparkle livecheck and no `auto_updates true` (issue #170994)](https://github.com/Homebrew/homebrew-cask/issues/170994) (HIGH — current discussion)
- [Self-updating apps thread](https://discourse.brew.sh/t/installing-casks-for-self-updating-apps/6292) (MEDIUM)
- [What happens with auto updating casks (Discussion #3359)](https://github.com/orgs/Homebrew/discussions/3359) (HIGH)

**UAT:**
- [TestRail — UAT checklist](https://www.testrail.com/blog/user-acceptance-testing/) (MEDIUM — vendor blog)
- [BrowserStack — UAT template](https://www.browserstack.com/guide/user-acceptance-testing-template) (MEDIUM)
- [coaxsoft — Agile UAT checklist](https://coaxsoft.com/blog/how-to-conduct-user-acceptance-testing) (MEDIUM)
