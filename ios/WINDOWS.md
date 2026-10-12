# Windows and WSL with xtool

[xtool](https://github.com/xtool-org/xtool) provides a useful app build path from
Windows **through WSL**. Its SwiftPM pipeline can compile and package SwiftUI
apps against an extracted Apple SDK. Its Linux linker/archive tools and
SwiftPM binary-target handling can consume the prebuilt HandBrake engine.
This is an **experimental, uncompiled build path** for this port.

The checked-in `Package.swift` uses the same App/Core Swift sources and
Objective-C++ bridge as the Xcode target. `xtool.yml` adds the app metadata and
license resources. `xtool-Info.plist` contains literal values, since Xcode's
`$(PRODUCT_BUNDLE_IDENTIFIER)` and other build-setting placeholders are not
appropriate for xtool packaging.

## What it does and does not provide

The existing `build-engine.py` still builds on macOS. It invokes `xcrun`,
compiles HandBrake's Metal shaders and uses Apple archive tools. xtool's
Linux Darwin toolset supplies a linker and archive utilities, but does not
supply the Metal shader compiler or automatically port HandBrake's contrib
build. A full source build of the engine in WSL remains additional work.

The immediate path is:

1. Build `ios/Artifacts/HandBrakeEngine.xcframework` and its sibling
   `HandBrakeEngine-Licenses` directory on a Mac using [BUILDING.md](BUILDING.md),
   or obtain those artifacts after a successful run of the included macOS CI workflow.
2. Set up the supported Linux Swift toolchain and xtool in WSL using the
   [official installation guide](https://github.com/xtool-org/xtool/blob/main/Documentation/xtool.docc/Installation-Linux.md).
3. Download the Xcode `.xip` version required by your xtool release from
   [Apple Developer downloads](https://developer.apple.com/download/all/?q=Xcode).
   This requires the user's Apple login and acceptance of Apple's terms.
4. Install the extracted SDK and build the app from the `ios` directory:

   ```sh
   xtool sdk install /path/to/Xcode.xip
   swift sdk list
   cd /path/to/HandBrake-1.11.2/ios
   xtool dev build
   ```

The unsigned build command does not require xtool signing authentication.
Installing on an iPhone/iPad additionally requires device connectivity and
valid signing/provisioning. For the public Apple API route, use xtool's API-key
authentication option with the applicable Apple Developer account; the documented
password-based route uses private service APIs and is not part of this workflow.
Follow the official installation instructions for WSL USB/device connectivity.

The app builds against the actual HandBrake archive. Missing engine artifacts
or SDKs are build errors; no engine replacement or fake encoding output is used.
Xcode's XCTest/device/simulator validation remains the primary build workflow
to run before release. A cross-compiled simulator slice cannot run an
iOS Simulator on Windows.

## Current verification

The original host has WSL and GCC, but no installed Swift/xtool Apple SDK and
no Xcode `.xip` archive. Consequently, neither `swift package` manifest evaluation
nor `xtool dev build` has been run here. Package grammar, plist/resources and
source references can be checked independently; these do not prove compilation
or runtime compatibility.

xtool source inspection used commit
`d802c719e43fb2d66a7c7879f7dff75bfdd96a27`. Relevant primary sources are
[its SDK installer](https://github.com/xtool-org/xtool/blob/d802c719e43fb2d66a7c7879f7dff75bfdd96a27/Sources/XToolSupport/SDKCommand.swift),
[its app packer](https://github.com/xtool-org/xtool/blob/d802c719e43fb2d66a7c7879f7dff75bfdd96a27/Sources/PackLib/Packer.swift), and
[Linux Darwin tools](https://github.com/xtool-org/darwin-tools-linux-llvm).
