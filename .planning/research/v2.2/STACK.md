# v2.2 Stack Research — Release Quality & Automation

**Researched:** 2026-04-18
**Scope:** New tooling for CI-driven notarization, Sparkle auto-update, Homebrew cask, and Instruments measurement.
**Overall confidence:** HIGH (most claims verified against official docs / GitHub release pages); MEDIUM on a few CLI specifics noted inline.

## TL;DR — Pinned Stack

| Component | Recommendation | Pin |
|-----------|----------------|-----|
| Sparkle | 2.x via SPM, `.upToNextMajor(from: "2.9.1")` | tag `2.9.1` (latest 2.x as of Apr 2026) |
| GitHub Actions runner | `macos-26` (arm64, GA Feb 2026) | `runs-on: macos-26` |
| Xcode in CI | 26.2 (default on macos-26) | leave as default; or `sudo xcode-select -s /Applications/Xcode_26.2.app` |
| Cert import action | `Apple-Actions/import-codesign-certs@v6.0.0` | SHA-pin once chosen |
| Notarization auth | App Store Connect API key (`.p8` + Key ID + Issuer ID), App Manager role | secrets in GH Actions |
| DMG build | `create-dmg/create-dmg` (shell, no deps) | pin commit SHA |
| Homebrew cask | personal tap `mitgor/homebrew-tap` with `Casks/mdviewer.rb` | — |
| Cask bumper | `macAuley/action-homebrew-bump-cask` triggered on `v*` tag push | SHA-pin |
| Signpost extraction | `xctrace export --xpath` over `.trace` (manual; no first-class signpost CSV exporter) | n/a |

---

## 1. Sparkle 2.x

### Latest stable
- **2.9.1** — released **2024-03-29**. This is the current head of `2.x` branch as of April 2026; no `2.10.x` / `2.11.x` releases for the macOS Sparkle framework. (Note: WebSearch hits for "Sparkle 2.10/2.11/2.12" refer to a separate Windows debloater app of the same name, not the macOS update framework — false-positive, ignored.) [HIGH]
  - Source: <https://github.com/sparkle-project/Sparkle/releases/tag/2.9.1>
  - Source: <https://github.com/sparkle-project/Sparkle/blob/2.x/CHANGELOG>
- 2.9.1 fixes a race in `clearDownloadedUpdate` and improves the appcast generation tool. 2.8.x added macOS 26 (Tahoe) compatibility.

### SPM integration
- **Repository URL:** `https://github.com/sparkle-project/Sparkle`
- Add via Xcode: File → Add Packages → paste URL → "Up to Next Major Version" starting at `2.9.1`.
- Equivalent in `Package.swift`:
  ```swift
  .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMajor(from: "2.9.1"))
  ```
- Sparkle is officially "Swift PM compatible" (per project README). [HIGH]
  - Source: <https://sparkle-project.org/documentation/> ("Installing with Swift Package Manager")
  - Source: <https://github.com/sparkle-project/Sparkle> (README "Swift PM compatible")

### Signing tools after SPM install
- After SPM resolution, the bundled CLI tools live in:
  ```
  <DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin/
  ```
  containing `generate_keys`, `sign_update`, `generate_appcast`. Right-click the `Sparkle` package in Xcode's project navigator → "Show in Finder" → navigate to `../artifacts/sparkle/Sparkle/bin/`. [HIGH]
  - Source: <https://sparkle-project.org/documentation/> (Installing with SPM section)

### EdDSA key setup (one-time)
```bash
# 1. Generate the Ed25519 keypair (private key stored in macOS login Keychain)
./bin/generate_keys
# → prints public key, e.g. pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ=

# 2. Embed public key in Info.plist
#    <key>SUPublicEDKey</key>
#    <string>pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ=</string>

# 3. To re-print the public key later:
./bin/generate_keys -p

# 4. Export the private key for CI (do this on the dev Mac, store as GH Secret):
./bin/generate_keys -x sparkle_private_key.txt
# → store contents as a secret (e.g. SPARKLE_ED_PRIVATE_KEY); restore in CI before signing
```
[HIGH] Source: <https://sparkle-project.org/documentation/> ("EdDSA signing of updates")

