// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CursorStatusBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "CursorStatusBar",
            path: "Sources/CursorStatusBar",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
