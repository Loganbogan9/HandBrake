# HandBrake for iOS and iPadOS

This directory contains an implementation of an in-process `libhb` iOS port
for the **HandBrake 1.11.2** checkout (commit
`9eb6c936803e8b071035b1a77662cb0db58441ea`). It targets iOS 17, iPhone and iPad.
The Windows development host has no Apple SDK, Xcode, or Swift compiler.
**The iOS engine, app, and native integration tests have not been compiled or
run here. This is not yet a verified functional iOS release.**

See [BUILDING.md](BUILDING.md) for the engine, Xcode, simulator and device
commands. Open `HandBrakeIOS.xcodeproj` after building the engine artifact.
An experimental SwiftPM/xtool app path for Windows through WSL is documented
in [WINDOWS.md](WINDOWS.md). It still needs an Apple SDK and a prebuilt native
engine artifact; it has not been compiled here.

## Engine architecture

The existing macOS `HBCore.m` initializes libhb, creates sessions, calls
`hb_scan`, and polls `hb_get_state`. Its `HBJob+HBJobConversion.m` translates GUI
settings into native jobs, then submits them with `hb_add` and `hb_start`.
The CLI demonstrates the preset path through `hb_preset_job_init` and native
JSON jobs. The iOS bridge follows these same APIs; it does not launch a
desktop process or replace HandBrake with an AVFoundation exporter.

`Bridge/HBEngine.mm` owns one handle on a serial dispatch queue. HandBrake's
existing threads perform scanning and transcoding. A dispatch timer copies
real progress and completion state to the main queue. Scanned metadata,
capabilities, presets and settings cross the Swift boundary as JSON copies.
No borrowed native title/job pointers escape to Swift. The bridge initializes
process-global libhb tables once and retains them until process exit.
Pause/resume/stop controls use the main OS thread because libhb holds its
pthread pause mutex between pause and resume calls. They are dispatched
synchronously from the engine queue to preserve ordering; initialization,
scanning and job preparation remain off the UI thread. A native lifetime fix
protects the current job pointer while updating pause statistics, including
JSON pre-scan and completion races.

Each queued source is rescanned before creating a preset-derived job. Settings
override the selected preset explicitly; the rest of its supported engine
filters and metadata remain in the native job. Requested codec availability,
container compatibility, rate control, dimensions, audio bitrate and track
indices are checked before submission. An unavailable encoder returns an error.
VideoToolbox capability queries use the actual device encoder properties, and
session creation enforces hardware use, dimensions, profile and rate control.

`Core/HandBrakeModel.swift` handles source import, persisted queue state,
per-job setting snapshots, disk checks and output publication. Files are copied
under security-scoped access and file coordination, off the UI thread. Copies
live in Application Support; completed outputs live in Documents/Outputs and
are visible in Files. Encoding writes a hidden partial file. Successful
MP4/MOV output is checked for video/audio tracks and duration before being
moved to its final name. Files export uses the document picker directly,
without loading the encoded video into memory.

## Platform changes

The make build has an explicit iOS feature and SDK target. Each device or
simulator slice has its own clang wrappers, CMake toolchain, Meson cross file
and contrib directory. Build-time `bin2c` remains a native Mac executable.
The script merges libhb and its target static dependency closure, verifies
every Mach-O object platform/architecture, links an engine smoke executable,
and creates an XCFramework with public headers. It never runs the smoke
executable on the build Mac.

`libhb/ports.c` avoids macOS IOKit sleep assertions and CoreServices backup
calls on iOS. The Apple config path uses the application's sandbox.
The existing Metal filters select the default iOS GPU and shared resources
instead of macOS device enumeration and managed resources. The libbluray and
libdvdread compatibility patches remove desktop disk-device discovery while
preserving file readers. Desktop behavior is retained behind platform guards.

The build retains x264, FFmpeg, AAC, VP8/VP9, SVT-AV1, dav1d, Opus,
Vorbis, Theora, LAME, containers, subtitle libraries and software/Metal filters.
Software x265 HEVC is included at 8, 10 and 12 bits using the pinned contrib
source, portable C++ kernels and separate device and simulator toolchains.
Apple compilation and the new x265 encoding tests remain unverified.
Rust libdovi and nonfree FDK-AAC remain disabled. HEVC also supports explicitly
selected VideoToolbox hardware when available. Apple hardware
selection/verification keys require iOS 17.4;
iOS 17.0–17.3 uses the available software encoders. Simulator capabilities can
therefore differ from a physical device.

## Implemented application workflow

- Files import, native source scanning, title selection and media information.
- Native HandBrake presets and runtime codec/container enumeration.
- Quality or bitrate control according to encoder capability, resolution bounds,
  source/constant frame rate, audio tracks, audio codec and bitrate.
- One subtitle track passed through when the container supports its format,
  chapter markers and Bwdif deinterlacing. Other supported filters can come from
  the selected native preset.
