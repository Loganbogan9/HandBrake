# Build the iOS/iPadOS app on a Mac

These instructions build the native iPhone/iPad app from
[Loganbogan9/HandBrake, branch `codex/ios-port`](https://github.com/Loganbogan9/HandBrake/tree/codex/ios-port).
Build the HandBrake engine first, then open the iOS Xcode project.

**Status:** this port has passed portable source/build-rule checks, but its
engine, app and native tests have not yet been compiled or run with Xcode.
This is a first test build; compiler or linker fixes may still be needed.

## 1. Set up Xcode

You need a Mac with full **Xcode 16 or newer** and a macOS version supported by
that Xcode release. The app targets **iOS/iPadOS 17 or newer**. Use a native
Terminal session: `uname -m` should print `arm64` on Apple Silicon or `x86_64`
on Intel. On Apple Silicon, turn off Terminal's **Open using Rosetta** option.

Install [Xcode from Apple](https://developer.apple.com/xcode/), open it once,
complete its initial setup and accept the license. Install iOS platform support
and an iOS Simulator runtime in **Xcode > Settings > Components** (called
**Platforms** in some versions). A standalone Command Line Tools installation
does not provide everything this build needs.

In Terminal, select your Xcode installation and check the SDKs:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path
xcrun --sdk iphonesimulator --show-sdk-path
xcrun --sdk iphoneos metal --version
xcrun --sdk iphonesimulator metal --version
```

If Xcode is installed elsewhere, change the path in the first command.
If a Metal check reports a missing toolchain, install **Metal Toolchain** in
Xcode's Components settings. On versions that support it, the equivalent is:

```sh
xcodebuild -downloadComponent metalToolchain
```

Then repeat the Metal checks. See Apple's
[component installation instructions](https://developer.apple.com/documentation/Xcode/downloading-and-installing-additional-xcode-components).

## 2. Install the build tools

Install [Homebrew](https://brew.sh/) if needed and follow its instructions to
add `brew` to your shell's PATH. Then run:

```sh
brew install python autoconf automake libtool pkg-config cmake meson ninja nasm
python3 --version
```

Python 3.9 or newer is required. The engine script downloads and builds the
pinned HandBrake dependencies itself, checking their SHA256 hashes. You do
not need to install HandBrake or FFmpeg with Homebrew. Keep enough free disk
space for Xcode, simulator runtimes and multiple native dependency builds;
the first build downloads and compiles substantial source code.

## 3. Clone the port

Run these commands in Terminal. Keep the checkout and build paths free of
spaces; HandBrake's make rules require this.

```sh
mkdir -p "$HOME/Developer"
cd "$HOME/Developer"
git clone --branch codex/ios-port --single-branch https://github.com/Loganbogan9/HandBrake.git HandBrake-iOS
cd HandBrake-iOS
git rev-parse --short HEAD
```

Use this fork and branch so the clone includes the iOS sources. All remaining
Terminal commands are run from the `HandBrake-iOS` repository root.

## 4. Build the native engine

```sh
mkdir -p ios/build
set -o pipefail
python3 ios/scripts/build-engine.py --jobs 4 --simulator-arch "$(uname -m)" 2>&1 | tee ios/build/engine-build.log
```

This builds **arm64 for physical devices** and a simulator slice matching your
Mac, then packages them together. The explicit simulator option matters on
Intel: the script's default simulator architecture is arm64. Lower `--jobs`
to `2` if compilation runs out of memory.

Continue only after the command succeeds and prints `Created ...HandBrakeEngine.xcframework`.
It produces both of these, which the app project requires:

```text
ios/Artifacts/HandBrakeEngine.xcframework
ios/Artifacts/HandBrakeEngine-Licenses/
```

The generated binaries are not included in Git. Opening the Xcode project
alone does not build them. Keep the license directory beside the framework.

## 5. Compile the app without signing

This checks device compilation before setting up an Apple account or device:

```sh
set -o pipefail
xcodebuild -project ios/HandBrakeIOS.xcodeproj -scheme HandBrakeIOS -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ios/build/DeviceDerivedData \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee ios/build/device-build.log
```

Success ends with `BUILD SUCCEEDED`. The app is under
`ios/build/DeviceDerivedData/Build/Products/Debug-iphoneos/HandBrakeIOS.app`.
This unsigned build cannot be installed directly on an iPhone or iPad; use
the signing steps below for installation.

## 6. Run in the simulator and run the tests

```sh
open ios/HandBrakeIOS.xcodeproj
```

In Xcode, select the **HandBrakeIOS** scheme and a specific iPhone or iPad
simulator running iOS/iPadOS 17 or later. Choose **Product > Run** (`Command-R`)
to launch it. Simulator runs do not need an Apple signing account.

Choose **Product > Test** (`Command-U`) to run the included tests. The native
engine tests scan the bundled one-second sample, encode H.264/AAC MP4 through
libhb and inspect the real output. Hardware encoding tests may be skipped
when the selected simulator does not advertise the required encoder.

To save a test result bundle from Terminal, list the available simulators:

```sh
xcrun simctl list devices available
```

Replace `PASTE_SIMULATOR_UUID_HERE` with an available iPhone/iPad simulator's
UUID from that list. Use an installed iOS runtime version 17 or later:

```sh
SIMULATOR_ID="PASTE_SIMULATOR_UUID_HERE"
set -o pipefail
xcodebuild -project ios/HandBrakeIOS.xcodeproj -scheme HandBrakeIOS -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath ios/build/SimulatorDerivedData \
  -resultBundlePath "ios/build/EngineTests-$(date +%Y%m%d-%H%M%S).xcresult" \
  CODE_SIGNING_ALLOWED=NO test 2>&1 | tee ios/build/simulator-tests.log
```

Success ends with `TEST SUCCEEDED`. The timestamp gives each run a new result
bundle; Xcode will not overwrite an existing `.xcresult` destination.

## 7. Install on an iPhone or iPad

1. Connect a device running iOS/iPadOS 17 or newer. Unlock it and trust the Mac
   when prompted. Xcode must support the device's installed OS version.
2. Sign into your Apple account in **Xcode > Settings > Apple Accounts**
   (or **Accounts** in older versions).
3. Select the project in Xcode, then the **HandBrakeIOS** target. Under
   **Signing & Capabilities**, enable **Automatically manage signing**, select
   your team and change the bundle identifier to something unique, such as
   `com.yourname.handbrakeios`. Xcode can use a Personal Team for development.
4. If running tests on the device, configure the **HandBrakeIOSTests** target
   with the same team and a unique test bundle ID, such as
   `com.yourname.handbrakeios.tests`.
5. Enable **Settings > Privacy & Security > Developer Mode** on the device
   when required, following its restart and confirmation prompts.
6. Select that device as the run destination and press `Command-R`.

Apple documents [device signing and running](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)
and [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

For a first manual check, import a short local video from Files, choose an
available software H.264 encoder, AAC audio and MP4, start the job, then play
and export its completed output. Keep the app in the foreground: backgrounding
currently cancels the active job, which can be restarted from the beginning.
Test pause/resume/cancel and VideoToolbox separately on the device.
Hardware encoding is exposed only when available on iOS 17.4 or later;
simulator success does not establish device hardware support.

## If the build fails

| Symptom | Next step |
| --- | --- |
| `xcodebuild` requires Xcode, or an SDK cannot be found | Select full Xcode in step 1 and install its iOS components. |
| `metal` cannot be found or executed | Install the Metal Toolchain for the selected Xcode and repeat the checks. |
| A build tool is missing | Repeat step 2 and check that Homebrew is on PATH. |
| Framework or engine license notices are missing | Complete step 4; both generated artifacts are required. |
| Device and simulator architecture/platform mismatch | Rebuild with the simulator architecture matching the Mac. Device arm64 and simulator arm64 are different platforms. |
| `Build configuration changed ... use a fresh --build-root` | Use a new build directory as shown below. |
| No available simulator or destination | Install an iOS simulator runtime and select a concrete compatible simulator. |
| Signing team, profile or bundle ID error | Follow step 7. For a compilation check alone, use step 5. |
| Compiler/linker error in source | Send the full log and first actual error; this port still needs its first verified Apple build. |

After changing Xcode/SDKs, the deployment target, contrib patches or build
configuration, use a new engine build directory. This keeps previous build
files available for diagnosis:

```sh
set -o pipefail
python3 ios/scripts/build-engine.py --jobs 4 --simulator-arch "$(uname -m)" \
  --build-root "ios/build/engine-$(date +%Y%m%d-%H%M%S)" \
  2>&1 | tee ios/build/engine-rebuild.log
```

For help, send the Git commit (`git rev-parse HEAD`), `xcodebuild -version`,
`uname -m`, the full failing command and its log. For test failures, also send
the `.xcresult` bundle. Engine configuration logs and per-target manifests are
under the chosen build root, by default `ios/build/engine/`.

## Optional engine commands

These are alternatives to step 4, not prerequisites for the normal build:

```sh
# Inspect targets and dependencies without compiling.
python3 ios/scripts/build-engine.py --plan

# Run compiler/configuration probes without building the engine.
python3 ios/scripts/build-engine.py --configure-only --simulator-arch "$(uname -m)"

# Build device only; this artifact cannot run simulator tests.
python3 ios/scripts/build-engine.py --device-only --jobs 4

# Package both simulator architectures, plus the device slice.
python3 ios/scripts/build-engine.py --simulator-arch arm64 --simulator-arch x86_64 --jobs 4
```

The initial build disables optional x265, Rust libdovi and nonfree FDK-AAC.
Software H.264 uses x264; AAC uses the FFmpeg encoder. HEVC encoding uses
VideoToolbox when available. HandBrake's GPL and dependency licenses apply;
preserve the generated notices and corresponding source when distributing
builds. See [README.md](README.md) for the port's current capabilities and
validation status.
