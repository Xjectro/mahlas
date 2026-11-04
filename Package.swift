// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Mahlas",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Mahlas", targets: ["Mahlas"])
    ],
    targets: [
        .executableTarget(
            name: "Mahlas",
            path: "Sources/Mahlas",
            resources: [
                .copy("Resources/Fonts")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
