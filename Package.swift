// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pier",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Pier", targets: ["Pier"]),
    ],
    targets: [
        .target(
            name: "PierKit",
            path: "Sources/PierKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "Pier",
            dependencies: ["PierKit"],
            path: "Sources/Pier",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PierKitTests",
            dependencies: ["PierKit"],
            path: "Tests/PierKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
