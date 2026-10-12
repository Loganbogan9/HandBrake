"""Exercise upstream GNU make's actual iOS and macOS rule expansion."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("make"), "GNU make is required for build-rule expansion")
class MakeConfigurationTests(unittest.TestCase):
    def configuration(self, ios, sdk="iphoneos"):
        with tempfile.TemporaryDirectory() as directory:
            configuration = Path(directory) / "Makefile"
            values = [
                f"SRC/ := {REPOSITORY.as_posix()}/", "BUILD/ := ./",
                "HOST.system := darwin", "HOST.machine := arm64", "HOST.arch := arm64",
                "HOST.spec := arm64-apple-darwin24.0.0", "HOST.cross := 1",
                "BUILD.machine := arm64", "BUILD.spec := arm64-apple-darwin24.0.0",
                "FEATURE.xcode := 0", "FEATURE.x265 := 0", "FEATURE.libdovi := 0",
                "GCC.g := none", "GCC.O := speed", "GCC.cpu := none", "GCC.lto := none",
            ]
            if ios:
                values += ["FEATURE.ios := 1", f"IOS.sdk := {sdk}",
                           "IOS.host_cc := /host/clang", "IOS.meson_cross := /target/ios.cross.meson",
                           "IOS.cmake_toolchain := /target/ios.toolchain.cmake"]
            values += [
                "include $(SRC/)make/include/main.defs",
                "GCC.gcc := /target/hb-clang", "GCC.minver := 17.0", "GCC.sysroot := /target/iPhoneOS.sdk",
                "include $(SRC/)make/include/main.rules",
                "$(info compiler=$(call LIBHB.GCC.C_O,example.o,example.c))",
                "$(info helper=$(call BIN2C.GCC.C_O,helper.o,helper.c))",
                "$(info metal=$(LIBHB.METAL.cc) $(LIBHB.METAL.args.extra))",
                "$(info meson=$(LIBDVDREAD.CONFIGURE.extra))",
                "$(info cmake=$(SVT-AV1.CONFIGURE.extra))",
                "$(info vpx=$(LIBVPX.CONFIGURE.extra))",
                "$(info contrib_host=$(CONTRIB.host))",
                "$(info modules=$(MODULES))",
                ".PHONY: test.config", "test.config:", "\t@:", "",
            ]
            configuration.write_text("\n".join(values), encoding="utf-8")
            result = subprocess.run(["make", "--no-print-directory", "-f", str(configuration), "test.config"],
                                    cwd=directory, capture_output=True, text=True, check=True)
            return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)

    def test_ios_device_rules_preserve_sdk_and_native_helper(self):
        values = self.configuration(True)
        self.assertIn("-miphoneos-version-min=17.0", values["compiler"])
        self.assertIn("-fblocks", values["compiler"])
        self.assertIn("-fno-objc-arc", values["compiler"])
        self.assertNotIn("macosx-version-min", values["compiler"])
        self.assertIn("/host/clang", values["helper"])
        self.assertNotIn("iPhoneOS.sdk", values["helper"])
        self.assertNotIn("version-min", values["helper"])
        self.assertIn("--sdk iphoneos metal", values["metal"])
        self.assertIn("-std=ios-metal2.4", values["metal"])
        self.assertIn("--cross-file=/target/ios.cross.meson", values["meson"])
        self.assertNotIn("darwin-gcc.meson", values["meson"])
        self.assertIn("-DCMAKE_SYSTEM_NAME=iOS", values["cmake"])
        self.assertEqual(values["vpx"].count("--target="), 1)
        self.assertIn("--target=generic-gnu", values["vpx"])
        self.assertEqual(values["contrib_host"], "arm64-apple-darwin")
        self.assertNotIn(" test", values["modules"])
        self.assertNotIn(" macosx", values["modules"])

    def test_simulator_rules_use_simulator_deployment_target(self):
        values = self.configuration(True, "iphonesimulator")
        self.assertIn("-mios-simulator-version-min=17.0", values["compiler"])
        self.assertIn("--sdk iphonesimulator metal", values["metal"])

    def test_cached_desktop_config_without_ios_feature_preserves_behavior(self):
        values = self.configuration(False)
        self.assertIn("-mmacosx-version-min=17.0", values["compiler"])
        self.assertIn("-std=macos-metal2.4", values["metal"])
        self.assertIn("darwin-gcc.meson", values["meson"])
        self.assertIn("--target=arm64-darwin20-gcc", values["vpx"])
        self.assertIn(" test", values["modules"])


if __name__ == "__main__":
    unittest.main()
