// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lacuna",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Lacuna", targets: ["Lacuna"])],
    targets: [
        .target(name: "LacunaCore"),
        .executableTarget(name: "Lacuna", dependencies: ["LacunaCore"], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("Carbon"),
            .linkedFramework("ApplicationServices"), .linkedFramework("Security")
        ]),
        .testTarget(name: "LacunaCoreTests", dependencies: ["LacunaCore"])
    ]
)
