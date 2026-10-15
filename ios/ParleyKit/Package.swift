// swift-tools-version: 6.0
// ParleyKit: the app's logic, kept out of the app target so it is unit tested
// with `swift test` on macOS: the relay's API models and client, the event
// stream parser, timings decoding, the highlight cursor and the playback state
// machine. Pure Foundation: no UIKit, AVFoundation or SwiftData here.
import PackageDescription

let package = Package(
    name: "ParleyKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ParleyKit", targets: ["ParleyKit"]),
    ],
    targets: [
        .target(name: "ParleyKit"),
        .testTarget(name: "ParleyKitTests", dependencies: ["ParleyKit"]),
    ],
    swiftLanguageModes: [.v5]
)
