# Phase 12: Sparkle Auto-Update Integration — Research

**Researched:** 2026-04-20
**Domain:** Sparkle 2.x auto-update integration for macOS AppKit app (first-time integration)
**Confidence:** HIGH on Sparkle mechanics and CI wiring (verified against current Sparkle 2.9.1 docs and MDViewer's Phase 11 pipeline); MEDIUM on appcast XML schema exactness (Sparkle docs don't publish a complete schema — examples come from multiple community sources that agree); LOW-to-MEDIUM on a few edge cases flagged inline.

---

## Summary

MDViewer's Phase 12 adds Sparkle 2.9.1+ as the app's first SPM dependency, wires a "Check for Updates…" menu item to `SPUStandardUpdaterController`, and extends the Phase 11 `release.yml` with an appcast-generation step. The bulk of "what could go wrong" is already documented in `.planning/research/v2.2/PITFALLS.md` (26 pitfalls; ~10 are Sparkle-specific) — this research does not re-enumerate those; it answers the 15 planning-actionable questions the roadmap raised on top of them. **Three findings invalidate prior assumptions and need the planner to adjust:** (1) the Info.plist already has `CFBundleVersion=2.1` — not `1.0` as the phase context states — which changes the migration math but not the direction; (2) the repo has NO `Package.swift` and NO `Package.resolved` (cmark-gfm is fully vendored under `Vendor/cmark-gfm/`), so Sparkle will be the project's first SPM dep and must be added to the **Xcode project** directly, not to a non-existent `Package.swift`; (3) Sparkle's binary tools live at a DerivedData path that varies per-run on GitHub-hosted runners, so the CI script must **discover** the path, not hardcode it.

**Primary recommendation:** Split Phase 12 into **3 plans** along file-isolation boundaries — (1) app integration (SPM + Info.plist + AppDelegate), (2) CI appcast pipeline (generate_appcast step + Scripts/generate_appcast.sh + Scripts/verify_bundle.sh), (3) pre-release gates + docs (key backup procedure + README notice + CFBundleVersion migration). Plans 1 and 2 can parallelize after SPM resolution is confirmed; Plan 3 gates the first shipping release.

---

## Phase Requirements

