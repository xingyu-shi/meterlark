// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Meterlark",
    // The Swift source targets 13; the app bundle's runtime minimum is 14 because ccusage requires it.
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Meterlark", targets: ["MeterlarkApp"])
    ],
    targets: [
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"
        ),
        .executableTarget(
            name: "MeterlarkApp",
            dependencies: ["Sparkle"],
            path: "Sources/MeterlarkApp",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "MeterlarkTests",
            dependencies: ["MeterlarkApp"],
            path: "Tests/MeterlarkTests"
        )
    ]
)
