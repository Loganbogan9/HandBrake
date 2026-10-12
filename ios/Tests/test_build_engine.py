"""Portable checks for platform isolation and static-library completeness."""
import importlib.util
from pathlib import Path
import plistlib
import re
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/build-engine.py"
spec = importlib.util.spec_from_file_location("handbrake_ios_build", SCRIPT)
build = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = build
spec.loader.exec_module(build)


def macho(cpu, platform):
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, cpu, 0, 1, 1, 24, 0, 0)
    command = struct.pack("<IIIIII", 0x32, 24, platform, 0x110000, 0x110000, 0)
    return header + command


def archive_bytes(*objects):
    result = bytearray(b"!<arch>\n")
    for index, data in enumerate(objects):
        header = f"{('object' + str(index) + '.o/'):16}{0:12}{0:6}{0:6}{'644':8}{len(data):10}`\n".encode()
        result.extend(header + data + (b"\n" if len(data) % 2 else b""))
    return bytes(result)


class ArchivePlatformTests(unittest.TestCase):
    def verify(self, contents, target):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "engine.a"
            archive.write_bytes(contents)
            return build.verify_archive_platform(archive, target)

    def test_ios_device_archive_accepts_every_correct_member(self):
        data = archive_bytes(macho(0x100000C, 2), macho(0x100000C, 2))
        self.assertEqual(self.verify(data, build.Target("iphoneos", "arm64", "17.0")), 2)

    def test_arm64_device_cannot_be_mixed_into_simulator_archive(self):
        data = archive_bytes(macho(0x100000C, 7), macho(0x100000C, 2))
        with self.assertRaisesRegex(RuntimeError, "Wrong Apple platform.*object1"):
            self.verify(data, build.Target("iphonesimulator", "arm64", "17.0"))

    def test_macos_arm64_is_rejected_even_when_cpu_matches(self):
        with self.assertRaisesRegex(RuntimeError, "Wrong Apple platform"):
            self.verify(archive_bytes(macho(0x100000C, 1)), build.Target("iphoneos", "arm64", "17.0"))

    def test_wrong_architecture_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "Wrong architecture"):
            self.verify(archive_bytes(macho(0x1000007, 7)), build.Target("iphonesimulator", "arm64", "17.0"))

    def test_non_macho_object_cannot_hide_in_archive(self):
        with self.assertRaisesRegex(RuntimeError, "Non-Mach-O object"):
            self.verify(archive_bytes(b"not a compiled object"), build.Target("iphoneos", "arm64", "17.0"))


class DependencyClosureTests(unittest.TestCase):
    def test_missing_target_library_does_not_fall_back_to_host(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "libhb").mkdir()
            (root / "libhb/libhandbrake.a").touch()
            with patch.object(build, "run", return_value="-lavcodec -lc++"):
                with self.assertRaisesRegex(RuntimeError, "No target static archive for -lavcodec"):
                    build.dependency_archives(root, {})

    def test_static_closure_deduplicates_and_preserves_system_libraries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "libhb").mkdir()
            (root / "contrib/lib").mkdir(parents=True)
            engine = root / "libhb/libhandbrake.a"
            codec = root / "contrib/lib/libavcodec.a"
            engine.touch()
            codec.touch()
            with patch.object(build, "run", return_value="-lavcodec -lc++ -lavcodec -lz"):
                archives, flags = build.dependency_archives(root, {})
            self.assertEqual(archives, [engine, codec])
            self.assertIn("-lc++", flags)


class TargetTests(unittest.TestCase):
    def test_simulator_triple_has_its_own_platform(self):
        self.assertEqual(build.Target("iphonesimulator", "arm64", "17.0").triple,
                         "arm64-apple-ios17.0-simulator")

    def test_meson_never_executes_target_probes_and_cmake_targets_ios(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(build, "xcrun", return_value="/usr/bin/strip"):
                _, _, _, cmake, meson = build.toolchain_files(
                    Path(directory), build.Target("iphoneos", "arm64", "17.0"),
                    Path("/SDK/iPhoneOS.sdk"), "/usr/bin/clang", "/usr/bin/clang++",
                    "/usr/bin/ar", "/usr/bin/ranlib", "/usr/bin/pkg-config")
            self.assertIn("needs_exe_wrapper = true", meson.read_text())
            self.assertIn("set(CMAKE_SYSTEM_NAME iOS)", cmake.read_text())
            wrapper = (Path(directory) / "tools/hb-clang").read_text()
            self.assertIn("-target arm64-apple-ios17.0", wrapper)
            self.assertNotIn("macosx-version-min", wrapper)


class SwiftPackageMetadataTests(unittest.TestCase):
    def test_binary_engine_module_exposes_public_api_only(self):
        with tempfile.TemporaryDirectory() as directory:
            headers = Path(directory)
            build.write_engine_module(headers)
            module = (headers / "module.modulemap").read_text()
            header = (headers / "HandBrakeEngine.h").read_text()
            self.assertIn('module HandBrakeEngine {', module)
            self.assertIn('header "HandBrakeEngine.h"', module)
            self.assertNotIn("umbrella", module)
            self.assertIn("#include <handbrake/handbrake.h>", header)
            self.assertNotIn("libav", header)

    def test_swift_package_uses_existing_bridge_and_app_sources(self):
        root = SCRIPT.parents[1]
        manifest = (root / "Package.swift").read_text()
        self.assertRegex(manifest, r'\.binaryTarget\(\s*name: "HandBrakeEngine",\s*path: "Artifacts/HandBrakeEngine.xcframework"')
        self.assertRegex(manifest, r'name: "HBEngineBridge",[\s\S]*?sources: \["HBEngine.mm"\]')
        self.assertIn('sources: ["App", "Core"]', manifest)
        self.assertIn('swiftLanguageModes: [.v5]', manifest)
        self.assertTrue((root / "Bridge/HBEngine.mm").is_file())
        bridge_module = (root / "Bridge/module.modulemap").read_text()
        header = re.search(r'header "([^"]+)"', bridge_module).group(1)
        self.assertTrue((root / "Bridge" / header).is_file())
        self.assertIn("module HBEngineBridge", bridge_module)

    def test_xtool_metadata_and_license_resources_resolve(self):
        root = SCRIPT.parents[1]
        configuration = (root / "xtool.yml").read_text()
        self.assertRegex(configuration, r"(?m)^version: 1$")
        self.assertRegex(configuration, r"(?m)^product: HandBrakeIOS$")
        info_path = re.search(r"(?m)^infoPath: (.+)$", configuration).group(1)
        plist = plistlib.loads((root / info_path).read_bytes())
        self.assertEqual(plist["CFBundleShortVersionString"], "1.11.2")
        self.assertEqual(plist["UIDeviceFamily"], [1, 2])
        self.assertTrue(plist["LSSupportsOpeningDocumentsInPlace"])
        self.assertTrue(plist["UIFileSharingEnabled"])
        self.assertNotIn("$(", (root / info_path).read_text())
        for source in re.findall(r"(?m)^  - (.+)$", configuration):
            if source == "Artifacts/HandBrakeEngine-Licenses":
                continue  # generated with the actual engine on the Apple host
            self.assertTrue((root / source).is_file(), source)


if __name__ == "__main__":
    unittest.main()
