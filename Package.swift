// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Chores",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "chores", targets: ["chores"]),
        .executable(name: "ChoresApp", targets: ["ChoresApp"]),
    ],
    targets: [
        .target(name: "ChoresKit"),
        .executableTarget(name: "chores", dependencies: ["ChoresKit"]),
        .executableTarget(name: "ChoresApp", dependencies: ["ChoresKit"], resources: [.process("Resources")]),
        .testTarget(name: "ChoresKitTests", dependencies: ["ChoresKit"]),
    ]
)
