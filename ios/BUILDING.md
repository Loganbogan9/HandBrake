# Building the native iOS engine and app

For the experimental Windows/WSL app packaging path, see [WINDOWS.md](WINDOWS.md).
The native engine build described below currently requires macOS.

The engine build uses this checkout's `make/configure.py`, `libhb`, pinned
`contrib` releases and existing HandBrake patches. It does not invoke
HandBrakeCLI at runtime. An Apple build and real-device transcoding have **not**
been completed on the original Windows implementation host. Portable tests
are separate from the Apple compilation and runtime checks below.

## Requirements

Use a Mac with full Xcode 16 or newer, the iOS and iOS Simulator SDKs, Python 3.9 or newer,
and the normal HandBrake contrib tools. Select the intended Xcode installation:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path
xcrun --sdk iphonesimulator --show-sdk-path
brew install autoconf automake libtool pkg-config cmake meson ninja nasm
```

Homebrew's `glibtool` may be needed by dependencies' Autoconf bootstrap;
`autoreconf` normally discovers it automatically on macOS. Apple's `libtool`
is used specifically to merge static archives. The script reports missing
tools and stops on compilation, link or platform-verification failures.
Keep the repository and build/output paths free of whitespace because the
upstream make rules use whitespace-separated paths. Downloads are verified
against HandBrake's pinned SHA256 values.

## Engine build

From the repository root:

```sh
python3 ios/scripts/build-engine.py --jobs 8
```

This builds arm64 device and arm64 simulator slices and writes
`ios/Artifacts/HandBrakeEngine.xcframework`. To include Intel Mac simulators:

```sh
python3 ios/scripts/build-engine.py --simulator-arch arm64 --simulator-arch x86_64
```

Useful limited checks:

```sh
# Works on Windows/Linux too; shows the targets and dependency closure only.
python3 ios/scripts/build-engine.py --plan
# On a Mac, run the actual compiler/configuration probes without compilation.
python3 ios/scripts/build-engine.py --configure-only
# Build one device slice when a simulator is not needed.
python3 ios/scripts/build-engine.py --device-only
```

Each target gets a separate directory under `ios/build/engine`. Compiler
wrappers carry the clang target and SDK to Autoconf, FFmpeg and assembler
invocations. Meson receives a cross file with target executables disabled;
CMake receives an iOS toolchain. `bin2c`, a program executed while embedding
Metal shaders, is compiled for the build Mac. Metal shaders use the selected
iOS SDK and iOS Metal language standard. The application embeds the engine
and never executes target build helpers.

The default port retains x264, FFmpeg codecs/containers/filters, libass,
subtitle libraries, VP8/VP9, dav1d, SVT-AV1, Opus, Vorbis, Theora and LAME.
Optional x265, Rust libdovi and nonfree FDK-AAC are disabled for the initial
reproducible build. AAC uses HandBrake's FFmpeg AAC encoder; Apple AudioToolbox
remains available through the engine. Runtime capability detection controls
which VideoToolbox encoders are shown. Some preset features can therefore be
unavailable and must be reported by the application.

The static dependency closure comes from target-only `pkg-config --static`,
rather than importing host Homebrew libraries. Every archive member is checked
for architecture and Apple platform metadata. LTO is disabled so archives contain
inspectable Mach-O objects. A native iOS link smoke program
references engine initialization/session creation/cleanup and must link before
packaging. This program is not executed by the build script. Device arm64 and
simulator arm64 are packaged separately; only simulator architectures are
combined with `lipo`.

The public headers include `handbrake/handbrake.h`, generated HandBrake feature
headers and dependency headers. App linking needs Foundation, CoreFoundation,
CoreGraphics, CoreText, AudioToolbox, VideoToolbox, CoreMedia, CoreVideo,
IOSurface, Metal, Accelerate, QuartzCore, and `c++`, `iconv`, `z`, `bz2`.
Source notices are preserved beside the framework in
`ios/Artifacts/HandBrakeEngine-Licenses`. Preserve GPL and dependency notices
when distributing source or binaries; this repository's licensing applies.

Build identity checks prevent reuse of stale contrib objects after an SDK,
compiler, deployment-target, build-script, contrib configuration or patch change.
Use a fresh `--build-root` in that case. Deleting the
generated `ios/build/engine` directory also starts a clean build. A previous
XCFramework is kept until its replacement has been successfully packaged.

## Application and real engine tests

Open `ios/HandBrakeIOS.xcodeproj` and select the shared `HandBrakeIOS` scheme.
For a physical iPhone/iPad, select your team and a unique bundle identifier in
Xcode, choose the device, and run. The application requires iOS 17 or later.
Unsigned compilation can be checked independently of device installation:

```sh
xcodebuild -project ios/HandBrakeIOS.xcodeproj -scheme HandBrakeIOS \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

For simulator tests, choose an installed iPhone simulator:

```sh
xcrun simctl list devices available
xcodebuild -project ios/HandBrakeIOS.xcodeproj -scheme HandBrakeIOS \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  CODE_SIGNING_ALLOWED=NO -resultBundlePath ios/build/EngineTests.xcresult test
```

`HandBrakeIOSTests/HBEngineTests` scans the bundled video using libhb, transcodes
to H.264/AAC MP4 using the native bridge, and probes the actual result with
AVFoundation for playable video/audio tracks and duration. These tests require
the engine framework and a running simulator. The fixture contains an original
one-second test pattern and tone; it is not a mocked output. Tests also cover
unavailable encoder and missing-source errors. Run import/export, long jobs,
pause/resume/cancel, background interruption, security-scoped Files access,
thermal throttling and hardware encoding on physical devices before release.
The simulator software encoder test does not prove device VideoToolbox support.
Additional integration tests transcode with H.264 and HEVC VideoToolbox only
when the runtime advertises them, and check that hardware encoders are hidden
below iOS 17.4. Those checks are also pending execution on an Apple host.

Portable validation (no Apple SDK required):

```sh
python3 -m unittest discover -s ios/Tests -p 'test_*.py' -v
python3 -m py_compile make/configure.py ios/scripts/build-engine.py
python3 libhb/tests/test_vt_error.py
python3 libhb/tests/test_resume.py
# On a host with a C compiler:
mkdir -p ios/build
cc -std=c11 -Wall -Wextra -Werror ios/Tests/test_job_policy.c -lm -o ios/build/test-job-policy
ios/build/test-job-policy
```

The GitHub Actions iOS workflow performs the engine build, unsigned device app
build and simulator tests. It is a reproducible validation path; adding it does
not imply that it has already run successfully.
