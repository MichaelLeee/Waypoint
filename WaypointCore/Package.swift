// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WaypointCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "WaypointCore", targets: ["WaypointCore"])
    ],
    targets: [
        .target(name: "WaypointCore"),
        .testTarget(
            name: "WaypointCoreTests",
            dependencies: ["WaypointCore"]
        )
    ]
)
