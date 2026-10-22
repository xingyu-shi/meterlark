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
        .executableTarget(
            name: "MeterlarkApp",
            path: "Sources/MeterlarkApp"
        ),
        .testTarget(
            name: "MeterlarkTests",
            dependencies: ["MeterlarkApp"],
            path: "Tests/MeterlarkTests"
        )
    ]
)
