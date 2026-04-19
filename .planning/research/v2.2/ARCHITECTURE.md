# Architecture: v2.2 Release Quality & Automation

**Project:** MDViewer
**Milestone:** v2.2 — CI-driven notarized releases, Sparkle 2.x auto-update, Homebrew tap
**Researched:** 2026-04-19
**Confidence:** HIGH on workflow shape and Sparkle wiring (cross-referenced Sparkle docs + 3+ public CI examples). MEDIUM on SPM XPC bundling edge cases (one open issue history, behavior may vary by Sparkle 2.x patch version — pin and verify in a smoke test). MEDIUM on `brew bump-cask-pr` invocation specifics from a tagged release in another repo (well documented but the PAT scope dance has historically tripped people up).

---

## 1. Top-Level Topology

Three repositories, one direction of dependency:

```
mitgor/mdviewer  (this repo)             mitgor/homebrew-tap  (separate repo)
├── source code                          ├── Casks/
├── .github/workflows/release.yml        │   └── mdviewer.rb       (auto-bumped)
├── Sparkle SPM dependency               └── README.md
├── (build artifacts: DMG, appcast.xml)
│
└── publishes ──► GitHub Release on this repo (v* tag)
                  ├── MDViewer-2.2.0.dmg          (download asset)
                  ├── MDViewer-2.2.0.dmg.sig      (optional, for non-Sparkle verifiers)
                  └── appcast.xml                 (download asset OR gh-pages)
                       │
                       ▼
                  Sparkle in installed app pulls
                  https://github.com/mitgor/mdviewer/releases/latest/download/appcast.xml
                  (or https://mitgor.github.io/mdviewer/appcast.xml if gh-pages chosen)

mdviewer release workflow → bumps cask in homebrew-tap via PAT
```

**Single source of truth for version:** the git tag `vX.Y.Z` pushed to `mitgor/mdviewer`. Everything else (Info.plist, appcast `sparkle:shortVersionString`, cask `version`) is derived from that tag at build time. This avoids the classic "I forgot to bump Info.plist" rebuild loop.

---

## 2. Repository Layout Changes (this repo)

```
mdviewer/
├── .github/
│   └── workflows/
│       ├── ci.yml                    (existing-or-new: PR builds + tests, no signing)
│       └── release.yml               (NEW: tag-triggered signed/notarized release)
├── .planning/                        (existing)
├── MDViewer/
│   ├── Info.plist                    (UPDATED: SUFeedURL, SUPublicEDKey, SUEnableAutomaticChecks)
│   ├── MDViewer.entitlements         (NEW or UPDATED: hardened-runtime entitlements; no sandbox needed)
│   └── ...                           (existing)
├── MDViewer.xcodeproj/               (regenerated from project.yml)
├── Vendor/cmark-gfm/                 (existing)
├── project.yml                       (UPDATED: add Sparkle SPM dep, embed phase)
├── Package.swift                     (UPDATED: Sparkle dependency added alongside swift-cmark)
├── Scripts/                          (NEW)
│   ├── set_version.sh                (writes git tag → Info.plist via PlistBuddy)
│   ├── make_dmg.sh                   (create-dmg wrapper; emits MDViewer-X.Y.Z.dmg)
│   ├── notarize.sh                   (notarytool submit + staple; idempotent)
│   └── update_appcast.sh             (calls generate_appcast with stdin-piped EdDSA key)
├── ExportOptions.plist               (NEW: developer-id distribution method)
└── README.md                         (UPDATED: brew install instructions, Sparkle note)
```

**Why a `Scripts/` directory rather than inline in `release.yml`:** Each script is independently runnable on a developer Mac. The CI workflow becomes thin orchestration, which makes "I need to reproduce this locally" a one-line invocation. This is the pattern the Franz/defn.io workflow uses (build.yml is mostly script invocations).

---

## 3. `.github/workflows/release.yml` Shape

