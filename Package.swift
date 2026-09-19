// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Samovar",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SamovarCore", targets: ["SamovarCore"]),
        .executable(name: "samovar", targets: ["samovar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "SamovarCore"),
        .executableTarget(
            name: "samovar",
            dependencies: [
                "SamovarCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "SamovarCoreTests", dependencies: ["SamovarCore"]),
    ]
)
