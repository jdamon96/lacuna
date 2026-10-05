// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lacuna",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Lacuna", targets: ["Lacuna"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "LacunaCore"),
        .executableTarget(name: "Lacuna", dependencies: ["LacunaCore", .product(name: "Sparkle", package: "Sparkle")], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("Carbon"),
            .linkedFramework("ApplicationServices"), .linkedFramework("Security"),
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
        ]),
        .testTarget(name: "LacunaCoreTests", dependencies: ["LacunaCore"])
    ]
)
