// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Monitr",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CMonitr",
            path: "Sources/CMonitr",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        // Pure logic with no UI, covered by MonitrCoreTests.
        .target(name: "MonitrCore", path: "Sources/MonitrCore"),
        .testTarget(name: "MonitrCoreTests", dependencies: ["MonitrCore"], path: "Tests/MonitrCoreTests"),
        // The XPC contract between the app and its root helper.
        .target(name: "MonitrShared", path: "Sources/MonitrShared"),
        .executableTarget(
            name: "Monitr",
            dependencies: ["CMonitr", "MonitrShared", "MonitrCore"],
            path: "Sources/Monitr",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        // Read-only root helper: CPU, memory and energy for processes the app cannot read.
        .executableTarget(
            name: "MonitrHelper",
            dependencies: ["MonitrShared"],
            path: "Sources/MonitrHelper",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
    ],
    swiftLanguageModes: [.v5]
)
