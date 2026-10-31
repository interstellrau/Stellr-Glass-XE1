// swift-tools-version:5.9
// tools/swift-check: builds the iPhone app's Foundation-only Core (copied in by run.sh
// from ios/GlassBridge/Core) into the `gbcheck` executable and checks it against the
// Python reference (tools/make_test_stream.py). Swift 5 language mode, like the app.
import PackageDescription

let package = Package(
    name: "swift-check",
    targets: [
        .executableTarget(
            name: "gbcheck",
            path: "Sources/gbcheck"
        )
    ],
    swiftLanguageVersions: [.v5]
)
