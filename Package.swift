// swift-tools-version:5.9
// MDViewer SPM manifest — exists solely to declare external package
// dependencies for the Xcode project. cmark-gfm remains vendored under
// Vendor/cmark-gfm/ and is NOT declared here. Xcode's SPM integration
// resolves this manifest when `xcodebuild -resolvePackageDependencies`
// runs, producing Package.resolved in the xcworkspace.
//
// Sparkle 2.9.1+ pinned with upToNextMajor (patch and minor updates
// inside 2.x accepted; a future 3.0 requires explicit planning — see
// .planning/phases/12-sparkle-auto-update-integration/12-RESEARCH.md §Standard Stack).
import PackageDescription

let package = Package(
    name: "MDViewerDeps",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            .upToNextMajor(from: "2.9.1")
        )
    ]
)
