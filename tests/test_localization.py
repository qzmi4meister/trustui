import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class LocalizationTests(unittest.TestCase):
    def test_all_ui_and_error_strings_have_both_translations(self):
        catalogs = {}
        for language in ("ru", "en"):
            with (ROOT / f"Resources/{language}.lproj/Localizable.strings").open("rb") as file:
                catalogs[language] = plistlib.load(file)
        self.assertEqual(catalogs["ru"].keys(), catalogs["en"].keys())
        for key in catalogs["ru"]:
            self.assertTrue(catalogs["en"][key])
            self.assertEqual(catalogs["en"][key].count("%@"), catalogs["ru"][key].count("%@"))
            self.assertIsNone(re.search(r"[А-Яа-яЁё]", catalogs["en"][key]), key)
        for path in (ROOT / "Sources").glob("*"):
            if path.suffix not in (".swift", ".py"):
                continue
            for literal in re.findall(r'"([^"\n]*)"', path.read_text()):
                if literal == "Русский" or "{path.name}" in literal:
                    continue  # Language autonym and legacy machine-response warning, rendered from invalidProfiles.
                if re.search(r"[А-Яа-яЁё]", literal) or literal.startswith("guide."):
                    self.assertIn(literal, catalogs["en"], f"Missing translation in {path.name}")

    def test_native_bundle_lookup_switching_and_formatting(self):
        with tempfile.TemporaryDirectory(prefix="trustui-language-") as folder:
            app = Path(folder) / "Check.app/Contents"
            (app / "MacOS").mkdir(parents=True)
            shutil.copytree(ROOT / "Resources", app / "Resources")
            with (app / "Info.plist").open("wb") as file:
                plistlib.dump({"CFBundleIdentifier": "local.trustui.localization-check",
                               "CFBundleExecutable": "Check", "CFBundlePackageType": "APPL"}, file)
            executable = app / "MacOS/Check"
            subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                            str(ROOT / "Sources/Localization.swift"), str(ROOT / "tests/localization_check.swift"),
                            "-o", str(executable)], check=True, capture_output=True, text=True)
            result = subprocess.run([str(executable)], check=True, capture_output=True, text=True)
            self.assertIn("passed", result.stdout)

    def test_missing_config_returns_localizable_error_without_touching_files(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, "-I", str(ROOT / "Sources/backend.py"), "load"],
                                    input=json.dumps({"directory": directory}), capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            response = json.loads(result.stdout)
            self.assertIn("%@", response["errorKey"])
            self.assertEqual(response["errorArguments"], [str(Path(directory).resolve() / "trusttunnel_client.toml")])
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_guide_commands_parse_without_running_installers(self):
        source = (ROOT / "Sources/GuideView.swift").read_text()
        blocks = re.findall(r'#"""\n(.*?)\n\s*"""#', source, re.DOTALL)
        self.assertEqual(len(blocks), 4)
        for block in blocks:
            subprocess.run(["/bin/bash", "-n"], input=block, text=True, check=True, capture_output=True)
        self.assertIn("test ! -e trusttunnel_client.toml", source)


if __name__ == "__main__":
    unittest.main()
