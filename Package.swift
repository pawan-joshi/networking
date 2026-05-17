// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Networking",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        // Production library — link this into the app targets.
        .library(
            name: "Networking",
            targets: ["Networking"]
        ),
        // Testing helpers (MockURLProtocol, MockHTTPClient).
        // Link this into your app's unit-test target only.
        .library(
            name: "NetworkTesting",
            targets: ["NetworkTesting"]
        ),
    ],
    targets: [
        .target(
            name: "Networking"
        ),
        .target(
            name: "NetworkTesting",
            dependencies: ["Networking"]
        ),
        .testTarget(
            name: "NetworkTests",
            dependencies: [
                "Networking",
                "NetworkTesting",
            ]
        ),
    ]
)
