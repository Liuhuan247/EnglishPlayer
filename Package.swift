// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EnglishPlayer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EnglishPlayer", targets: ["EnglishPlayer"])
    ],
    targets: [
        .target(
            name: "EnglishPlayerKit",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "EnglishPlayer",
            dependencies: ["EnglishPlayerKit"]
        ),
        .testTarget(
            name: "EnglishPlayerKitTests",
            dependencies: ["EnglishPlayerKit"]
        )
    ]
)