**Single job** on `macos-14` (Apple Silicon runner; needed for native arm64 codesign). Splitting build/sign/notarize/release across jobs sounds clean but multiplies artifact upload/download cost and complicates keychain handoff. Keep it monolithic until pipeline exceeds ~25 minutes, which it won't for an app this size.

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write    # needed to create GitHub Release & upload assets

jobs:
  build-sign-notarize-release:
    runs-on: macos-14
    timeout-minutes: 30
    env:
      DEVELOPER_DIR: /Applications/Xcode_15.4.app/Contents/Developer
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0    # tag history needed for changelog generation

      - name: Derive version from tag
        id: version
        run: |
          TAG="${GITHUB_REF_NAME}"           # e.g. v2.2.0
          VERSION="${TAG#v}"                 # 2.2.0
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          echo "tag=$TAG"         >> "$GITHUB_OUTPUT"

      - name: Stamp version into Info.plist
        run: ./Scripts/set_version.sh "${{ steps.version.outputs.version }}"

      - name: Cache SPM dependencies
        uses: actions/cache@v4
        with:
          path: |
            ~/Library/Developer/Xcode/DerivedData/**/SourcePackages
            ~/Library/Caches/org.swift.swiftpm
          key: spm-${{ runner.os }}-${{ hashFiles('Package.resolved', 'MDViewer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved') }}
          restore-keys: spm-${{ runner.os }}-

      - name: Install signing certificate
        env:
          MAC_CERT_P12_BASE64: ${{ secrets.MAC_CERT_P12_BASE64 }}
          MAC_CERT_P12_PASSWORD: ${{ secrets.MAC_CERT_P12_PASSWORD }}
          KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
        run: |
          echo "$MAC_CERT_P12_BASE64" | base64 --decode > /tmp/cert.p12
          security create-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
          security default-keychain -s build.keychain
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
          security set-keychain-settings -lut 21600 build.keychain
          security import /tmp/cert.p12 -k build.keychain \
            -P "$MAC_CERT_P12_PASSWORD" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple:,codesign: \
            -s -k "$KEYCHAIN_PASSWORD" build.keychain
          rm /tmp/cert.p12

      - name: Generate Xcode project
        run: brew install xcodegen && xcodegen generate

      - name: Archive
        run: |
          xcodebuild archive \
            -project MDViewer.xcodeproj \
            -scheme MDViewer \
            -configuration Release \
            -archivePath build/MDViewer.xcarchive \
            -destination 'generic/platform=macOS' \
            CODE_SIGN_STYLE=Manual \
            DEVELOPMENT_TEAM=${{ secrets.APPLE_TEAM_ID }} \
            CODE_SIGN_IDENTITY="Developer ID Application"

      - name: Export
        run: |
          xcodebuild -exportArchive \
            -archivePath build/MDViewer.xcarchive \
            -exportPath build/export \
            -exportOptionsPlist ExportOptions.plist

      - name: Build DMG
        run: ./Scripts/make_dmg.sh build/export/MDViewer.app build/MDViewer-${{ steps.version.outputs.version }}.dmg

      - name: Notarize DMG
        env:
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
          ASC_API_KEY_ID: ${{ secrets.ASC_API_KEY_ID }}
          ASC_API_ISSUER_ID: ${{ secrets.ASC_API_ISSUER_ID }}
          ASC_API_KEY_P8_BASE64: ${{ secrets.ASC_API_KEY_P8_BASE64 }}
        run: ./Scripts/notarize.sh build/MDViewer-${{ steps.version.outputs.version }}.dmg

      - name: Update appcast.xml
        env:
          SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}
          VERSION: ${{ steps.version.outputs.version }}
        run: ./Scripts/update_appcast.sh

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ steps.version.outputs.tag }}
          name: MDViewer ${{ steps.version.outputs.version }}
          generate_release_notes: true
          files: |
            build/MDViewer-${{ steps.version.outputs.version }}.dmg
            build/appcast.xml

      - name: Bump Homebrew cask
        uses: macauley/action-homebrew-bump-cask@v1
        with:
          token: ${{ secrets.HOMEBREW_TAP_PAT }}
          tap: mitgor/homebrew-tap
          cask: mdviewer
          tag: ${{ steps.version.outputs.tag }}
