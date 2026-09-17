// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentAim",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AgentAim", targets: ["AgentAim"]),
        .executable(name: "AgentAimHook", targets: ["AgentAimHook"])
    ],
    targets: [
        .target(name: "AgentAimCore"),
        .executableTarget(name: "AgentAim", dependencies: ["AgentAimCore"]),
        .executableTarget(name: "AgentAimHook", dependencies: ["AgentAimCore"]),
        .testTarget(name: "AgentAimCoreTests", dependencies: ["AgentAimCore"])
    ]
)
