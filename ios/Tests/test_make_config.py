"""Exercise upstream GNU make's actual iOS and macOS rule expansion."""
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("make"), "GNU make is required for build-rule expansion")
class MakeConfigurationTests(unittest.TestCase):
    def configuration(self, ios, sdk="iphoneos", arch="arm64", x265=False):
        with tempfile.TemporaryDirectory() as directory:
            configuration = Path(directory) / "Makefile"
            values = [
                f"SRC/ := {REPOSITORY.as_posix()}/", "BUILD/ := ./",
                "HOST.system := darwin", f"HOST.machine := {arch}", f"HOST.arch := {arch}",
                "HOST.spec := arm64-apple-darwin24.0.0", "HOST.cross := 1",
                "BUILD.machine := arm64", "BUILD.spec := arm64-apple-darwin24.0.0",
                "FEATURE.xcode := 0", f"FEATURE.x265 := {int(x265)}", "FEATURE.libdovi := 0",
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
                "$(info fribidi=$(FRIBIDI.CONFIGURE.extra))",
                "$(info freetype=$(FREETYPE.CONFIGURE.extra))",
                "$(info cmake=$(SVT-AV1.CONFIGURE.extra))",
                "$(info harfbuzz=$(HARFBUZZ.CONFIGURE.extra))",
                "$(info x265_8=$(call fn.ARGS,X265_8.CONFIGURE,$(X265_8.CONFIGURE.args)))",
                "$(info x265_10=$(call fn.ARGS,X265_10.CONFIGURE,$(X265_10.CONFIGURE.args)))",
                "$(info x265_12=$(call fn.ARGS,X265_12.CONFIGURE,$(X265_12.CONFIGURE.args)))",
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

    def test_ios_generators_use_native_compiler_and_preprocessor_flags(self):
        values = self.configuration(True)
        self.assertIn('CC_FOR_BUILD="/host/clang"', values["fribidi"])
        self.assertIn('CPPFLAGS_FOR_BUILD=""', values["fribidi"])
        self.assertIn('LDFLAGS_FOR_BUILD=""', values["fribidi"])
        self.assertIn('CC_BUILD="/host/clang"', values["freetype"])

    def test_ios_harfbuzz_uses_exact_target_freetype_archive(self):
        for sdk, arch in (("iphoneos", "arm64"), ("iphonesimulator", "arm64"),
                          ("iphonesimulator", "x86_64")):
            with self.subTest(sdk=sdk, arch=arch):
                arguments = shlex.split(self.configuration(True, sdk, arch)["harfbuzz"])
                cache = dict(argument[2:].split("=", 1) for argument in arguments
                             if argument.startswith("-D") and "=" in argument)
                archive = cache["FREETYPE_LIBRARY:FILEPATH"]
                self.assertTrue(archive.endswith("/contrib/lib/libfreetype.a"), archive)
                self.assertEqual(cache["FREETYPE_LIBRARIES:FILEPATH"], archive)
                self.assertNotIn("/opt/homebrew", archive)

    def test_cached_desktop_config_without_ios_feature_preserves_behavior(self):
        values = self.configuration(False)
        self.assertIn("-mmacosx-version-min=17.0", values["compiler"])
        self.assertIn("-std=macos-metal2.4", values["metal"])
        self.assertIn("darwin-gcc.meson", values["meson"])
        self.assertIn("--target=arm64-darwin20-gcc", values["vpx"])
        self.assertIn(" test", values["modules"])
        self.assertNotIn("CC_FOR_BUILD=", values["fribidi"])
        self.assertNotIn("CC_BUILD=", values["freetype"])
        self.assertNotIn("-DFREETYPE_LIBRARY:FILEPATH=", values["harfbuzz"])

    def test_x265_multilib_uses_target_toolchain_for_every_ios_slice(self):
        for sdk, arch in (("iphoneos", "arm64"), ("iphonesimulator", "arm64"),
                          ("iphonesimulator", "x86_64")):
            with self.subTest(sdk=sdk, arch=arch):
                values = self.configuration(True, sdk, arch, x265=True)
                for depth in (8, 10, 12):
                    command = values[f"x265_{depth}"]
                    self.assertIn("-DCMAKE_SYSTEM_NAME=iOS", command)
                    self.assertIn('-DCMAKE_TOOLCHAIN_FILE="/target/ios.toolchain.cmake"', command)
                    self.assertIn(f"-DCMAKE_OSX_ARCHITECTURES={arch}", command)
                    self.assertIn("-DENABLE_ASSEMBLY=OFF", command)
                    self.assertIn("-DENABLE_SVE=OFF", command)
                    self.assertIn("-DENABLE_SVE2=OFF", command)
                    self.assertIn("-DENABLE_PIC=ON", command)
                    self.assertIn("-DENABLE_SHARED=OFF", command)
                    self.assertIn("-DENABLE_CLI=OFF", command)
                    self.assertNotIn("-DCMAKE_HOST_SYSTEM=", command)
                    self.assertIn(f"/{depth}bit;", command)
                self.assertIn("-DLINKED_10BIT=ON", values["x265_8"])
                self.assertIn("-DLINKED_12BIT=ON", values["x265_8"])
                self.assertIn("-DHIGH_BIT_DEPTH=OFF", values["x265_8"])
                self.assertIn("-DHIGH_BIT_DEPTH=ON", values["x265_10"])
                self.assertIn("-DHIGH_BIT_DEPTH=ON", values["x265_12"])
                self.assertIn("-DMAIN12=ON", values["x265_12"])

    def test_desktop_x265_retains_existing_assembly_configuration(self):
        values = self.configuration(False, x265=True)
        for depth in (8, 10, 12):
            command = values[f"x265_{depth}"]
            self.assertNotIn("-DENABLE_ASSEMBLY=OFF", command)
            self.assertNotIn("-DENABLE_SVE=OFF", command)
            self.assertNotIn("-DCMAKE_SYSTEM_NAME=iOS", command)
            self.assertIn("-DCMAKE_OSX_ARCHITECTURES=arm64", command)


if __name__ == "__main__":
    unittest.main()