```

**Notes on the shape:**

- `on: push: tags: [v*]` is the canonical "publish a release" trigger. Tag-driven, not branch-driven, because we want exactly one release per tag and tags are immutable in Git semantics. Verified pattern across Federico Terzi's article and the Franz/defn.io workflow.
- `macos-14` for arm64. `macos-latest` floats and has burned projects mid-Xcode-upgrade — pin.
- `permissions: contents: write` is required for `softprops/action-gh-release` to create the release using the default `GITHUB_TOKEN`. Tap bump uses a separate PAT (different repo).
- SPM cache key hashes `Package.resolved` paths. If both root `Package.swift` and the Xcode-managed `Package.resolved` exist, hash both to avoid stale caches.
- DerivedData is intentionally **not** cached. It's brittle (`irgaly/xcode-cache` exists exactly because vanilla `actions/cache` corrupts mtimes), the project is small (~5min cold archive), and a CI-corrupted `.xcarchive` failing notarization is a much worse outcome than a 3-min savings.
- Single keychain unlocked for 21600s (6h) per Franz pattern — well above the workflow timeout.

---

## 4. Secrets Architecture

| Secret name | What it is | How produced | Consumed by |
|---|---|---|---|
| `MAC_CERT_P12_BASE64` | "Developer ID Application" cert + private key, exported as `.p12`, then `base64` | Keychain Access → Export → set password → `base64 -i cert.p12 -o cert.p12.b64` | "Install signing certificate" step |
| `MAC_CERT_P12_PASSWORD` | Password used during the `.p12` export | Set during the export above | "Install signing certificate" step |
| `KEYCHAIN_PASSWORD` | Arbitrary password for the throwaway CI keychain | `openssl rand -base64 32` once, store as secret | "Install signing certificate" step |
| `APPLE_ID` | Developer Apple ID email | Apple Developer account | (only needed if falling back to app-specific password notarization; unused with API key) |
| `APPLE_TEAM_ID` | 10-char Team ID (e.g. `ABCDE12345`) | Apple Developer account | `xcodebuild` archive + `notarytool` submit |
| `ASC_API_KEY_ID` | App Store Connect API key ID (10 chars) | App Store Connect → Users and Access → Integrations → App Store Connect API → key | `notarytool` submit |
| `ASC_API_ISSUER_ID` | Issuer UUID for the API key | Same App Store Connect screen | `notarytool` submit |
| `ASC_API_KEY_P8_BASE64` | The `.p8` private key, base64-encoded | Download from App Store Connect (one-time only!), `base64 -i AuthKey_XXX.p8 -o AuthKey.p8.b64` | `notarytool` submit (decoded into a tmpfile, passed via `--key`) |
| `SPARKLE_ED_PRIVATE_KEY` | EdDSA private key (base64) for signing appcast updates | `generate_keys` tool, stored in dev Mac keychain originally; export once via `generate_keys -x /path/to/private.key` | `generate_appcast` via stdin (never written to disk in CI) |
| `HOMEBREW_TAP_PAT` | Fine-grained PAT with **Contents: Read & Write** on `mitgor/homebrew-tap` only | GitHub → Settings → Developer settings → Personal access tokens → Fine-grained | `macauley/action-homebrew-bump-cask` (it forks-and-PRs into the tap) |

**Why API key over app-specific password for notarytool:** API keys don't depend on a specific human Apple ID and don't expire when the human's password changes. They're scoped to the developer team and revocable independently. App-specific passwords are the "I'm in a hurry" path; API key is the production path.

**Why a fine-grained PAT for the tap, not classic `repo` PAT:** A classic `repo` PAT can read/write every private repo the user owns. A fine-grained PAT can be scoped to a single repository. The action requires the PAT (not `GITHUB_TOKEN`) because `brew bump-cask-pr` performs `git push` to a fork.

**EdDSA key — keychain vs secret:** Sparkle's `generate_keys` tool stores the key in the developer's macOS keychain by default. For CI, you `generate_keys -x` once to extract it, paste it into the GitHub secret, and treat the GitHub secret as the production key from then on. The keychain copy is a backup. The public key (`SUPublicEDKey` in Info.plist) is committed to the repo — no secret needed.

---

## 5. Sparkle Integration

### 5.1 Info.plist additions

```xml
<key>SUFeedURL</key>
<string>https://github.com/mitgor/mdviewer/releases/latest/download/appcast.xml</string>

