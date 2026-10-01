// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ntfy-macos",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "ntfy-macos",
            targets: ["ntfy-macos"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .executableTarget(
            name: "ntfy-macos",
            dependencies: ["Yams"],
            path: "Sources",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "ntfy-macosTests",
            dependencies: ["ntfy-macos", "Yams"],
            path: "Tests/ntfy-macosTests",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
