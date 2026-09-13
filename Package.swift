// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentAim",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AgentAim", targets: ["AgentAim"])
    ],
    targets: [
        .executableTarget(name: "AgentAim")
    ]
)
