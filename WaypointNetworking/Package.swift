// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WaypointNetworking",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "WaypointNetworking", targets: ["WaypointNetworking"])
    ],
    targets: [
        .target(name: "WaypointNetworking")
    ]
)