<key>SUPublicEDKey</key>
<string>BASE64_PUBLIC_ED_KEY_FROM_generate_keys</string>

<key>SUEnableAutomaticChecks</key>
<true/>

<key>SUScheduledCheckInterval</key>
<integer>86400</integer>
```

**`SUFeedURL` choice:** GitHub Releases asset URL via the `/releases/latest/download/` redirect. This sidesteps the gh-pages dance entirely — every tagged release uploads a fresh `appcast.xml` as an asset, and `latest/download/appcast.xml` always 302s to the newest one. Zero extra infra. The tradeoff is: appcast versioning isn't accumulative across releases (each tag publishes a fresh appcast). This is fine for MDViewer because Sparkle only needs to know about *latest*, not history. (The Sparkle discussion thread #2308 noted the same limitation.)

**Alternative considered: gh-pages.** Would let `appcast.xml` accumulate `<item>` entries over time and serve from a stable URL. Adds a second commit step in CI, requires gh-pages branch maintenance. Not worth it for a quick-preview app — recommend GitHub Releases asset.

**`SUPublicEDKey`:** committed to the repo. Public by definition, signed update validation depends on it being baked into shipped builds.

**`SUEnableAutomaticChecks: true`** with default check interval (1 day). MDViewer is opened often and briefly, so background daily check is unobtrusive.

**Sandboxing keys (`SUEnableInstallerLauncherService` etc.):** **not needed** — MDViewer is unsandboxed (no `App Sandbox` entitlement). Sparkle auto-detects this and skips the XPC service path. Confirmed in Sparkle 2.x docs: "if no XPC services are bundled with your app, Sparkle behaves like it used to" (christiantietze.de).

### 5.2 SPM dependency wiring

Sparkle is added to `Package.swift` (which XcodeGen consumes via `MDViewerDeps` per the existing pattern):

```swift
// Package.swift
let package = Package(
    name: "MDViewerDeps",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-cmark", branch: "gfm"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "MDViewerDeps", dependencies: [
            .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
    ]
)
```

And in `project.yml` add Sparkle as an SPM-resolved dependency on the `MDViewer` target:

```yaml
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: 2.6.0

targets:
  MDViewer:
    # ...existing config...
    dependencies:
      - target: cmark-gfm
      - target: cmark-gfm-extensions
      - package: Sparkle
