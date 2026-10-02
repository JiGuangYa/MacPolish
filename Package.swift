// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacPolish",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "MacPolish",
            targets: ["MacPolish"]
        ),
        .executable(
            name: "MacPolishVerification",
            targets: ["MacPolishVerification"]
        ),
        .executable(
            name: "MacPolishWindowVerification",
            targets: ["MacPolishWindowVerification"]
        )
    ],
    targets: [
        .target(
            name: "MacPolishKit",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "MacPolish",
            dependencies: ["MacPolishKit"]
        ),
        .executableTarget(
            name: "MacPolishVerification",
            dependencies: ["MacPolishKit"]
        ),
        .executableTarget(
            name: "MacPolishWindowVerification",
            dependencies: ["MacPolishKit"]
        )
    ]
)