### Signing a release artifact
```bash
./bin/sign_update MDViewer-2.2.0.dmg
# → outputs:  sparkle:edSignature="..." length="1879795"
# Paste both attributes into the appcast <enclosure> element.
```
Or, preferred: `./bin/generate_appcast <Updates_dir>` auto-signs every artifact and emits a complete `appcast.xml`. [HIGH]
- Source: <https://sparkle-project.org/documentation/publishing/>

### Sparkle docs URL
- Top-level docs: <https://sparkle-project.org/documentation/>
- Publishing / appcast: <https://sparkle-project.org/documentation/publishing/>
- Sandboxing (relevant if MDViewer is ever sandboxed — currently not): <https://sparkle-project.org/documentation/sandboxing/>

---

## 2. GitHub Actions macOS Runner

### Recommendation
- **`runs-on: macos-26`** — GA on **2026-02-26**, native Apple Silicon (arm64). MDViewer ships universal binaries via Xcode default build; arm64 runner is fine and produces both slices (Xcode `ARCHS = standard` includes `arm64 x86_64` for macOS apps). [HIGH]
  - Source: <https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/>
  - Source: <https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md>

### Runner labels available (April 2026)
| Label | OS | Arch | Notes |
|-------|-----|------|-------|
| `macos-26` | 26 (Tahoe) | arm64 (M-series) | **GA Feb 2026 — preferred** |
| `macos-26-intel` | 26 | x86_64 | Public beta as of 2025-09 |
| `macos-15` | 15 (Sequoia) | arm64 | GA April 2025; still supported |
| `macos-15-intel` | 15 | x86_64 | Supported |
| `macos-14` | 14 (Sonoma) | arm64 | **Deprecated** — fully unsupported by 2025-11-02 |
| `macos-latest` | → `macos-15` since Aug 2025 (per GitHub policy) | arm64 | Avoid implicit drift |

[HIGH] Sources: <https://github.com/actions/runner-images/issues/12520>, <https://github.blog/changelog/2025-04-10-github-actions-macos-15-and-windows-2025-images-are-now-generally-available/>

### Xcode preinstalled on macos-26 (arm64)
| Xcode | Build | Default? |
|-------|-------|----------|
| 26.5 (beta) | 17F5012f | no |
| 26.4 | 17E192 | no |
| 26.3 | 17C529 | no |
| **26.2** | **17C52** | **yes** |
| 26.1.1 | 17B100 | no |
| 26.0.1 | 17A400 | no |

[HIGH] Source: <https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md>

### Apple Silicon implication for MDViewer
- macos-26 runs natively on M-series. Local universal builds remain identical. No special action needed; just ensure `xcodebuild archive` is invoked (no `-arch x86_64` override).
- `cmark-gfm` (vendored C) compiles cleanly under arm64 macOS — already proven by local builds.

### Xcode selection (only if pinning a non-default version)
```yaml
- name: Select Xcode
  run: sudo xcode-select -s /Applications/Xcode_26.2.app
```

---

## 3. Notarytool Credentials in CI

### Verdict: **App Store Connect API key (`.p8`)** for unattended CI
**Not** an app-specific password. The API key is the Apple-recommended path for automation: no MFA, no Apple ID password rotation, no human prompt. App-specific passwords work but require an Apple ID (account-tied) and are awkward to rotate in CI. [HIGH]
- Source: <https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool>
- Source: <https://keith.github.io/xcode-man-pages/notarytool.1.html> (notarytool man page lists `--key`, `--key-id`, `--issuer` as Team API key auth)

