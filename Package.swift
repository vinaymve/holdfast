// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Holdfast",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Holdfast", targets: ["Holdfast"]),
        .executable(name: "holdfastd", targets: ["holdfastd"]),
        .executable(name: "holdfast-cli", targets: ["holdfast-cli"]),
        .library(name: "HoldfastCore", targets: ["HoldfastCore"]),
    ],
    targets: [
        // Shared engine: parsing, hosts/pf blocking, schedules, app blocking, XPC.
        .target(name: "HoldfastCore"),
        // Root launchd daemon that owns the block and enforces it.
        .executableTarget(name: "holdfastd", dependencies: ["HoldfastCore"]),
        // Command-line front end.
        .executableTarget(name: "holdfast-cli", dependencies: ["HoldfastCore"]),
        // SwiftUI app.
        .executableTarget(name: "Holdfast", dependencies: ["HoldfastCore"]),
        .testTarget(name: "HoldfastCoreTests", dependencies: ["HoldfastCore"]),
    ]
)
