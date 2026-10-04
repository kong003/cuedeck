// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CueDeck",
    platforms: [.macOS(.v13)],
    targets: [
        // Real-time mixer in C: lock-free ring buffers, routing, fades.
        .target(
            name: "CMixer",
            path: "Sources/CMixer"
        ),
        // Catches Objective-C exceptions from AVFoundation so a bad file
        // shows an error instead of quitting the app.
        .target(
            name: "ObjCSupport",
            path: "Sources/ObjCSupport"
        ),
        .executableTarget(
            name: "CueDeck",
            dependencies: ["CMixer", "ObjCSupport"],
            path: "Sources/CueDeck",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ]
)
