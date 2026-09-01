// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WaypointCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WaypointCore", targets: ["WaypointCore"]),
        .library(name: "WaypointMitmEngine", targets: ["WaypointMitmEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        .target(name: "WaypointCore"),
        .target(
            name: "WaypointMitmEngine",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .testTarget(
            name: "WaypointCoreTests",
            dependencies: ["WaypointCore", "WaypointMitmEngine"]
        ),
    ]
)
