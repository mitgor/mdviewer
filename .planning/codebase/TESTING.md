# Testing Patterns

**Analysis Date:** 2026-04-03

## Test Framework

**Runner:**
- XCTest (Apple's native framework, bundled with Xcode)
- No third-party testing libraries
- Config: Xcode project target `MDViewerTests` defined in `project.yml`

**Assertion Library:**
- XCTest built-in: `XCTAssertTrue`, `XCTAssertFalse`, `XCTAssertEqual`, `XCTAssertNotNil`, `XCTAssertGreaterThan`

**Run Commands:**
```bash
# From Xcode: Cmd+U to run all tests
# From command line:
xcodebuild test -project MDViewer.xcodeproj -scheme MDViewer -destination 'platform=macOS'
```

## Test File Organization

**Location:**
- Separate `MDViewerTests/` directory alongside `MDViewer/` source directory
- Not co-located with source files

**Naming:**
- Test file mirrors source file with `Tests` suffix: `MarkdownRendererTests.swift` tests `MarkdownRenderer.swift`
- `MDViewerTests.swift` is a placeholder file

**Structure:**
```
MDViewerTests/
├── MDViewerTests.swift          # Placeholder (single stub test)
└── MarkdownRendererTests.swift  # Primary test suite (92 lines, 8 tests)
```

## Test Structure

**Suite Organization:**
```swift
import XCTest
@testable import MDViewer

final class MarkdownRendererTests: XCTestCase {

    func testBasicMarkdownRendersToHTML() {
        let renderer = MarkdownRenderer()
        let (chunks, _) = renderer.render(markdown: "# Hello\n\nWorld")
        let joined = chunks.joined()
        XCTAssertTrue(joined.contains("<h1>"))
        XCTAssertTrue(joined.contains("Hello"))
        XCTAssertTrue(joined.contains("<p>World</p>"))
    }
}
```

**Patterns:**
- `final class` for all test classes — no subclassing
- `@testable import MDViewer` to access `internal` types
- No `setUp`/`tearDown` — each test is fully self-contained, creates its own dependencies
- No shared state between tests
- Test function names use `test` prefix followed by a descriptive snake-style phrase: `testBasicMarkdownRendersToHTML`, `testMermaidBlockBecomesPlaceholder`

## Mocking

**Framework:** None — no mocking libraries used (no OCMock, Cuckoo, etc.)

**Patterns:**
- No protocol-based mocking in the existing tests
- Tests exercise real implementations directly
- `MarkdownRenderer` is a pure function-style class (no network/disk I/O in `render(markdown:)`) so mocking is not needed for most test cases
- File I/O tested using `FileManager.default.temporaryDirectory`:

```swift
func testRenderFromFile() {
    let renderer = MarkdownRenderer()
    let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("test.md")
    try! "# File Test\n\nContent".write(to: tmpFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    let template = SplitTemplate(templateHTML: "<body>{{FIRST_CHUNK}}</body>")
    let result = renderer.renderFullPage(fileURL: tmpFile, template: template)
    XCTAssertNotNil(result)
    XCTAssertTrue(result!.page.contains("File Test"))
}
```

**What to mock:**
- If testing `AppDelegate` or `WebContentView` in the future, `WebContentViewDelegate` protocol is suitable for protocol mocking

**What NOT to mock:**
- `MarkdownRenderer` — it is a pure transform, test it directly
- `SplitTemplate` — it is a value type, test it directly

## Fixtures and Factories

**Test Data:**
- Inline string literals for markdown input — no external fixture files
- Minimal inputs that exercise one behavior at a time:

```swift
// Minimal fixture for table rendering
let md = """
| Name | Age |
|------|-----|
| Alice | 30 |
"""

// Generated fixture for chunking threshold test
var md = ""
for i in 0..<100 {
    md += "## Heading \(i)\n\nParagraph \(i) content here.\n\n"
}
```

**Location:**
- All fixtures are inline within test methods, not in separate files

## Coverage

**Requirements:** None enforced — no coverage threshold configured

**View Coverage:**
```bash
# Enable in Xcode: Product > Scheme > Edit Scheme > Test > Code Coverage
# Or via command line:
xcodebuild test -project MDViewer.xcodeproj -scheme MDViewer \
    -destination 'platform=macOS' \
    -enableCodeCoverage YES
```

**Current coverage:**
- `MarkdownRenderer` — well covered (all public methods tested)
- `SplitTemplate` — tested via `testSplitTemplateConcat` and implicitly through `renderFullPage` tests
- `AppDelegate` — no tests
- `MarkdownWindow` — no tests
- `WebContentView` — no tests (requires WKWebView runtime, not unit-testable without a host app)

## Test Types

**Unit Tests:**
- All existing tests are unit tests
- Scope: single class or method in isolation
- Location: `MDViewerTests/`

**Integration Tests:**
- Not present

**E2E Tests:**
- Not used — no UI testing framework (XCUITest) configured

**UI Tests:**
- `WebContentView` and `MarkdownWindow` are not covered — they require WKWebView and AppKit window infrastructure, which are integration/UI-level concerns

## Common Patterns

**Asserting HTML output:**
```swift
let (chunks, _) = renderer.render(markdown: "# Hello\n\nWorld")
let joined = chunks.joined()
XCTAssertTrue(joined.contains("<h1>"))
XCTAssertTrue(joined.contains("<p>World</p>"))
```

**Asserting boolean flags from render:**
```swift
let (_, hasMermaid) = renderer.render(markdown: "# No diagrams here")
XCTAssertFalse(hasMermaid)
```

**Asserting chunking behavior:**
```swift
let (chunks, _) = renderer.render(markdown: md)
XCTAssertGreaterThan(chunks.count, 1, "Large content should be split into multiple chunks")
XCTAssertTrue(chunks[0].contains("Heading 0"))
```

**Temporary file pattern (with cleanup):**
```swift
let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("test.md")
try! "...".write(to: tmpFile, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: tmpFile) }
```

**Error Testing:**
- Not demonstrated in current tests — `renderFullPage(fileURL:)` returning `nil` on bad input is not covered

## Placeholder Tests

`MDViewerTests.swift` contains a single stub that should be replaced when adding new test classes:

```swift
final class MDViewerTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }
}
```

This file can be removed or repurposed for `AppDelegate` integration tests.

---

*Testing analysis: 2026-04-03*
