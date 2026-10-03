// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ntfyx",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "ntfyx",
            targets: ["ntfyx"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .executableTarget(
            name: "ntfyx",
            dependencies: ["Yams"],
            path: "Sources",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "ntfyxTests",
            dependencies: ["ntfyx", "Yams"],
            path: "Tests/ntfyxTests",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
