// swift-tools-version:5.9
import Foundation
import PackageDescription

// Delivers the iOS Rust artifact — libflextunnel.xcframework (built by the
// sibling repo's build-ios.sh, released as libflextunnel-ios.xcframework.zip) —
// as a Swift package binary target. The app (this repo) references this package
// by local path, so it always uses this manifest; there is no vendored copy.
//
// Default: download the pinned release zip by URL + checksum (reproducible).
// Bump both when moving to a new release (scripts/bump-xcframework.sh <tag>).
//
// Local FFI dev: set FLEXTUNNEL_LOCAL_XCFRAMEWORK to link a locally built
// xcframework instead of the release. SPM forbids binary-target paths outside
// the package root, so the local build is reached through the committed relative
// symlink local/libflextunnel.xcframework -> ../flextunnel/dist/ios. Set the var
// to "1" to use that symlink, or to another path relative to this package dir:
//   FLEXTUNNEL_LOCAL_XCFRAMEWORK=1 xcodegen generate && ... xcodebuild ...

func localBinaryTarget() -> Target? {
    guard let value = ProcessInfo.processInfo.environment["FLEXTUNNEL_LOCAL_XCFRAMEWORK"],
          !value.isEmpty else { return nil }
    let path = (value == "1" || value == "true") ? "local/libflextunnel.xcframework" : value
    return .binaryTarget(name: "libflextunnel", path: path)
}

let binaryTarget = localBinaryTarget() ?? .binaryTarget(
    name: "libflextunnel",
    url: "https://github.com/andrewtheguy/flextunnel/releases/download/v0.0.49/libflextunnel-ios.xcframework.zip",
    checksum: "fd49507818f157404f220193093e21f6b922608fd352715545d3acb609445e77"
)

let package = Package(
    name: "Flextunnel",
    products: [
        .library(name: "libflextunnel", targets: ["libflextunnel"]),
    ],
    targets: [binaryTarget]
)