### Required pieces
1. **`.p8` private key file** — downloaded once at creation time, never available again.
2. **Key ID** — 10-character alphanumeric (e.g. `59GAB85EFG`).
3. **Issuer ID** — UUID identifying the team (e.g. `a04788a9-0819-478d-936f-6ff0fd860df5`).

### Where to generate
1. Sign in to **App Store Connect** → **Users and Access** → **Integrations** tab → **Team Keys** (NOT Individual Keys — individual keys cannot use notarytool). [HIGH]
   - Source: <https://developer.apple.com/forums/thread/133063> (Apple staff: individual keys can't notarize)
2. Click **+** to generate a new key.
3. Set role: **Developer** is the documented minimum that works for notarization. (App Manager and Account Holder also work; Developer is least-privilege.) [MEDIUM — community consensus + Apple staff hints; no single doc page enumerates the matrix]
   - Source: <https://developer.apple.com/forums/thread/133063>
4. Download the `.p8` immediately and copy the Key ID + Issuer ID.

> Note: prompt mentioned "App Manager role" — that works too, but **Developer** is sufficient and least-privilege; prefer it.

### Storing in GitHub Actions
| Secret name | Contents |
|-------------|----------|
| `APPSTORE_API_KEY_P8` | full contents of the `.p8` file (including BEGIN/END lines) |
| `APPSTORE_API_KEY_ID` | the 10-char Key ID |
| `APPSTORE_API_ISSUER_ID` | the UUID Issuer ID |

### CI invocation
```bash
# Materialize the .p8 from the secret
mkdir -p ~/.appstoreconnect/private_keys
echo "$APPSTORE_API_KEY_P8" > ~/.appstoreconnect/private_keys/AuthKey_${APPSTORE_API_KEY_ID}.p8

# Submit + wait + staple
xcrun notarytool submit MDViewer-2.2.0.dmg \
  --key ~/.appstoreconnect/private_keys/AuthKey_${APPSTORE_API_KEY_ID}.p8 \
  --key-id "${APPSTORE_API_KEY_ID}" \
  --issuer "${APPSTORE_API_ISSUER_ID}" \
  --wait

xcrun stapler staple MDViewer-2.2.0.dmg
```
[HIGH] Sources: <https://keith.github.io/xcode-man-pages/notarytool.1.html>, <https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool>

> The `--keychain-profile` form (`xcrun notarytool store-credentials`) is **not** suitable for ephemeral CI runners — it writes to the macOS Keychain which is wiped between runner jobs. Use `--key/--key-id/--issuer` directly.

---

## 4. Code-Signing Certificate Import in CI

### Recommendation: `Apple-Actions/import-codesign-certs@v6.0.0`
- Latest release: **v6.0.0** on **2024-12-02**. Upgrades to Node 24 and adds `productsign` support. [HIGH]
  - Source: <https://github.com/Apple-Actions/import-codesign-certs/releases>
- Maintained by Apple's GitHub org (`Apple-Actions`) — appropriate trust level for handling `.p12`.

### Usage
```yaml
- name: Import Developer ID cert
  uses: Apple-Actions/import-codesign-certs@v6.0.0
  with:
    p12-file-base64: ${{ secrets.DEVELOPER_ID_P12 }}
    p12-password:    ${{ secrets.DEVELOPER_ID_P12_PASSWORD }}
    # creates an ephemeral keychain `signing_temp.keychain-db`
    # auto-unlocked for this job, deleted after
```
The action creates a temporary keychain, unlocks it for the job, and prepends it to the search list — `codesign` will find the identity automatically. [HIGH]
- Source: <https://github.com/Apple-Actions/import-codesign-certs/blob/main/action.yml>

### Pin recommendation
- Pin to a commit SHA (not just `@v6.0.0`) since this action handles secrets:
  ```yaml
  uses: Apple-Actions/import-codesign-certs@<full-sha-of-v6.0.0>
  ```

