// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-2.0-or-later

import PackageDescription

// Experimental xtool/SwiftPM frontend. Build the real engine XCFramework with
// ios/scripts/build-engine.py on macOS first, then copy Artifacts to this host.
// The existing Xcode project remains the device/simulator validation path.
let package = Package(
    name: "HandBrakeIOS",
    platforms: [.iOS(.v17)],
    products: [
        // xtool selects an automatic library product and wraps it as an app.
        .library(name: "HandBrakeIOS", targets: ["HandBrakeIOS"]),
    ],
    targets: [
        .binaryTarget(
            name: "HandBrakeEngine",
            path: "Artifacts/HandBrakeEngine.xcframework"
        ),
        .target(
            name: "HBEngineBridge",
            dependencies: ["HandBrakeEngine"],
            path: "Bridge",
            exclude: ["HandBrakeIOS-Bridging-Header.h"],
            sources: ["HBEngine.mm"],
            publicHeadersPath: ".",
            cxxSettings: [.unsafeFlags(["-fobjc-arc", "-fblocks"])],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("Accelerate"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("c++"),
                .linkedLibrary("iconv"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
            ]
        ),
        .target(
            name: "HandBrakeIOS",
            dependencies: ["HBEngineBridge"],
            path: ".",
            exclude: [
                "Artifacts", "Bridge", "Tests", "scripts", "build",
                "HandBrakeIOS.xcodeproj", "Info.plist", "xtool-Info.plist",
                "xtool.yml", "README.md", "BUILDING.md", "WINDOWS.md",
            ],
            sources: ["App", "Core"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("UIKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("Security"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