```

### 5.3 SPM + XPC services — the gotcha

Sparkle 2.x ships its XPC services (`Installer.xpc`, `Downloader.xpc`) **inside** the framework bundle (`Sparkle.framework/Versions/B/XPCServices/`). For SPM, Xcode's "Embed & Sign" automatically copies the framework — including its embedded XPC services — into `MDViewer.app/Contents/Frameworks/Sparkle.framework/`. No manual "Copy Files" build phase is needed for the XPC services themselves.

**Known SPM bug to verify:** Issue #1689 reported Sparkle being bundled twice (once in `Frameworks`, once in `SharedSupport`/`Resources`). This was specifically the binary-target SPM path; should be fixed in modern Sparkle 2.x but **add a smoke test** to the release workflow that asserts only one `Sparkle.framework` exists in the final `.app`:

```bash
# Scripts/verify_bundle.sh
COUNT=$(find build/export/MDViewer.app -name "Sparkle.framework" -type d | wc -l)
[ "$COUNT" -eq 1 ] || { echo "Sparkle bundled $COUNT times"; exit 1; }
```

Run between Export and Notarize.

### 5.4 Calling `SPUStandardUpdaterController`

Minimal Swift wiring in `AppDelegate.swift`:

```swift
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    @IBAction func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }
    // ...
}
```

Plus a "Check for Updates…" menu item under the app menu wired to `checkForUpdates(_:)`. Standard pattern.

---

## 6. Versioning Flow

**Single source of truth:** the git tag `vX.Y.Z`.

```
┌──────────────────────────────────────────────────────────────┐
│ developer: git tag v2.2.0 && git push origin v2.2.0          │
└──────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│ release.yml step "Derive version from tag":                  │
│   VERSION = ${TAG#v}    # 2.2.0                              │
└──────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│ Scripts/set_version.sh:                                      │
│   /usr/libexec/PlistBuddy -c \                               │
│     "Set :CFBundleShortVersionString $VERSION" Info.plist    │
│   /usr/libexec/PlistBuddy -c \                               │
│     "Set :CFBundleVersion $VERSION" Info.plist               │
└──────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│ xcodebuild archive picks up the stamped Info.plist           │
│   → MDViewer.app advertises version 2.2.0 to Finder/About    │
│   → Sparkle reads CFBundleShortVersionString at runtime      │
└──────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│ generate_appcast scans the .dmg directory and produces:      │
│   <sparkle:shortVersionString>2.2.0</...>                    │
│   <sparkle:version>2.2.0</...>                               │
│ derived from the .app inside the .dmg                        │
└──────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│ macauley/action-homebrew-bump-cask uses tag input:           │
│   tag: v2.2.0                                                │
│ → opens PR to homebrew-tap/Casks/mdviewer.rb                 │
│   bumping  version "2.1.0"  →  version "2.2.0"               │
└──────────────────────────────────────────────────────────────┘
```

The `Info.plist` in git stays at whatever version was last released. The CI mutation is ephemeral (lives only in the runner's checkout). No "I forgot to bump the plist" mistake possible.

---

## 7. End-to-End Sequence: Tag Push to User Update

```
TIME  ACTOR              EVENT
────  ─────────────────  ──────────────────────────────────────────────
T+0   developer          git tag v2.2.0 && git push --tags
T+10s GitHub             release.yml triggered
T+1m  runner             checkout, derive VERSION=2.2.0, stamp Info.plist
T+2m  runner             SPM cache restored, xcodegen regen project
T+5m  runner             xcodebuild archive (cmark+Sparkle linked, signed)
T+6m  runner             xcodebuild -exportArchive (Developer ID method)
T+6m  runner             verify_bundle.sh → exactly 1 Sparkle.framework
T+7m  runner             create-dmg → MDViewer-2.2.0.dmg
T+10m runner             notarytool submit --wait → "Accepted"
T+10m runner             stapler staple MDViewer-2.2.0.dmg
T+11m runner             generate_appcast (EdDSA private key from stdin)
                          → produces appcast.xml with edSignature
T+12m runner             gh release create v2.2.0
                          uploads MDViewer-2.2.0.dmg + appcast.xml
T+12m runner             action-homebrew-bump-cask
                          → forks mitgor/homebrew-tap, edits Casks/mdviewer.rb
                          → opens PR ("mdviewer 2.1.0 → 2.2.0")
                          → developer merges (or auto-merge if configured)
T+24h existing user      Sparkle scheduled check fires
                          GET https://github.com/mitgor/mdviewer/releases/
                              latest/download/appcast.xml
                          → 302 to v2.2.0 asset → fetches XML
                          → compares CFBundleShortVersionString (2.1) <
                                       sparkle:shortVersionString (2.2.0)
                          → prompts user, downloads DMG, verifies edSignature
                          → installs (no XPC needed, unsandboxed app)
T+24h+ brew user         brew upgrade --cask mdviewer
                          → reads new mitgor/homebrew-tap/Casks/mdviewer.rb
                          → downloads same DMG, sha256 matches, installs
```

---

## 8. Homebrew Tap Repository

### 8.1 `mitgor/homebrew-tap` topology

```
homebrew-tap/
├── README.md                         (install instructions; required for discoverability)
├── Casks/
│   └── mdviewer.rb                   (single-letter subdir 'm/' is optional for small taps)
└── .github/                          (optional: CI to run brew audit on PRs)
    └── workflows/
        └── audit.yml                 (runs `brew audit --strict --new` on PRs)
```

The tap repo **must** be named `homebrew-tap` (or `homebrew-something`) for `brew tap mitgor/tap` shorthand to work. The leading `homebrew-` prefix is consumed by `brew tap`.

### 8.2 `Casks/mdviewer.rb`

```ruby
cask "mdviewer" do
  version "2.2.0"
  sha256 "abc123...computed_at_release_time..."

  url "https://github.com/mitgor/mdviewer/releases/download/v#{version}/MDViewer-#{version}.dmg",
      verified: "github.com/mitgor/mdviewer/"

  name "MDViewer"
  desc "Fast native macOS markdown viewer with LaTeX typography"
  homepage "https://github.com/mitgor/mdviewer"

  livecheck do
    url "https://github.com/mitgor/mdviewer/releases/latest/download/appcast.xml"
    strategy :sparkle
  end

  auto_updates true        # signal to brew that Sparkle handles in-app updates
  depends_on macos: ">= :ventura"

  app "MDViewer.app"

  zap trash: [
    "~/Library/Preferences/com.mdviewer.app.plist",
    "~/Library/Saved Application State/com.mdviewer.app.savedState",
    "~/Library/Application Support/MDViewer",
  ]
end
```

**`auto_updates true`** is important: it tells Homebrew "this app updates itself via Sparkle, don't fight it." Without it, `brew upgrade --cask mdviewer` may downgrade an already-Sparkle-updated install.

**`livecheck` with `strategy :sparkle`** lets `brew livecheck` verify the cask is current by parsing the appcast — same XML Sparkle uses. Single source of truth for "what version is current."

### 8.3 README.md (required)

Bare minimum — `brew tap-new` generates a stub but customize:

```markdown
# mitgor/tap

Homebrew tap for [MDViewer](https://github.com/mitgor/mdviewer).

## Install

\`\`\`sh
brew install --cask mitgor/tap/mdviewer
\`\`\`

Or, after tapping:

\`\`\`sh
brew tap mitgor/tap
brew install --cask mdviewer
\`\`\`
```

### 8.4 How `brew bump-cask-pr` is invoked from this repo

The `macauley/action-homebrew-bump-cask` step in `release.yml` does the work. Mechanically it:

1. Sets up Homebrew on the runner.
2. Authenticates as the PAT-holder.
3. Forks `mitgor/homebrew-tap` to the PAT-owner's account if not already forked.
4. Runs `brew bump-cask-pr --version=2.2.0 --tag=v2.2.0 mitgor/tap/mdviewer`.
5. `brew` itself computes the new sha256 by downloading the new DMG from the release URL, edits the cask file, pushes to the fork, opens a PR.
6. `mitgor` (or auto-merge) merges. Done.

**Why a PAT not `GITHUB_TOKEN`:** `GITHUB_TOKEN` is scoped to the running repo only. Forking and PRing into another repo (`mitgor/homebrew-tap`) requires credentials that have access there. A fine-grained PAT scoped to that single repo is the principle-of-least-privilege answer.

---

## 9. Critical Sub-Sequences

### 9.1 Notarize script (`Scripts/notarize.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

DMG_PATH="$1"

# Decode the .p8 to a tmp file (notarytool wants a file path, not stdin)
P8_PATH=$(mktemp -t asc_key)
trap 'rm -f "$P8_PATH"' EXIT
echo "$ASC_API_KEY_P8_BASE64" | base64 --decode > "$P8_PATH"

xcrun notarytool submit "$DMG_PATH" \
  --key      "$P8_PATH" \
  --key-id   "$ASC_API_KEY_ID" \
  --issuer   "$ASC_API_ISSUER_ID" \
  --wait \
  --timeout 20m

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
```

`--wait` blocks until Apple finishes (usually 1–10 min). Trap deletes the `.p8` even if notarization fails.

### 9.2 Update appcast script (`Scripts/update_appcast.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

# Sparkle's tools live in the SPM artifacts dir after first build
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin' -type d | head -n1)
GENERATE="$SPARKLE_BIN/generate_appcast"

mkdir -p build/appcast_input
cp "build/MDViewer-${VERSION}.dmg" build/appcast_input/

# Pipe the EdDSA private key via stdin -- never touches disk
echo "$SPARKLE_ED_PRIVATE_KEY" | "$GENERATE" \
  --ed-key-file - \
  --download-url-prefix "https://github.com/mitgor/mdviewer/releases/download/v${VERSION}/" \
  --link "https://github.com/mitgor/mdviewer/releases/tag/v${VERSION}" \
  build/appcast_input

mv build/appcast_input/appcast.xml build/appcast.xml
```

The `--ed-key-file -` stdin form is the recommended pattern from Sparkle discussion #2308 to avoid writing the private key to the runner's disk.

### 9.3 `ExportOptions.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
```

Committed to repo. Team ID is not a secret (it's visible in any signed app's `codesign -dv` output).

---

## 10. Hardened Runtime + Entitlements

Notarization requires Hardened Runtime (`--options runtime` to codesign, or `ENABLE_HARDENED_RUNTIME = YES` in build settings). MDViewer's WKWebView and cmark JIT-free C parsing don't need any entitlement exceptions, so the entitlements file is minimal:

```xml
<!-- MDViewer/MDViewer.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- intentionally empty: Hardened Runtime defaults are sufficient -->
</dict>
</plist>
```

XcodeGen project.yml adds:

```yaml
targets:
  MDViewer:
    settings:
      ENABLE_HARDENED_RUNTIME: YES
      CODE_SIGN_ENTITLEMENTS: MDViewer/MDViewer.entitlements
```

If a future feature needs JIT (it shouldn't — Mermaid runs in WebKit's already-sandboxed JS engine), add `com.apple.security.cs.allow-jit`. Not anticipated for v2.2.

---

## 11. Where State Lives — Summary Table

| State | Lives in | Rationale |
|---|---|---|
| Version number | git tag (`vX.Y.Z`) | Single source of truth; immutable; triggers CI |
| Info.plist version | Stamped in CI from tag | Avoids "forgot to bump" class of bugs |
| Sparkle EdDSA private key | GitHub secret + dev Mac keychain backup | CI needs it; never committed; rotatable |
| Sparkle EdDSA public key | Info.plist (committed) | Public by design; must ship with app |
| Signing cert (`.p12`) | GitHub secret (base64) + dev Mac keychain | CI needs it; physical cert in keychain is the master |
| App Store Connect API key (`.p8`) | GitHub secret (base64) | One-time download from Apple; cannot be re-downloaded |
| Appcast.xml | GitHub release asset on each tag | Sparkle reads `latest/download/appcast.xml` redirect |
| Cask version + sha256 | `mitgor/homebrew-tap/Casks/mdviewer.rb` | Computed from DMG at release time |
| DMG | GitHub release asset | Immutable per tag; what notarization staples to |
| Build artifacts (`.xcarchive`) | runner only, discarded | Reproducible from source + tag |
| Homebrew PAT | GitHub secret | Scoped to tap repo only |

---

## 12. Open Questions / Things to Validate in Phase 1

1. **Sparkle SPM double-bundle bug** — re-test on the chosen Sparkle version (≥2.6 recommended). If reproduced, fall back to manual framework download or Carthage-with-XCFramework.
2. **Notarization runner architecture** — `macos-14` is arm64. Verify the DMG produced runs on Intel Macs too (xcodebuild defaults to building for the host arch unless `ARCHS=arm64;x86_64` set explicitly). If MDViewer needs Intel support, stay with universal binary build.
3. **`brew bump-cask-pr` from a tag without a sha256 yet** — the action computes the sha256 by downloading the DMG. Verify the GitHub release asset is publicly available *before* the bump step runs (it is, in the workflow above — `softprops/action-gh-release` completes before the bump step).
4. **First-time secret bootstrap** — neither the EdDSA key nor the cask file exist yet for v2.2. Phase 1 needs a one-time `generate_keys` invocation on the dev Mac, then a manual first cask file commit before the workflow can auto-bump.

---

## 13. Sources

| Source | Use | Confidence contribution |
|---|---|---|
| [Sparkle Publishing docs](https://sparkle-project.org/documentation/publishing/) | Appcast XML format, generate_appcast, sign_update | HIGH |
| [Sparkle Customization docs](https://sparkle-project.org/documentation/customization/) | Complete Info.plist key reference | HIGH |
| [Sparkle Sandboxing docs](https://sparkle-project.org/documentation/sandboxing/) | XPC service requirements (only for sandboxed apps) | HIGH |
| [Sparkle GitHub](https://github.com/sparkle-project/Sparkle) | Latest version 2.9.1 (2026-03-29), SPM URL | HIGH |
| [Sparkle issue #1689](https://github.com/sparkle-project/Sparkle/issues/1689) | SPM double-bundle bug history | MEDIUM (verify on current version) |
| [Sparkle discussion #2308](https://github.com/sparkle-project/Sparkle/discussions/2308) | EdDSA stdin pattern, generate_appcast in CI | HIGH |
| [Federico Terzi — codesign + notarize](https://federicoterzi.com/blog/automatic-code-signing-and-notarization-for-macos-apps-using-github-actions/) | Keychain setup pattern, codesign step | HIGH |
| [defn.io — Distributing Mac Apps](https://defn.io/2023/09/22/distributing-mac-apps-with-github-actions/) | Reference to Franz workflow split-job approach | MEDIUM |
| [Franz build.yml on GitHub](https://github.com/Bogdanp/Franz/blob/388edfd7238839af52ecda9ad8554fba7e462db5/.github/workflows/build.yml) | Real-world archive/notarize/DMG pattern | HIGH |
| [omkarcloud/macos-code-signing-example](https://github.com/omkarcloud/macos-code-signing-example) | Secret naming conventions | MEDIUM |
| [Christian Tietze — Sparkle XPC setup](https://christiantietze.de/posts/2019/06/sparkle-xpc-setup/) | SPM vs Carthage XPC handling | HIGH |
| [Homebrew Tap docs](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap) | Tap repo structure, naming, `Casks/` directory | HIGH |
| [macauley/action-homebrew-bump-cask](https://github.com/marketplace/actions/homebrew-bump-cask) | PAT requirement, action input shape | HIGH |
| [MacDown cask example](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/m/macdown.rb) | Real cask DSL with Sparkle livecheck | HIGH |
| [Alexander Perathoner — Xcode + Sparkle CI](https://medium.com/@alex.pera/automating-xcode-sparkle-releases-with-github-actions-bd14f3ca92aa) | End-to-end flow reference | MEDIUM |
| [Apple notarytool docs](https://keith.github.io/xcode-man-pages/notarytool.1.html) | API key submit semantics | HIGH |
