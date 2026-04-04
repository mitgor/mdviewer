// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MDViewerDeps",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-cmark.git", branch: "gfm"),
    ],
    targets: [
        .target(name: "MDViewerDeps", dependencies: [
            .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
        ]),
    ]
)