| ID | Description (from REQUIREMENTS.md) | Research Support |
|----|-------------|------------------|
| SPK-01 | Sparkle 2.9.1+ added as SPM dep via `upToNextMajor(from: "2.9.1")` | §2 — add via Xcode "Add Package Dependencies…" UI; repo has no Package.swift to edit. SPM binary target (XCFramework) ships prebuilt. |
| SPK-02 | EdDSA keys generated via `generate_keys`; private in GitHub secret + offline backup; public in Info.plist | §5 — `generate_keys` stores private in login keychain and prints public to stdout; `generate_keys -x <path>` exports private to a file as a single-line base64 ed25519 key |
| SPK-03 | `Info.plist SUFeedURL = https://github.com/mitgor/mdviewer/releases/latest/download/appcast.xml` | §3 — required key, must be HTTPS (Pitfall #6), GitHub's `/releases/latest/download/` is a stable HTTPS redirect |
| SPK-04 | `SUEnableAutomaticChecks=true`, `SUScheduledCheckInterval=86400` | §3 — both documented keys; 86400 is Sparkle's default; setting it explicitly is idiomatic |
| SPK-05 | "Check for Updates…" menu item wired via `SPUStandardUpdaterController` | §9 — instantiate as AppDelegate property; wire selector `#selector(SPUStandardUpdaterController.checkForUpdates(_:))` |
| SPK-06 | `generate_appcast` in CI, key materialized from `SPARKLE_ED_PRIVATE_KEY` into tmpfs, never to runner disk | §6 — use `--ed-key-file -` with stdin (preferred) or `$RUNNER_TEMP`-backed file with `trap` cleanup |
| SPK-07 | `phasedRolloutInterval=43200` (12h) in appcast | §7 — per-item `<sparkle:phasedRolloutInterval>43200</sparkle:phasedRolloutInterval>`; Sparkle hardcodes 7 groups |
| SPK-08 | `CFBundleVersion` migrated from string to monotonic integer BEFORE first Sparkle ship | §8 — **BLOCKING** decision; current value is `"2.1"` not `"1.0"`; recommend switching to `CFBundleVersion=22` (matching ShortVersionString 2.2 at build 0) |
| SPK-09 | `minimumSystemVersion=13.0` in appcast | §11 — set `<sparkle:minimumSystemVersion>13.0.0</sparkle:minimumSystemVersion>` (three parts — Sparkle parses 1–3 components but three is the documented convention) |
| SPK-10 | `verify_bundle.sh` smoke test: exactly one `Sparkle.framework` in app | §4 — check `find MDViewer.app -name 'Sparkle.framework' -type d \| wc -l` = 1; also verify `Contents/Frameworks/Sparkle.framework` path + team ID match |
| SPK-11 | README one-time manual-update notice for v2.1 users | §14 — short block near top of README (covered in Pitfall #9) |
| SPK-12 | Release notes per version fetchable as markdown from stable URL referenced by appcast | §7 — `<sparkle:releaseNotesLink>` per item; use GitHub's Release body rendered as HTML at `https://github.com/.../releases/tag/vX.Y.Z` or a stable raw URL |

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Check for Updates menu action | AppKit (`AppDelegate.swift`) | Sparkle framework | Menu item lives in `NSApp.mainMenu`; selector resolves to `SPUStandardUpdaterController.checkForUpdates(_:)` held by AppDelegate |
| Scheduled update check | Sparkle framework | Info.plist (config source) | Framework owns the timer, UI, and download pipeline; Info.plist keys are declarative defaults |
| EdDSA verification | Sparkle framework | — | Framework verifies signature against `SUPublicEDKey` during download acceptance |
| Appcast generation | CI (`.github/workflows/release.yml`) | `Scripts/generate_appcast.sh` + Sparkle's `generate_appcast` CLI | Generated fresh per release tag; never lives in the repo; uploaded as a release asset |
| EdDSA private key custody | GitHub Secrets (primary) | Offline backup (disaster recovery) | No runtime custody — the app never sees the private key |
| Bundle layout verification | CI (`Scripts/verify_bundle.sh`) | — | Post-sign, pre-notarize; guards against regressions of SPM double-framework issue |
| CFBundleVersion stamping | CI (`Scripts/set_version.sh`) | `MDViewer/Info.plist` (template) | Plist is the template; CI overwrites at build time from the git tag |

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Sparkle | **2.9.1** (pin `.upToNextMajor(from: "2.9.1")`) | macOS auto-update framework with EdDSA-signed appcasts and XPC-isolated installer | De facto standard for non-App-Store macOS apps; only framework that handles notarization-friendly update flow with sandboxed XPC services and Ed25519 signatures [VERIFIED: https://github.com/sparkle-project/Sparkle/releases] |

**Installation (MDViewer-specific):**
MDViewer has no `Package.swift`, no `Package.resolved`, and no existing SPM dependencies — cmark-gfm is vendored under `Vendor/cmark-gfm/`. Sparkle will be the **first** SPM dependency and must be added via Xcode's package UI (File → Add Package Dependencies…) or by editing `project.pbxproj` to declare an `XCRemoteSwiftPackageReference`. [VERIFIED: grep of project.pbxproj — no matches for `XCRemoteSwiftPackageReference`, `Sparkle`, `swift-cmark`]

XcodeGen's `project.yml` does support package dependencies via a top-level `packages:` block and per-target `dependencies: - package: Sparkle` form. The planner should add both:

```yaml
# project.yml addition
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: "2.9.1"

targets:
  MDViewer:
    dependencies:
      - target: cmark-gfm
      - target: cmark-gfm-extensions
      - package: Sparkle
```

After regenerating via `xcodegen generate`, commit both `project.pbxproj` AND the new `MDViewer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` so CI's SPM cache can key off it. [CITED: https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md]

### Supporting

None. Sparkle's binary tools (`generate_keys`, `generate_appcast`, `sign_update`) ship inside the resolved SPM artifact and are the only helpers needed. No additional Ruby/Python/Node toolchain required.

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Sparkle | DevMate / custom updater | DevMate is sunset; rolling a custom updater means re-implementing Ed25519 verification, XPC privilege separation, and Gatekeeper-compatible install — out of scope |
| SPM binary target | Carthage, manual framework drop-in | Sparkle ships and recommends SPM binary target since 2.x; mixing distribution methods adds risk for no benefit |
| SPM binary target | SPM source build | Sparkle's maintainers explicitly distribute as XCFramework binary target because building from source requires non-trivial dev tool chain (Sparkle includes Objective-C++, C, Swift, a set of XPC services and a separate Updater.app). Binary target avoids this. [CITED: https://github.com/sparkle-project/Sparkle/pull/1634] |

**Version verification:** `npm view`-style check not applicable (Sparkle is not on npm). Verified against GitHub releases page as of 2026-04-20:
- 2.9.1 (2026-03-29) — current stable
- 2.9.0 (2026-02-22) — major appcast/markdown improvements
- 2.8.1 (2024-11-15) — UI refinements
- 2.8.0 (2024-09-16) — UI modernization for macOS Tahoe

No Sparkle 3.x release exists or is announced as of research date. No open security advisories against 2.9.x. macOS 15/26 compatibility is tracked by Sparkle (changelog 2.9.1: "Add Xcode 26.4 beta compiler warnings"; 2.8.0: "Update retrieving app icon to work better in Tahoe"). [CITED: https://github.com/sparkle-project/Sparkle/blob/2.x/CHANGELOG]

---

## Runtime State Inventory

> Phase 12 is additive — no rename / refactor — but there IS runtime state the planner must treat explicitly.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | Sparkle user defaults keys under `com.mdviewer.app` domain (`SUAutomaticallyUpdate`, `SULastCheckTime`, etc.) — created at runtime after first Sparkle launch | **None** for first release; `brew uninstall --zap` cask must include `~/Library/Preferences/com.mdviewer.app.plist` (already planned in Phase 13 BREW-05) |
| Live service config | `SUFeedURL` points to a GitHub-served URL; no third-party service state | None — feed URL is static; GitHub Releases surface is the config |
| OS-registered state | None — Sparkle does not register LaunchAgents or system daemons in the unsandboxed/non-XPC-autoupdate flow | None |
| Secrets/env vars | `SPARKLE_ED_PRIVATE_KEY` documented in `docs/release/ci-secrets.md` (Phase 11 plan 11-02, lines 377–455); backup location is a `_DOCUMENT HERE WHEN BACKUP IS CREATED_` placeholder | **Plan 3 gate:** operator fills in backup locations in that file BEFORE first `v2.2.0` tag |
| Build artifacts | `MDViewer.app/Contents/Frameworks/Sparkle.framework` — new framework; `MDViewer.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/` — Installer.xpc, Downloader.xpc | Verify bundle layout post-sign (Plan 2 `verify_bundle.sh`) |

---

## User Constraints (from CONTEXT.md)

No CONTEXT.md exists for Phase 12 (this research runs standalone under `/gsd:execute-phase` workflow with `skip_discuss: false`). Upstream constraints come from:

- **REQUIREMENTS.md** — 12 SPK-* requirement IDs, verbatim above
- **ROADMAP.md Phase 12** — 6 success criteria including 3 "pre-release gates"
- **CLAUDE.md** — "No network: all resources bundled" constraint. **This research confirms compatibility:** Sparkle only makes network calls on the update check / download path, to the developer-specified `SUFeedURL` and the enclosure URLs the feed advertises. Sparkle sends NO telemetry to sparkle-project.org. System profiling is opt-in (`SUEnableSystemProfiling`, which MDViewer will leave at default `NO`). [VERIFIED: https://sparkle-project.org/documentation/system-profiling/]

---

## Architecture Patterns

### System Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│  MDViewer.app (user machine)                                          │
│                                                                       │
│   AppDelegate.swift                                                   │
│     └── updaterController: SPUStandardUpdaterController               │
│           │                                                           │
│           ├── Auto: on schedule (every 86400s) ──┐                    │
│           └── Manual: Check for Updates menu ────┤                    │
│                                                  ▼                    │
│   Sparkle.framework                                                   │
│     ├── SPUUpdater     (owns timer + UI flow)                         │
│     ├── Downloader.xpc (network I/O isolated)                         │
│     └── Installer.xpc  (privileged install isolated)                  │
│                         │                                             │
└─────────────────────────┼─────────────────────────────────────────────┘
                          │ HTTPS (only network activity in app)
                          ▼
          https://github.com/mitgor/mdviewer/releases/latest/
                  download/appcast.xml
                          │
                          ▼ parse XML → verify <sparkle:edSignature> with SUPublicEDKey
                          │
         ┌────────────────┴─────────────────────────┐
         │ Channel 1: stable (default)              │
         │   <item>                                 │
         │     <sparkle:version>22</sparkle:version>│
         │     <enclosure url="…/MDViewer-2.2.0.dmg"│
         │       sparkle:edSignature="…" length="…" │
         │     />                                   │
         │   </item>                                │
         └────────────────┬─────────────────────────┘
                          ▼
         https://github.com/mitgor/mdviewer/releases/download/
                 v2.2.0/MDViewer-2.2.0.dmg
                 (notarized + stapled DMG from Phase 11)
                          │
         Sparkle verifies Ed25519 signature, mounts DMG,
         replaces /Applications/MDViewer.app via Installer.xpc

┌──────────────────────────────────────────────────────────────────────┐
│  GitHub Actions (.github/workflows/release.yml)                       │
│                                                                       │
│   Tag push (v*)                                                       │
│     ├── build + sign + notarize + staple (Phase 11 — unchanged)       │
│     │                                                                 │
│     ├── NEW: Scripts/verify_bundle.sh                 (SPK-10)        │
│     │    └── exactly one Sparkle.framework            (Plan 2)        │
│     │                                                                 │
│     ├── NEW: Scripts/generate_appcast.sh              (SPK-06,07,09)  │
│     │    ├── materialize $SPARKLE_ED_PRIVATE_KEY → tmpfs              │
│     │    ├── locate generate_appcast in SourcePackages/artifacts      │
│     │    ├── run generate_appcast with --ed-key-file -                │
│     │    └── post-process XML: add phasedRolloutInterval + notes link │
│     │                                                                 │
│     └── softprops/action-gh-release                                   │
│          └── upload build/appcast.xml as a release asset              │
│             alongside the DMG (so GitHub's                             │
│             /releases/latest/download/appcast.xml resolves)            │
└──────────────────────────────────────────────────────────────────────┘
```

### Recommended Project Structure (only new/changed paths)

```
MDViewer/
├── AppDelegate.swift                 # + updaterController property (Plan 1)
├── Info.plist                        # + SUFeedURL, SUPublicEDKey, etc. (Plan 1)
└── Resources/                        # unchanged

project.yml                           # + Sparkle package dep (Plan 1)
MDViewer.xcodeproj/project.pbxproj    # regenerated; commits SPM wire-up (Plan 1)
MDViewer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved   # NEW — commit (Plan 1)

.github/workflows/release.yml         # + verify + appcast steps (Plan 2)
Scripts/generate_appcast.sh           # NEW (Plan 2)
Scripts/verify_bundle.sh              # NEW (Plan 2)
Scripts/set_version.sh                # MAYBE touched if CFBundleVersion scheme changes (Plan 3)

docs/release/ci-secrets.md            # extend SPARKLE_ED_PRIVATE_KEY section (Plan 3)
docs/release/sparkle-setup.md         # NEW — operator runbook for key generation + Info.plist wiring (Plan 3)
README.md                             # + one-time manual-update notice for v2.1 users (Plan 3)
```

### Pattern 1: `SPUStandardUpdaterController` as AppDelegate property

**What:** Sparkle's turnkey controller. Owns an `SPUUpdater` internally, wires it to a standard-UI user driver, and exposes `checkForUpdates(_:)` as an `@IBAction` the menu item can target.
**When to use:** Default choice for any app without a custom preferences UI. Matches REQUIREMENTS constraint "No Preferences window — no settings to persist."

**Example:**

```swift
// Source: https://sparkle-project.org/documentation/api-reference/Classes/SPUStandardUpdaterController.html
// Add to AppDelegate.swift

import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, … {
    // Instantiate at property level so the updater starts immediately after launch.
    // Delegates are both nil — the standard UI covers our needs; no custom checks.
    // CRITICAL: hold as a property so the updater isn't deallocated.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    …
}

// In setupMenu() under the app menu submenu, BEFORE the separator before Quit:
appMenu.addItem(withTitle: "About MDViewer",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: "")

let checkItem = NSMenuItem(
    title: "Check for Updates…",
    action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
    keyEquivalent: "")
checkItem.target = updaterController   // selector lives on the controller, not AppDelegate
appMenu.addItem(checkItem)

appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Quit MDViewer",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q")
```

Note: The Mozilla bugzilla reference shows "Check for Updates" under the app menu IS the current convention for most macOS apps that ship with their own updater (Firefox, Office). Apple's HIG doesn't mandate a location; putting it under the app menu (second item, after About) is idiomatic for Sparkle-powered apps. [CITED: https://bugzilla.mozilla.org/show_bug.cgi?id=1691433]

### Pattern 2: CI-side appcast generation — script, don't inline

**What:** Wrap the `generate_appcast` invocation in `Scripts/generate_appcast.sh` so the logic (key materialization, path discovery, post-processing) is testable and not buried in YAML.
**When to use:** Matches the Phase 11 pattern (build_and_sign.sh, notarize.sh, etc.) — CI calls the script, script handles the complexity.

**Example:**

```bash
#!/usr/bin/env bash
# Scripts/generate_appcast.sh
# Usage: generate_appcast.sh <version> <dmg-path>
# Reads SPARKLE_ED_PRIVATE_KEY from env (base64 of the exported single-line key).
# Produces build/appcast.xml with EdDSA signatures.
set -euo pipefail

VERSION="${1:?version required}"
DMG_PATH="${2:?dmg path required}"

: "${SPARKLE_ED_PRIVATE_KEY:?must be set}"
[ -f "$DMG_PATH" ] || { echo "::error::$DMG_PATH not found"; exit 1; }

# 1) Locate generate_appcast inside the SPM-resolved artifact.
# The DerivedData path varies per-build on hosted runners; discover it.
# Sparkle 2 SPM binary target places it under SourcePackages/artifacts/sparkle/Sparkle/bin/
GENERATE_APPCAST=$(find ~/Library/Developer/Xcode/DerivedData \
    -type f -name generate_appcast \
    -path '*SourcePackages/artifacts/sparkle/Sparkle/bin/*' 2>/dev/null | head -n1)

if [ -z "$GENERATE_APPCAST" ]; then
  echo "::error::generate_appcast not found. Has Sparkle SPM been resolved? Run 'xcodebuild -resolvePackageDependencies' first."
  exit 1
fi
chmod +x "$GENERATE_APPCAST"

# 2) Stage the DMG in a folder (generate_appcast scans a directory).
STAGING="$RUNNER_TEMP/appcast-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp "$DMG_PATH" "$STAGING/"

# 3) Invoke generate_appcast, streaming the private key via stdin (Pitfall #14).
# --ed-key-file - reads from stdin; nothing touches the runner filesystem.
# --link: human-readable landing page for this release
# --download-url-prefix: where Sparkle should download DMGs from
# -o: output path
echo "$SPARKLE_ED_PRIVATE_KEY" \
  | "$GENERATE_APPCAST" \
      --ed-key-file - \
      --link "https://github.com/mitgor/mdviewer/releases/tag/v${VERSION}" \
      --download-url-prefix "https://github.com/mitgor/mdviewer/releases/download/v${VERSION}/" \
      -o "$RUNNER_TEMP/appcast.xml" \
      "$STAGING"

# 4) Post-process: inject <sparkle:phasedRolloutInterval> and a release-notes link.
# generate_appcast doesn't set phasedRolloutInterval from any flag; it has to be added.
# Using python (preinstalled on macos-26 runner) or xmlstarlet; python is more portable.
python3 - <<'PY' "$RUNNER_TEMP/appcast.xml" "$VERSION"
import sys, xml.etree.ElementTree as ET
path, version = sys.argv[1], sys.argv[2]
ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
ET.register_namespace('sparkle', ns['sparkle'])
tree = ET.parse(path)
root = tree.getroot()
for item in root.iter('item'):
    # phasedRolloutInterval = 43200s (12h * 7 groups = 84h full rollout)
    pri = ET.SubElement(item, '{%s}phasedRolloutInterval' % ns['sparkle'])
    pri.text = '43200'
    # per-version release notes — point at the GitHub Release HTML page
    notes = ET.SubElement(item, '{%s}releaseNotesLink' % ns['sparkle'])
    notes.text = f'https://github.com/mitgor/mdviewer/releases/tag/v{version}'
    # minimumSystemVersion — three-part form is the documented convention
    msv = ET.SubElement(item, '{%s}minimumSystemVersion' % ns['sparkle'])
    msv.text = '13.0.0'
tree.write(path, xml_declaration=True, encoding='utf-8')
PY

# 5) Copy to the build/ directory so release.yml can attach it.
cp "$RUNNER_TEMP/appcast.xml" build/appcast.xml

# 6) Sanity-check: the output has at least one <sparkle:edSignature>.
grep -q 'sparkle:edSignature' build/appcast.xml \
  || { echo "::error::appcast.xml missing EdDSA signature — key didn't work"; exit 1; }

echo "Generated build/appcast.xml for v${VERSION}"
```

### Anti-Patterns to Avoid

- **Do not** hand-write the appcast XML in the workflow YAML (as the rampatra gist does). Sparkle's `generate_appcast` handles DMG size measurement, enclosure SHA, and EdDSA signature in one pass; skipping it means re-implementing all three and introducing drift.
- **Do not** hardcode the generate_appcast path. SPM's DerivedData directory name contains a random hash that changes per-build on hosted runners. Always `find` it by name.
- **Do not** use `sign_update` separately from `generate_appcast` unless you're also hand-writing the XML. `generate_appcast` invokes `sign_update` internally and produces the full `<enclosure sparkle:edSignature="…">` attribute. [CITED: https://github.com/sparkle-project/Sparkle/pull/2615 — stdin pattern preferred in CI]
- **Do not** put SUPublicEDKey in a shared secret file at build time. The public key is not a secret — commit it into `MDViewer/Info.plist` in source. Sparkle's threat model treats the public key as a constant the installed app carries.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Ed25519 signature verification | Custom Security.framework wrapper | Sparkle framework | Constant-time comparison, key format parsing, and appcast parsing are load-bearing; one-off implementations have led to real CVEs (see historical DSA-downgrade attacks on pre-Sparkle-1.26.0 apps) |
| Background update check scheduler | NSBackgroundActivityScheduler + NSURLSession logic | `SPUStandardUpdaterController` | Sparkle handles wake-from-sleep backoff, rate limiting, and first-run user-consent prompt already |
| Privileged install step | `AuthorizationExecuteWithPrivileges` + rename/replace logic | Sparkle's Installer.xpc | Service has hardened runtime + per-team-ID XPC hardening (Pitfall #15); custom code would reintroduce every CVE Sparkle has patched |
| Appcast XML generation | Hand-written XML in Bash heredoc | `generate_appcast` + post-process | Handles DMG byte length, SHA, Ed25519 signature, encoded DMG filename, and XML escaping in one pass |
| DMG bundling verification | Manual check or skipping the step | `verify_bundle.sh` (write ourselves — see Plan 2) + `codesign -dvvv` chain | Phase 11 pattern: small shell scripts that fail loudly in CI are the contract |

**Key insight:** Sparkle exists because every attempt to "just write a small updater" has produced a CVE. The framework's complexity is earned complexity.

---

## Common Pitfalls

See `.planning/research/v2.2/PITFALLS.md` for the full 26-item catalog — especially #2 (EdDSA key loss), #3 (`--deep` flag), #6 (HTTP appcast refused), #9 (v2.1 users can't auto-upgrade), #10 (Homebrew fighting Sparkle), #14 (generate_appcast keychain prompt), #15 (XPC team ID hardening), and #19 (CFBundleVersion string comparison). Those are NOT repeated here.

### New pitfalls discovered during this research

### Pitfall A: `generate_appcast` path lives in DerivedData — hash changes per build

**What goes wrong:** Hardcoding `./build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast` works on the developer Mac but breaks in CI because DerivedData path includes a hash (`MDViewer-dnleqmiieejruiawzcazrtmcdsmz/`) that changes per-build.
**Why it happens:** SPM stores binary target artifacts under DerivedData by default. The hash is derived from the project path + build settings.
**How to avoid:** Use `find ~/Library/Developer/Xcode/DerivedData -name generate_appcast -path '*SourcePackages/artifacts/sparkle/*' | head -n1` and fail-loud if it returns empty. Alternative: pass `-derivedDataPath build/DerivedData` to every `xcodebuild` invocation to pin a predictable location.
**Warning signs:** "No such file or directory" in the appcast step; passing locally but failing in CI.
**Source:** [VERIFIED: https://swiftdevjournal.com/accessing-the-sparkle-binary-from-its-swift-package/]

### Pitfall B: The private key format is a SINGLE LINE of base64 — newline introduction breaks it

**What goes wrong:** Copy-pasting the exported key via a terminal that wraps long lines, or via GitHub's secrets UI that may or may not preserve bytes verbatim, can introduce a `\n` mid-key. `sign_update` returns a cryptic signature-failure.
**Why it happens:** Sparkle's key file format per VibeTunnel docs: "Private key file must contain ONLY the base64 key. No comments, headers, or extra whitespace. Single line of base64 data."
**How to avoid:** When storing in GitHub Secrets, paste the entire exported file content WITHOUT a trailing newline. The Phase 11 secrets doc already recommends `pbcopy` from the exported file, which preserves bytes. When restoring in CI, write to `$RUNNER_TEMP` via `printf '%s' "$SPARKLE_ED_PRIVATE_KEY"` (not `echo` — `echo` appends a newline on some shells). Alternatively use stdin to `generate_appcast --ed-key-file -` to avoid the intermediate file entirely.
**Warning signs:** `sign_update` prints a short error; appcast XML is generated but `sparkle:edSignature=""` is empty.
**Source:** [VERIFIED: https://docs.vibetunnel.sh/mac/docs/sparkle-keys]

### Pitfall C: Release notes URL must serve HTML (or plain text), not markdown

**What goes wrong:** Pointing `<sparkle:releaseNotesLink>` at a `.md` file. Sparkle loads the link into a WKWebView for display; markdown renders as plain text.
**Why it happens:** Sparkle 2 added Markdown support in 2.9.0 only for certain forms (e.g., release notes fetched as the raw feed body under specific conditions), but the linked-URL form expects HTML.
**How to avoid:** Either point at a stable HTML URL (GitHub's `/releases/tag/vX.Y.Z` page renders the Release body as HTML — good default) OR use an embedded `<description><![CDATA[<h2>…</h2>]]></description>` inside the `<item>` with hand-rendered HTML.
**Warning signs:** "Check for Updates" dialog shows raw asterisks and backticks instead of formatted text.
**Source:** [CITED: Sparkle changelog 2.9.0 "Major appcast enhancements"; ASSUMED downstream for the markdown-via-link case — confirm before first release]

### Pitfall D: `SUScheduledCheckInterval` has a minimum of 3600 — 86400 is safe but documented

**What goes wrong:** Setting a value below 3600 is silently clamped by Sparkle to 3600.
**Why it happens:** Documented behavior in `SPUUpdater`: "SUScheduledCheckInterval has a minimum bound of 3600 seconds (or 1 hour)."
**How to avoid:** 86400 (24h) per SPK-04 is well above the floor. Document this limit in `docs/release/sparkle-setup.md`.
**Source:** [VERIFIED: https://sparkle-project.org/documentation/customization/]

### Pitfall E: CFBundleVersion migration — current value is "2.1", not "1.0" as phase context assumed

**What goes wrong:** Phase context and ROADMAP.md state CFBundleVersion needs migrating from `"1.0"` string. **The actual current value in `MDViewer/Info.plist` is `"2.1"`** (both CFBundleVersion and CFBundleShortVersionString). The migration math is the same (`"2.1"` is still a dotted string that Sparkle would compare lexicographically) but the planner must update the migration task description to match reality.
**Why it happens:** `Scripts/set_version.sh` currently sets BOTH values to the same thing from the git tag, and recent v2.1.0 release stamped `"2.1"`.
**How to avoid:** Update `set_version.sh` so that CFBundleVersion becomes an integer (e.g., derived from `git rev-list --count HEAD` for a monotonic count, OR computed from `CFBundleShortVersionString.replace('.', '')` — `2.2.0` → `220`), while CFBundleShortVersionString stays `"2.2.0"`. Pitfall #19 in PITFALLS.md recommends the `"22000"` scheme; Hammerspoon's canonical migration (issue #2187) uses `git rev-list --count` for monotonic guaranteed. **Irreversible once the first Sparkle release ships — whatever integer v2.2.0 gets must stay less than whatever v2.3.0 gets.**
**Recommendation:** Use `CFBundleVersion=220` (derived from `2.2.0` → strip dots). Simple, human-readable, and monotonic as long as future versions increment the human version. For dotted versions like `2.2.1`, strip dots → `221`. For `2.10.0`, strip dots → `2100` > `290`, which preserves the comparison.
**Source:** [VERIFIED: file read MDViewer/Info.plist line 10]

---

## Code Examples

### SUPublicEDKey format in Info.plist

```xml
<!-- Verified format via: https://github.com/sparkle-project/Sparkle/discussions/2347 -->
<!-- 44 characters base64 = 32 bytes Ed25519 public key -->
<key>SUPublicEDKey</key>
<string>cwzHFjcbP+WBG9+CxCnVWUxPgH/zqJnLYNaFTtlEVNg=</string>
```

### Generating keys (first-time, once per project-lifetime)

```bash
# Source: https://sparkle-project.org/documentation/publishing/
# and https://docs.vibetunnel.sh/mac/docs/sparkle-keys

# 1) Resolve Sparkle so the binaries exist on disk.
#    (Open MDViewer.xcodeproj once after adding Sparkle as a dep, OR:)
xcodebuild -resolvePackageDependencies -project MDViewer.xcodeproj -scheme MDViewer

# 2) Locate generate_keys.
GEN_KEYS=$(find ~/Library/Developer/Xcode/DerivedData \
    -name generate_keys -path '*SourcePackages/artifacts/sparkle/Sparkle/bin/*' | head -n1)

# 3) Generate the keypair. Private goes into login keychain, public prints to stdout.
"$GEN_KEYS"
# ...(interactive prompts; stores private in Keychain Access under "Private key for signing Sparkle updates")
# Prints: "In Info.plist, set SUPublicEDKey to: cwzHFjcbP+WBG9+CxCnVWUxPgH/zqJnLYNaFTtlEVNg="

# 4) Export the private key for CI + offline backup.
"$GEN_KEYS" -x sparkle_ed_priv.key
cat sparkle_ed_priv.key     # one line, base64
# Upload to TWO offline locations (see ci-secrets.md).
# base64-encode for GitHub Secrets to survive UI paste:
base64 -i sparkle_ed_priv.key | pbcopy   # paste into SPARKLE_ED_PRIVATE_KEY

# 5) Delete local plaintext key file.
rm sparkle_ed_priv.key
```

### Minimal valid appcast item (what generate_appcast produces + our post-processing)

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>MDViewer</title>
    <link>https://github.com/mitgor/mdviewer</link>
    <item>
      <title>Version 2.2.0</title>
      <pubDate>Sat, 20 Apr 2026 12:00:00 +0000</pubDate>

      <!-- CFBundleVersion-equivalent — Sparkle's primary comparator -->
      <sparkle:version>220</sparkle:version>
      <!-- CFBundleShortVersionString — shown in UI -->
      <sparkle:shortVersionString>2.2.0</sparkle:shortVersionString>

      <sparkle:minimumSystemVersion>13.0.0</sparkle:minimumSystemVersion>

      <!-- Phased rollout: 43200s (12h) per group, 7 groups, ~84h to reach 100% -->
      <sparkle:phasedRolloutInterval>43200</sparkle:phasedRolloutInterval>

      <!-- Release notes HTML — GitHub's release-tag page renders the markdown body -->
      <sparkle:releaseNotesLink>https://github.com/mitgor/mdviewer/releases/tag/v2.2.0</sparkle:releaseNotesLink>

      <!-- Generated entirely by generate_appcast — do NOT hand-compute length or signature -->
      <enclosure
        url="https://github.com/mitgor/mdviewer/releases/download/v2.2.0/MDViewer-2.2.0.dmg"
        sparkle:edSignature="MEQCIA...(Ed25519 sig)..."
        length="2847392"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
```

### Info.plist additions (Plan 1 — what gets added)

```xml
<!-- The public key is safe to commit. 44 chars base64 = 32-byte Ed25519 key. -->
<key>SUPublicEDKey</key>
<string>PLACEHOLDER_REPLACED_BY_OPERATOR_AT_PHASE_12_LAUNCH</string>

<!-- HTTPS required (Pitfall #6). GitHub's /releases/latest/download/ stably redirects to the latest published release. -->
<key>SUFeedURL</key>
<string>https://github.com/mitgor/mdviewer/releases/latest/download/appcast.xml</string>

<!-- Enables automatic background checks without prompting the user on 2nd launch. -->
<key>SUEnableAutomaticChecks</key>
<true/>

<!-- 86400s = 24h. Minimum is 3600; this is well above. -->
<key>SUScheduledCheckInterval</key>
<integer>86400</integer>

<!-- Explicitly OFF. MDViewer's privacy posture = ship as little as possible. -->
<key>SUEnableSystemProfiling</key>
<false/>
```

Note: `SUAllowsAutomaticUpdates` is NOT set — defaults to "enabled if auto-checks are on," which matches intent (user can still opt out via the standard UI). `SUEnableInstallerLauncherService` and `SUEnableDownloaderService` are NOT set — these are only required for sandboxed apps, and MDViewer is not sandboxed (per CLAUDE.md constraints).

---

## Runtime State Verification

Post-install sanity checks for Plan 2's `verify_bundle.sh`:

```bash
#!/usr/bin/env bash
# Scripts/verify_bundle.sh — run after build, before notarize
set -euo pipefail

APP="${1:?app bundle path required}"
TEAM_ID="${2:-V7YK72YLFF}"

# 1) Exactly one Sparkle.framework — guards SPM double-bundle (SPK-10)
COUNT=$(find "$APP" -type d -name 'Sparkle.framework' | wc -l | xargs)
[ "$COUNT" = "1" ] || { echo "::error::expected 1 Sparkle.framework, found $COUNT"; exit 1; }

# 2) Framework is at the standard path
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] \
  || { echo "::error::Sparkle.framework not at Contents/Frameworks/"; exit 1; }

# 3) XPC services exist inside the framework
[ -d "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" ] \
  || { echo "::error::Installer.xpc missing"; exit 1; }
[ -d "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" ] \
  || { echo "::error::Downloader.xpc missing"; exit 1; }

# 4) Same team ID across app + framework + XPCs (Pitfall #15 — mismatched = runtime rejection)
for PATH_ in \
  "$APP" \
  "$APP/Contents/Frameworks/Sparkle.framework" \
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
do
  codesign -dvvv "$PATH_" 2>&1 | grep -q "TeamIdentifier=${TEAM_ID}" \
    || { echo "::error::wrong team identifier on $PATH_"; exit 1; }
done

# 5) Hardened runtime on app and framework (not strictly required on XPCs but Sparkle sets it)
for PATH_ in "$APP" "$APP/Contents/Frameworks/Sparkle.framework"; do
  codesign -dvvv "$PATH_" 2>&1 | grep -qE "flags=.*runtime" \
    || { echo "::error::hardened runtime not set on $PATH_"; exit 1; }
done

# 6) Info.plist has the required Sparkle keys
/usr/libexec/PlistBuddy -c "Print :SUFeedURL"             "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey"         "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :SUEnableAutomaticChecks" "$APP/Contents/Info.plist"

# 7) CFBundleVersion is integer (SPK-08 gate)
CFB_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
[[ "$CFB_VER" =~ ^[0-9]+$ ]] \
  || { echo "::error::CFBundleVersion is not a pure integer: '$CFB_VER' (Sparkle compares lexicographically — Pitfall #19)"; exit 1; }

echo "PASS: Sparkle bundle layout verified"
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| DSA signatures (Sparkle 1.x) | EdDSA (Ed25519, Sparkle 2.x) | Sparkle 2.0, 2021 | Non-issue for new integrations — just use `SUPublicEDKey` and never touch DSA |
| `sign_update -s <raw key>` | `sign_update --ed-key-file -` (stdin) | Sparkle 2.x+ | Raw `-s` deprecated as insecure; stdin keeps key off process args and `ps` output |
| Custom version comparator delegate | `CFBundleVersion` integer comparison | Sparkle 2.7 (deprecated) | Don't try to "fix" the lexicographic comparison in code — migrate CFBundleVersion instead |
| Hand-written appcast XML | `generate_appcast` handles sig + length + metadata | Sparkle 2.0+ | Hand-writing is still seen in tutorials; always prefer the tool |
| Manual framework copy | SPM binary target | Sparkle 2.x | Carthage/manual drop-in still works but creates Xcode project noise |

**Deprecated/outdated:**
- Custom version comparators (deprecated in Sparkle 2.7 — don't write one)
- `SUFeedURL` over HTTP (refused as of Sparkle 2.x — always HTTPS, see Pitfall #6)
- Raw DSA keys in Info.plist (`SUPublicDSAKey`) — migrate to `SUPublicEDKey` (we're greenfield; don't add DSA at all)

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Sparkle 2.9.1 installs cleanly under Xcode 26.2 on macos-26 | §Standard Stack | LOW — Sparkle 2.9.1 explicitly added Xcode 26.4-beta warning fixes; should be fully supported. **Mitigation:** Plan 2 dry-run against `v2.2.0-rc.2` tag catches this. |
| A2 | Release notes `<sparkle:releaseNotesLink>` pointing at a GitHub release page renders correctly in Sparkle's standard UI | Pitfall C, §Code Examples | MEDIUM — Sparkle loads the URL in a WKWebView; GitHub's release page is heavyweight HTML. Could look odd in Sparkle's update sheet. **Mitigation:** First-release smoke test verifies display; fall back to embedded `<description><![CDATA[…]]>` if ugly. |
| A3 | `CFBundleVersion=220` (derived by stripping dots from `2.2.0`) is a valid monotonic scheme for all foreseeable versions | Pitfall E, §Code Examples | LOW-MEDIUM — scheme breaks if a future version has 3+ digit patch (`2.2.10` → `2210` vs `2.3.0` → `230` — `2210` > `230` ✓ so this is FINE). Confirmed monotonic for any X.Y.Z with each component < 10000. **Mitigation:** Document the scheme in `docs/release/sparkle-setup.md`; revisit if we ever hit 10k+ patch. |
| A4 | `generate_appcast` produces XML that can be post-processed with Python's stdlib `xml.etree` without losing EdDSA signature bytes | §Code Examples Plan 2 | LOW — `xml.etree.ElementTree` preserves text nodes verbatim; `sparkle:edSignature` is an XML attribute, not a text node, so round-trip is safe. **Mitigation:** `grep -q 'sparkle:edSignature' build/appcast.xml` after post-process catches any loss. |
| A5 | GitHub's `/releases/latest/download/appcast.xml` URL serves the file from the most recently *published* (non-draft) release, with strong caching that propagates quickly | §Feed URL choice | MEDIUM — the phase 11 dry-run CI-13 left releases as drafts; `/latest/download/` may 404 against a drafts-only repo. **Mitigation:** CI-13 dry-run tag is `v2.2.0-rc.1`, which is a pre-release, which `/releases/latest/download/` DOES NOT serve (pre-releases excluded). First real `v2.2.0` publish is the actual smoke test. Document this in Plan 3. |
| A6 | The `printf '%s' "$SPARKLE_ED_PRIVATE_KEY"` pattern survives GitHub Actions' secret-redaction | §Scripts/generate_appcast.sh example | LOW — GitHub redacts secrets in stdout/stderr only; writing to a pipe for a subprocess input stream is unaffected. **Mitigation:** Confirm no `echo` or `set -x` leak in the CI step. |

If any of A1–A6 turn out to be wrong, failures will surface in the CI-13 dry-run or the first `v2.2.0` publish; none are silent-corruption risks.

---

## Open Questions

1. **Should the appcast URL be `…/releases/latest/download/appcast.xml` or a static Pages URL?**
   - What we know: GitHub's `/releases/latest/download/<asset>` URL redirects to the latest *published, non-pre-release* asset. Reliable as long as we always upload `appcast.xml` as a release asset. Phase context specifies this URL.
   - What's unclear: Behavior during a notarization rejection or draft-in-progress window (old appcast still reachable because the old release is still "latest"; what about the ~minutes where a draft is being prepared?).
   - Recommendation: Proceed with `/releases/latest/download/appcast.xml` per phase context. If v2.2.0 smoke test reveals a race, switch to GitHub Pages (`https://mitgor.github.io/mdviewer/appcast.xml`) which PITFALLS.md #10 already references as an alternative — this is a one-line Info.plist change and re-notarize, not a structural pivot.

2. **Does `generate_appcast` need an explicit `-s 7` (number of signed items) or does it auto-discover from the staging directory?**
   - What we know: `generate_appcast` scans a directory for DMG/zip files and produces an item per file. Behavior is "all files, newest first."
   - What's unclear: Whether we need to curate which version files sit in the staging directory, or whether it's fine to only include the new DMG.
   - Recommendation: Only stage the single new DMG. Sparkle's docs don't require historical versions in the appcast — clients read the latest item. The GitHub Releases page is the historical record. Verify during CI-13 dry-run that a single-item appcast is accepted by Sparkle on the client side.

3. **Does the post-processing step need to strip the `xml:lang="en"` attribute that `generate_appcast` might add to `<sparkle:releaseNotesLink>`?**
   - What we know: `generate_appcast` optionally accepts a folder of `.html` release notes. If none are provided, no releaseNotesLink is auto-added.
   - What's unclear: Exact idempotency of running the post-processor's "add sparkle:releaseNotesLink" step when the tool may or may not have already added one.
   - Recommendation: Post-processor should UPSERT (find existing `sparkle:releaseNotesLink`, set text, else create). Python's `xml.etree.ElementTree.find()` handles this.

4. **Does macOS Gatekeeper warn on first post-update launch because Sparkle installs into `/Applications` via authorization service?**
   - What we know: PITFALLS.md #23 covers the admin prompt; LaunchServices caches the `spctl` decision after first manual launch.
   - What's unclear: Whether the re-installed binary retains the stapled ticket (it should — stapling is file-attached, not LaunchServices-registered).
   - Recommendation: Don't pre-worry. Verify in the CI-13 dry-run by actually taking the `v2.2.0-rc.1` DMG, installing it, then pointing a test appcast at a newer build, triggering "Check for Updates," and confirming no Gatekeeper prompt on post-update launch.

---

## Environment Availability

| Dependency | Required By | Available on macos-26 runner | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Xcode / `xcodebuild` | SPM resolution | ✓ (pinned 26.2 in release.yml line 34) | 26.2 | — |
| Python 3 | appcast post-processing (`python3 -`) | ✓ (preinstalled on macos-26) | 3.12+ | `xmlstarlet` via brew (slower) |
| `find`, `grep`, `base64` | script plumbing | ✓ (macOS base install) | BSD | — |
| Sparkle binaries (generate_appcast, generate_keys, sign_update) | appcast generation | ✗ until Sparkle SPM resolved | 2.9.1 | None — must resolve before script runs |
| `swift package compute-checksum` | verify checksum if we ever pin an XCFramework directly | ✓ (part of Swift toolchain) | — | — |

**Missing dependencies with no fallback:** None — all required tools are present on macos-26 hosted runner.

**Missing dependencies with fallback:** Python 3 → xmlstarlet, though Python 3 is safer (preinstalled, stdlib covers our needs).

---

## Validation Architecture

`.planning/config.json` has `workflow.nyquist_validation: false` — section **OMITTED** per instructions.

---

## Security Domain

### Applicable ASVS Categories (macOS desktop app — ASVS sections that map)

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No (no user accounts) | — |
| V3 Session Management | No | — |
| V4 Access Control | Yes (update install requires admin) | Handled by Sparkle's Installer.xpc + system Authorization Services |
| V5 Input Validation | Yes (appcast XML parsed at runtime) | Sparkle parses with strict schema; `SURequireSignedFeed` optional (off) |
| V6 Cryptography | Yes (Ed25519 verification) | Sparkle framework — NEVER hand-roll |
| V10 Malicious Code | Yes (auto-download-and-execute is the feature) | EdDSA signature verification + HTTPS feed + Gatekeeper + notarization stapling |
| V14 Configuration | Yes (Info.plist keys are security-sensitive) | Use documented keys only; public key committed but never re-rotated without plan |

### Known Threat Patterns for Sparkle auto-update

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| MITM tampering of appcast to suppress update | Tampering | HTTPS feed URL + Sparkle's HTTPS enforcement (Pitfall #6) |
| MITM injection of malicious DMG | Tampering, Elevation of Privilege | Ed25519 signature on each enclosure; DMG must be notarized + stapled (Gatekeeper gate on install) |
| Feed replay to downgrade | Tampering | CFBundleVersion monotonic integer (SPK-08); Sparkle refuses downgrades |
| Key compromise (private key leak) | Information Disclosure | GitHub Secrets (at-rest encrypted) + offline backup (2 locations per PITFALLS #2); rotation procedure in Plan 3 docs |
| Key loss (no recovery, no ship) | Denial of Service | **Pre-release gate** (SPK-02) — backup BEFORE first Sparkle release |
| Local tamper with installed app's SUPublicEDKey | Tampering | macOS code signature covers Info.plist; Gatekeeper blocks modified app |
| XPC impersonation to inject fake installer | Spoofing, Elevation of Privilege | Sparkle 2 hardened XPC policy (peer team ID check — Pitfall #15); all components signed same team |

---

## Planning Implications

Five concrete things the planner should do differently because of what this research uncovered:

1. **Treat "add SPM dependency" as a non-trivial task.** MDViewer has no `Package.swift`, no `Package.resolved`, and no existing SPM dependencies. The planner's Plan 1 MUST include (a) editing `project.yml` to add the `packages:` block AND per-target `dependencies: - package: Sparkle`, (b) running `xcodegen generate` to regenerate `project.pbxproj`, (c) running `xcodebuild -resolvePackageDependencies` to create `Package.resolved`, (d) committing BOTH the regenerated pbxproj AND the new `Package.resolved`. A generic "add SPM dep" task that assumes a Package.swift exists will fail.

2. **Fix the CFBundleVersion migration task description.** Phase context and ROADMAP.md both reference migrating from `"1.0"`. **Actual current value is `"2.1"`** (verified by reading Info.plist). Task description should say "migrate from dotted string `2.X` to integer `2X0` scheme" — migration direction is correct, starting value is not. Additionally, `Scripts/set_version.sh` must be updated to set CFBundleVersion differently from CFBundleShortVersionString (it currently sets them both to the same thing).

3. **Add the `--ed-key-file -` (stdin) pattern to CI secret materialization in Plan 2 explicitly.** PITFALLS #14 describes the keychain-prompt blocker but defaults to writing the key to `$RUNNER_TEMP`. Recent Sparkle community consensus (Pitfall B in this research) is **stdin is preferred** — nothing touches disk. Prefer `echo "$KEY" | generate_appcast --ed-key-file -` over the tempfile-with-trap pattern. The tempfile pattern is a fine backup but should not be the default.

4. **Split the work along file-isolation boundaries, not along SPK-01..12 numbering.** Suggested three plans:
   - **Plan 1 — App integration.** Files: `project.yml`, `MDViewer.xcodeproj/*` (via xcodegen), `MDViewer/Info.plist` (add Sparkle keys with PLACEHOLDER public key), `MDViewer/AppDelegate.swift` (menu + updater controller), `Package.resolved` (new). Requirements: SPK-01, SPK-03, SPK-04, SPK-05, SPK-09 (Info.plist side). Parallelization: safe with Plan 2 after SPM resolves.
   - **Plan 2 — CI appcast pipeline.** Files: `.github/workflows/release.yml`, `Scripts/generate_appcast.sh` (new), `Scripts/verify_bundle.sh` (new). Requirements: SPK-06, SPK-07, SPK-09 (XML side), SPK-10, SPK-12. Depends on Plan 1 (Sparkle must be SPM-resolved for CI to find binaries).
   - **Plan 3 — Pre-release gates + docs + key lifecycle.** Files: `Scripts/set_version.sh` (CFBundleVersion integer scheme), `docs/release/ci-secrets.md` (backup procedure), `docs/release/sparkle-setup.md` (new — operator runbook for key generation), `README.md` (v2.1 manual-update notice), `MDViewer/Info.plist` (replace PLACEHOLDER public key with real one). Requirements: SPK-02, SPK-08, SPK-11. This plan has the human-in-the-loop step (generate keys, back them up, install SUPublicEDKey) and is the release gate. Runs AFTER Plans 1 and 2 are merged; BEFORE the first `v2.2.0` tag.

5. **Add a post-merge / pre-release operator checklist to Plan 3.** The CI-13 dry-run from Phase 11 is the forward integration test — but that's for the notarization pipeline. For Phase 12, the operator must also: (a) generate Sparkle keys on developer Mac, (b) paste public key into Info.plist in a dedicated single-line commit, (c) paste private key base64 into `SPARKLE_ED_PRIVATE_KEY` secret, (d) back up private key to TWO offline locations and fill in the backup-location placeholders in `docs/release/ci-secrets.md`, (e) run a NEW dry-run (`v2.2.0-rc.2` or similar) that exercises the full appcast path, (f) manually install the rc.2 DMG and confirm "Check for Updates" works against a staging appcast. Operator can't parallelize this with shipping v2.2.0 proper.

---

## Sources

### Primary (HIGH confidence)

- [Sparkle documentation — main](https://sparkle-project.org/documentation/) — canonical API reference and integration guide
- [Sparkle documentation — publishing](https://sparkle-project.org/documentation/publishing/) — signing and appcast generation
- [Sparkle documentation — customization](https://sparkle-project.org/documentation/customization/) — full Info.plist key list with types and defaults
- [Sparkle documentation — system profiling](https://sparkle-project.org/documentation/system-profiling/) — confirmed opt-in and no third-party destinations
- [Sparkle 2.9.1 GitHub release](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.1) — verified current stable version as of 2026-04-20
- [Sparkle changelog (2.x branch)](https://github.com/sparkle-project/Sparkle/blob/2.x/CHANGELOG) — SPM / Xcode 26 compatibility entries
- [Sparkle SPM PR #1634](https://github.com/sparkle-project/Sparkle/pull/1634) — official SPM binary target distribution model
- [SPUStandardUpdaterController API ref](https://sparkle-project.org/documentation/api-reference/Classes/SPUStandardUpdaterController.html) — exact init signature and @IBAction
- `.planning/research/v2.2/PITFALLS.md` — 26-item pitfall catalog (mandatory prior read for Phase 12)

### Secondary (MEDIUM confidence — verified against primary)

- [Sparkle discussion #2347 — SUPublicEDKey format](https://github.com/sparkle-project/Sparkle/discussions/2347) — confirms 44-char base64 = 32-byte Ed25519 pub key
- [VibeTunnel Sparkle keys docs](https://docs.vibetunnel.sh/mac/docs/sparkle-keys) — concrete `generate_keys -x` output format, single-line base64 convention
- [Sparkle PR #2615 — FileHandle stdin for key](https://github.com/sparkle-project/Sparkle/pull/2615) — confirmed `--ed-key-file -` stdin pattern
- [SwiftDevJournal: Accessing Sparkle binary from SPM](https://swiftdevjournal.com/accessing-the-sparkle-binary-from-its-swift-package/) — DerivedData path pattern
- [Michael Tsai — Setting Up Sparkle](https://mjtsai.com/blog/2023/05/22/setting-up-sparkle/) — SPM integration walkthrough
- [XcodeGen project spec](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md) — `packages:` block syntax for project.yml

### Tertiary (LOW confidence — used only for directional hints)

- [rampatra — Automating Xcode Sparkle Releases with GitHub Actions (Medium)](https://medium.com/@alex.pera/automating-xcode-sparkle-releases-with-github-actions-bd14f3ca92aa) — workflow pattern reference; concrete command syntax verified against official docs before adoption
- [Hammerspoon issue #2187 — CFBundleVersion scripts](https://github.com/Hammerspoon/hammerspoon/issues/2187) — precedent for `git rev-list --count` monotonic CFBundleVersion; we chose the simpler strip-dots scheme (A3) instead

---

## Metadata

**Confidence breakdown:**
- Standard Stack (Sparkle 2.9.1): HIGH — verified via GitHub releases and changelog
- Info.plist keys and values: HIGH — cross-verified customization docs + community examples
- SPM integration (no Package.swift): HIGH — verified by reading project.pbxproj, project.yml, repo root
- Appcast XML structure: MEDIUM — Sparkle's published docs don't include a canonical schema; verified across 3 independent examples (VibeTunnel, rampatra gist, SUAppcastItem API ref)
- CI wiring (generate_appcast path discovery, stdin key): MEDIUM-HIGH — verified by two independent community sources + PITFALLS #14; confirmed against `printf` vs `echo` newline pitfall
- CFBundleVersion migration arithmetic: HIGH — verified current value by reading Info.plist; migration math is standard integer comparison
- Security threat map: HIGH — cross-verified against Sparkle's own sandboxing docs + Apple's xpc team ID API docs
- Release notes URL rendering behavior: MEDIUM (A2) — partly assumed; first real release will be the smoke test

**Research date:** 2026-04-20
**Valid until:** 2026-07-20 (~3 months; Sparkle 2.x is stable; review if a 2.10.0 or 3.0.0 drops)

## RESEARCH COMPLETE