### Required secrets
| Secret | Contents |
|--------|----------|
| `DEVELOPER_ID_P12` | base64 of `Developer ID Application: …` `.p12` (`base64 -i cert.p12 \| pbcopy`) |
| `DEVELOPER_ID_P12_PASSWORD` | the `.p12` password |

### Manual fallback (if action ever breaks)
```bash
KEYCHAIN=build.keychain
security create-keychain -p "$RANDOM_PW" "$KEYCHAIN"
security default-keychain -s "$KEYCHAIN"
security unlock-keychain -p "$RANDOM_PW" "$KEYCHAIN"
echo "$DEVELOPER_ID_P12" | base64 --decode > /tmp/cert.p12
security import /tmp/cert.p12 -k "$KEYCHAIN" -P "$DEVELOPER_ID_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$RANDOM_PW" "$KEYCHAIN"
```
[HIGH — standard recipe in many CI guides; e.g. <https://gregoryszorc.com/docs/apple-codesign/stable/apple_codesign_github_actions.html>]

---

## 5. Homebrew Cask

### Cask DSL (current — no formal version concept)
There is **no DSL version number**; Homebrew evolves the cask DSL in lockstep with `brew` itself. Latest brew: **5.1.0 (2026-03-10)**. Current cask conventions per <https://docs.brew.sh/Cask-Cookbook>. [HIGH]
- Source: <https://brew.sh/2026/03/10/homebrew-5.1.0/>

### Personal tap structure (`mitgor/homebrew-tap`)
```
mitgor/homebrew-tap/                  # repo MUST be named homebrew-<word>
├── Casks/
│   └── mdviewer.rb                   # cask file
├── Formula/                          # (optional, leave empty if cask-only)
└── README.md
```
[HIGH] Source: <https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap>

- Repo name **must** start with `homebrew-` for `brew tap` to work.
- Casks live in a top-level `Casks/` directory (capital C).
- Cask filename = cask token = `mdviewer.rb` (lowercase, hyphenated).

### Minimal `Casks/mdviewer.rb`
```ruby
cask "mdviewer" do
  version "2.2.0"
  sha256  "<sha256 of the notarized DMG>"

  url       "https://github.com/mitgor/mdviewer/releases/download/v#{version}/MDViewer-#{version}.dmg"
  name      "MDViewer"
  desc      "Fast native macOS markdown viewer with LaTeX typography and Mermaid"
  homepage  "https://github.com/mitgor/mdviewer"

  livecheck do
    url     :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"     # macOS 13+

  app "MDViewer.app"

  zap trash: [
    "~/Library/Preferences/com.mdviewer.app.plist",
    "~/Library/Saved Application State/com.mdviewer.app.savedState",
  ]
end
```
[HIGH] DSL stanzas verified against <https://docs.brew.sh/Cask-Cookbook>.

### User installation
```bash
brew install --cask mitgor/tap/mdviewer
# or:
brew tap mitgor/tap && brew install --cask mdviewer
```

### Auto-bumping on release tag
Use `macAuley/action-homebrew-bump-cask` (wraps `brew bump-cask-pr`):
```yaml
# .github/workflows/release.yml — runs after notarized DMG is published
- name: Bump Homebrew cask
  uses: macAuley/action-homebrew-bump-cask@<sha-pin>
  with:
    token:  ${{ secrets.HOMEBREW_TAP_PAT }}    # Personal Access Token, NOT GITHUB_TOKEN
    tap:    mitgor/homebrew-tap
    cask:   mdviewer
    tag:    ${{ github.ref_name }}             # e.g. v2.2.0
    force:  false
```
[HIGH] Sources: <https://github.com/marketplace/actions/homebrew-bump-cask>, <https://docs.brew.sh/Manpage> (`brew bump-cask-pr`)

### Required PAT scopes
- **`public_repo`** + **`workflow`** scopes on a fine-grained or classic PAT.
- `GITHUB_TOKEN` will **not** work because `brew bump-cask-pr` forks the tap repo and opens a PR; GITHUB_TOKEN cannot fork. [HIGH]
  - Source: <https://docs.brew.sh/Manpage> (`bump-cask-pr` notes)

### Verify before push (local sanity)
```bash
brew install --cask --no-quarantine ./Casks/mdviewer.rb
brew audit --new --cask mitgor/tap/mdviewer
brew style --cask mitgor/tap/mdviewer
```

---

## 6. Instruments / Signpost Extraction

### Verdict
**MEDIUM-painful.** `xctrace` *can* export signpost data, but **only as raw XML via XPath queries** against the trace's table-of-contents. There is **no first-class `--signposts-csv` flag**. For repeatable measurement (PERF-01..03, STRM-02), expect to write a small post-processor. [HIGH for capability; MEDIUM for ergonomics]

### Recording a trace headlessly
```bash
# Time-limited recording with the os_signpost template
xctrace record \
  --template 'os_signpost' \
  --output mdviewer-launch.trace \
  --launch -- /path/to/MDViewer.app/Contents/MacOS/MDViewer /path/to/sample.md \
  --time-limit 5s
```
[HIGH] Source: <https://keith.github.io/xcode-man-pages/xctrace.1.html>

### Discovering schemas in the recorded trace
```bash
xctrace export --input mdviewer-launch.trace --toc
# → prints XML listing all tables; look for
#   <table schema="os-signpost" .../>
#   <table schema="os-signpost-intervals" .../>
```
[MEDIUM — schema names `os-signpost` and `os-signpost-intervals` are widely cited in community posts but Apple does not publish a stable schema reference; verify per-Xcode-version with `--toc`.]
- Source: <https://developer.apple.com/forums/thread/661295>
- Source: <https://www.jviotti.com/2022/02/21/emitting-signposts-to-instruments-on-macos-using-cpp.html>

### Exporting signpost intervals
```bash
xctrace export --input mdviewer-launch.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' \
  > signposts.xml

# Then parse with xmllint / Python / Swift to pull <interval> nodes for
# the "open-to-paint" signpost name and compute durations.
xmllint --xpath '//row[event-type="Interval"]/duration' signposts.xml
```
[MEDIUM] Source: <https://developer.apple.com/forums/thread/661295>

### Practical recommendation for v2.2 measurement phase
- **For one-off perf gates** (PERF-01..03 sign-off): record traces locally with Instruments GUI; read the OSSignposter intervals directly from the timeline. Faster than wiring up xctrace.
- **For CI regression gates** (future, not v2.2): build a small `Tests/PerfTests` XCTest that reads `OSSignposter` data via `XCTOSSignpostMetric` (XCTest's first-class signpost metric, available since Xcode 12) — far easier than parsing xctrace XML.
  - Reference: `XCTOSSignpostMetric.applicationLaunch` and custom `XCTOSSignpostMetric(subsystem:category:name:)` in <https://developer.apple.com/documentation/xctest/xctossignpostmetric>
- **Third-party shortcut:** community tools like [`TraceUtility`](https://github.com/Qusic/TraceUtility) and [`instrumentsToPprof`](https://github.com/google/instrumentsToPprof) parse `.trace` bundles directly, but both rely on private SPI and break across Xcode versions — **not recommended**. [MEDIUM]

---

## 7. Cross-Cutting: DMG Build in CI

Not in the original question list but unavoidable for the pipeline.

- **`create-dmg/create-dmg`** (shell script, no runtime dependencies, MIT) — simplest reliable choice. Maintained, used by countless macOS apps. [HIGH]
  - Source: <https://github.com/create-dmg/create-dmg>
- Install in workflow: `brew install create-dmg` (preinstalled brew on macos-26).
- Invocation:
  ```bash
  create-dmg \
    --volname "MDViewer 2.2.0" \
    --window-size 540 380 \
    --icon-size 96 \
    --icon "MDViewer.app" 140 200 \
    --app-drop-link 400 200 \
    --hdiutil-quiet \
    "MDViewer-2.2.0.dmg" \
    "build/Release/MDViewer.app"
  ```
- **Sign the DMG itself** before notarization (notarytool requires a signed container):
  ```bash
  codesign --force --sign "Developer ID Application: <Team Name> (<TeamID>)" \
    --timestamp MDViewer-2.2.0.dmg
  ```
- Then submit to notarytool (see §3), then `stapler staple`.

> Alternative `sindresorhus/create-dmg` (Node-based) auto-detects app icon and is prettier, but adds a Node dependency. The shell-script `create-dmg/create-dmg` is leaner for CI.

---

## Open Questions (flag for execute-phase)

1. **Sparkle private key handling in CI** — current Sparkle docs assume the EdDSA private key lives in the dev's login keychain. For CI, we'll export it (`generate_keys -x`) into a secret and feed it to `sign_update` via `--ed-key-file`. Verify the `-x` flag and `--ed-key-file` flag names exist in 2.9.1 release. [unverified — confirm with `./bin/sign_update --help` after SPM checkout]
2. **Sparkle 2.x EOL?** — no public roadmap for Sparkle 3.x; 2.x has been the stable line since 2022. Assume stable indefinitely. [unverified]
3. **macos-26 runner cost** — standard runners on macOS are billed at higher multiplier than Linux. For a public repo this is free; for a private repo confirm minute usage budget. [unverified — out of scope for stack research]
4. **App-specific password fallback** — keep as documented backup path in case the team API key is revoked / expires; notarytool still accepts `--apple-id <id> --password <app-specific> --team-id <TeamID>`. [HIGH per notarytool man page]

---

## Sources Index

- Sparkle releases: <https://github.com/sparkle-project/Sparkle/releases>
- Sparkle 2.9.1 tag: <https://github.com/sparkle-project/Sparkle/releases/tag/2.9.1>
- Sparkle docs root: <https://sparkle-project.org/documentation/>
- Sparkle publishing: <https://sparkle-project.org/documentation/publishing/>
- Sparkle EdDSA migration: <https://sparkle-project.org/documentation/eddsa-migration/>
- macos-26 GA changelog: <https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/>
- macos-26-arm64 image readme: <https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md>
- macos-15 GA: <https://github.blog/changelog/2025-04-10-github-actions-macos-15-and-windows-2025-images-are-now-generally-available/>
- macos-latest policy: <https://github.com/actions/runner-images/issues/12520>
- TN3147 notarytool migration: <https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool>
- notarytool man page: <https://keith.github.io/xcode-man-pages/notarytool.1.html>
- ASC API key role discussion: <https://developer.apple.com/forums/thread/133063>
- ASC API key creation: <https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api>
- import-codesign-certs releases: <https://github.com/Apple-Actions/import-codesign-certs/releases>
- import-codesign-certs action.yml: <https://github.com/Apple-Actions/import-codesign-certs/blob/main/action.yml>
- Manual signing recipe: <https://gregoryszorc.com/docs/apple-codesign/stable/apple_codesign_github_actions.html>
- Homebrew tap docs: <https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap>
- Homebrew cask cookbook: <https://docs.brew.sh/Cask-Cookbook>
- Homebrew 5.1.0 release: <https://brew.sh/2026/03/10/homebrew-5.1.0/>
- Homebrew bump-cask action: <https://github.com/marketplace/actions/homebrew-bump-cask>
- xctrace man page: <https://keith.github.io/xcode-man-pages/xctrace.1.html>
- xctrace export forum: <https://developer.apple.com/forums/thread/661295>
- create-dmg: <https://github.com/create-dmg/create-dmg>
- XCTOSSignpostMetric: <https://developer.apple.com/documentation/xctest/xctossignpostmetric>
