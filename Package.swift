// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Followup",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "FollowupCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Followup",
            dependencies: ["FollowupCore"]
        ),
        .testTarget(
            name: "FollowupCoreTests",
            dependencies: ["FollowupCore"]
        ),
    ]
)
