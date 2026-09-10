// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Passwall",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PasswallCore", targets: ["PasswallCore"]),
        .executable(name: "PasswallMac", targets: ["PasswallMac"])
    ],
    targets: [
        .target(name: "PasswallCore"),
        .executableTarget(
            name: "PasswallMac",
            dependencies: ["PasswallCore"]
        ),
        .testTarget(
            name: "PasswallCoreTests",
            dependencies: ["PasswallCore"]
        ),
        .testTarget(
            name: "PasswallMacTests",
            dependencies: ["PasswallMac"]
        )
    ]
)