- Persisted queue, live native progress/speed/ETA, pause/resume, cancel and restart.
- Output deletion, Files export and AVPlayer playback of Apple-supported formats.
- Errors with recent engine diagnostics and explicit rejection of unavailable
  or incompatible encoders.

AAC/audio settings currently produce an appropriate mono/stereo mixdown. The
UI does not expose multichannel layouts, passthrough or lossless compression
controls. The bridge reports unsupported bitrates rather than silently changing
them. MKV/WebM export is available through the engine, but AVPlayer playback and
the built-in MP4/MOV output probe do not support every HandBrake container.
Subtitle burn-in/import, chapter editing, range editing, custom filter editing,
multi-pass controls, previews and full desktop preset editing remain future work.
Disc devices, downloaded executable codecs and external CLI execution are not
part of this application.

## Lifecycle and resource behavior

Encoding runs while the app is foregrounded. Backgrounding cancels active work
and records an interrupted job, which can be restarted from the beginning.
It uses a bounded UIKit background grant only to finish cancellation; it does
not claim unlimited background transcoding. See Apple's
[background execution guidance](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).
Foreground pause/resume retains the active engine state, while process
termination cannot persist libhb's partial transcoding state.

The queue is written atomically at state transitions. Startup recognizes
interrupted jobs, removes their partial outputs and rebases stored filenames
to the current sandbox. Import copies are excluded from backup. Unreferenced
source copies are pruned when jobs are removed. Completed outputs are retained
until the user deletes them; copies previously exported to Files are unaffected.

Before copying/encoding, the app checks free space. Bitrate jobs estimate
duration × total bitrate plus overhead; CQ jobs reserve twice the input size,
since output size cannot be predicted, plus 256 MB for the engine. The bridge
also checks before starting and stops if free space falls below 32 MB while
encoding. This is a conservative check, not a size guarantee. Critical thermal
state and memory warnings pause active encoding; the user resumes explicitly.
Low Power Mode and serious thermal state are shown to the user. Long-running
device tests are still needed to tune memory, speed and battery use.

## Milestone and validation status

| Milestone | Implementation | Verified on this host |
| --- | --- | --- |
| A: native engine compilation | Cross build, dependency patches, platform fixes, archive/link checks, XCFramework packaging | Portable build-rule/policy tests only; Apple compilation pending |
| B: H.264/AAC proof | Real scan/job/start bridge; original fixture; output probe XCTest | Fixture independently inspected with FFprobe; libhb runtime proof pending |
| C: native interface | SwiftUI workflow, controls, settings, persisted queue and export | Swift grammar and project structure checks; Apple typechecking/UI execution pending |
| D: expanded compatibility | Native presets, containers/codecs, chapters, compatible subtitle passthrough and deinterlace | Source implementation; expanded output/device tests pending |
| E: stabilization | Hardware checks, VT error/ownership and pause lifetime fixes, storage checks, thermal/memory/background handling | Production callback/error and resume functions tested under GCC, including AddressSanitizer races; device behavior pending |

Portable tests validate target isolation, static dependency closure, Mach-O
platform checking, project references, and actual native job/error policy
functions. The resume test exercises 25,000 job allocation/free/control races
under AddressSanitizer. Grammar checks are optional developer tooling and cannot establish
Swift type correctness or Apple API availability. The XCTest target contains
real scanning and H.264/AAC encoding/output probing, conditional H.264/HEVC
VideoToolbox tests, unavailable-encoder/missing-file errors and settings/queue
serialization tests. None of these Xcode tests have been run on this host.
The macOS CI workflow is provided but has not been executed during this task.

On the Windows/WSL implementation host, final portable validation passed:
20 Python build/project/package/selection tests, 2 native function tests
(VideoToolbox error/ownership and AddressSanitizer resume races), 22 C job-policy
checks, grammar parsing of all 10 Swift files, and `git diff --check`.
FFprobe confirmed the original test fixture is one-second 160 × 90 H.264/AAC
at 24 fps. The eleven native engine XCTests and five model XCTests remain
unexecuted. No encoded iOS output or engine binary was produced here.

The x265 integration subsequently passed all 27 portable checks. The exact
pinned source with HandBrake's patches also compiled into a combined static
8/10/12-bit library on Linux; each API encoded a short HEVC output at the
requested bit depth, and FFmpeg decoded all three without errors. CMake 4.4.4
configuration also passed. These host checks do not establish iOS
binary or runtime compatibility; the dedicated Mac CI build validates those
separately.

The outstanding blocker is access to full Xcode/iOS SDKs and a physical Apple
device. Compilation, any resulting SDK/linker repairs, simulator integration
tests and on-device scanning/transcoding are required before calling this a
working iOS port. The source here is wired to the real engine throughout; no
fabricated progress or encoding output is used.

## Licensing

HandBrake's GPL and dependency licenses remain applicable. The source build
preserves this checkout's notices and the notices from the exact downloaded
contrib releases beside the XCFramework. The app bundles HandBrake's COPYING
and the generated dependency notice directory. Preserve these artifacts and
the corresponding source when distributing the port.
