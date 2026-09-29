// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Vigil",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Vigil", targets: ["Vigil"]),
        .library(name: "VigilCore", targets: ["VigilCore"]),
    ],
    targets: [
        // Pure logic + system integration, no UI. Everything testable lives here.
        .target(
            name: "VigilCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        // SwiftUI menu bar app.
        .executableTarget(
            name: "Vigil",
            dependencies: ["VigilCore"],
            linkerSettings: [
                .linkedFramework("Carbon"), // RegisterEventHotKey (global shortcut without Accessibility)
            ]
        ),
        .testTarget(
            name: "VigilTests",
            dependencies: ["VigilCore"],
            // Real hook payloads recorded on this machine (the task parsers are tested against them).
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
