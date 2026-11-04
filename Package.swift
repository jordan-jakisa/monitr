// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Monitr",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CMonitr",
            path: "Sources/CMonitr",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "Monitr",
            dependencies: ["CMonitr"],
            path: "Sources/Monitr",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
