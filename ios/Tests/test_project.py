"""Check the hand-authored Xcode project on hosts without an Apple SDK.

These checks validate project structure only. They do not compile Swift or libhb.
Run: python3 -m unittest discover -s ios/Tests -p 'test_project.py' -v
"""

from pathlib import Path
import plistlib
import re
import unittest
import xml.etree.ElementTree as ET


IOS = Path(__file__).resolve().parents[1]


class OpenStep:
    """Parse the property-list subset emitted by this Xcode project."""

    def __init__(self, source):
        pattern = r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,"]+'
        self.tokens = [token for token in re.findall(pattern, source)
                       if not token.startswith(("//", "/*"))]
        self.offset = 0

    def take(self, expected=None):
        token = self.tokens[self.offset]
        self.offset += 1
        if expected is not None and token != expected:
            raise ValueError(f"Expected {expected}, found {token}")
        return token

    def value(self):
        token = self.take()
        if token == "{":
            result = {}
            while self.tokens[self.offset] != "}":
                key = self.value()
                self.take("=")
                if key in result:
                    raise ValueError(f"Duplicate key {key}")
                result[key] = self.value()
                self.take(";")
            self.take("}")
            return result
        if token == "(":
            result = []
            while self.tokens[self.offset] != ")":
                result.append(self.value())
                if self.tokens[self.offset] != ")":
                    self.take(",")
            self.take(")")
            return result
        if token.startswith('"'):
            return re.sub(r"\\(.)", lambda match: {"n": "\n", "t": "\t"}.get(match[1], match[1]), token[1:-1])
        return token

    def parse(self):
        result = self.value()
        if self.offset != len(self.tokens):
            raise ValueError("Unexpected trailing project tokens")
        return result


class ProjectTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = OpenStep((IOS / "HandBrakeIOS.xcodeproj/project.pbxproj").read_text()).parse()
        cls.objects = cls.project["objects"]

    def test_references_resolve(self):
        references = {"fileRef", "mainGroup", "productRefGroup", "productReference", "buildConfigurationList",
                      "target", "targetProxy", "containerPortal", "remoteGlobalIDString", "TestTargetID"}
        arrays = {"children", "buildPhases", "dependencies", "buildConfigurations", "targets", "files"}

        def visit(value, key=None):
            if isinstance(value, dict):
                for child_key, child in value.items():
                    visit(child, child_key)
            elif isinstance(value, list):
                for child in value:
                    visit(child, key)
            elif key in references | arrays:
                self.assertIn(value, self.objects, f"Unresolved {key}: {value}")

        visit(self.objects)
        self.assertEqual(self.objects[self.project["rootObject"]]["isa"], "PBXProject")

    def test_source_files_and_fixture_exist(self):
        root = self.objects[self.project["rootObject"]]["mainGroup"]
        files = {}

        def visit(identifier, directory):
            obj = self.objects[identifier]
            if obj["isa"] == "PBXGroup":
                directory = directory / obj.get("path", "")
                for child in obj["children"]:
                    visit(child, directory)
            elif obj["isa"] == "PBXFileReference" and obj["sourceTree"] == "<group>":
                files[identifier] = directory / obj["path"]

        visit(root, IOS)
        native_sources = set()
        for obj in self.objects.values():
            if obj["isa"] in {"PBXSourcesBuildPhase", "PBXResourcesBuildPhase"}:
                for build_id in obj["files"]:
                    path = files[self.objects[build_id]["fileRef"]]
                    self.assertTrue(path.is_file(), str(path))
                    if obj["isa"] == "PBXSourcesBuildPhase":
                        native_sources.add(path.resolve())
        swift_files = set(IOS.glob("App/*.swift")) | set(IOS.glob("Core/*.swift")) | set(IOS.glob("Tests/*.swift"))
        for path in swift_files:
            self.assertIn(path.resolve(), native_sources, f"Swift file missing from target: {path}")

    def test_shared_scheme_matches_targets(self):
        scheme = ET.parse(IOS / "HandBrakeIOS.xcodeproj/xcshareddata/xcschemes/HandBrakeIOS.xcscheme")
        for buildable in scheme.findall(".//BuildableReference"):
            target = self.objects[buildable.attrib["BlueprintIdentifier"]]
            self.assertEqual(target["isa"], "PBXNativeTarget")
            self.assertEqual(target["name"], buildable.attrib["BlueprintName"])
            product = self.objects[target["productReference"]]
            self.assertEqual(product["path"], buildable.attrib["BuildableName"])

    def test_ios_sandbox_and_minimum_deployment(self):
        with (IOS / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        self.assertTrue(info["UIFileSharingEnabled"])
        self.assertTrue(info["LSSupportsOpeningDocumentsInPlace"])
        self.assertNotIn("UIBackgroundModes", info)
        deployment = [obj["buildSettings"]["IPHONEOS_DEPLOYMENT_TARGET"]
                      for obj in self.objects.values() if obj["isa"] == "XCBuildConfiguration"
                      and "IPHONEOS_DEPLOYMENT_TARGET" in obj["buildSettings"]]
        self.assertEqual(deployment, ["17.0", "17.0"])


if __name__ == "__main__":
    unittest.main()
