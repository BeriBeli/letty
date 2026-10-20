"""Release guards run without building the app or contacting GitHub."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
spec = importlib.util.spec_from_file_location("release_gate", ROOT / "tools/verify-native-release.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ReleaseGuards(unittest.TestCase):
    def run_package(self, version, tag, ref_type="tag"):
        env = dict(os.environ, GITHUB_ACTIONS="true", GITHUB_REF_TYPE=ref_type,
                   GITHUB_REF_NAME=tag)
        result = subprocess.run([sys.executable, str(ROOT / "tools/package.py"),
                                 "--ci", "--version", version],
                                env=env, cwd=ROOT, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        return result.stdout + result.stderr

    def test_version_must_match_lock(self):
        self.assertIn("differs from deps.lock.json", self.run_package("99.0.0", "v99.0.0"))

    def test_tag_must_match_version(self):
        self.assertIn("differs from the workflow tag", self.run_package("0.1.0", "v0.2.0"))

    def test_branch_cannot_publish(self):
        self.assertIn("differs from the workflow tag", self.run_package("0.1.0", "v0.1.0", "branch"))

    def test_version_rejects_path_components(self):
        self.assertIn("numeric X.Y.Z", self.run_package("../0.1.0", "v../0.1.0"))

    def check_ui(self, *, count=2, log_hash="log", omit_batch=False):
        output = "PASS UI first\nPASS UI second\nAll UI checks passed.\n"
        for batch in ("M9", "M10", "M11", "SIDEBAR", "SETTINGS", "PREVIEW"):
            if batch == "PREVIEW" and omit_batch:
                continue
            output += f"BATCH_BEGIN {batch}\nBATCH_END {batch}\nFeature checks passed: {batch}\n"
        record = {"suite": "linux-ui", "log_sha256": log_hash,
                  "binary_sha256": "binary", "count": count}
        build = {"configuration": {"target": "x86_64-linux.3.10-gnu.2.17"},
                 "binaries": {"letty": "binary"}}
        with patch.object(gate, "SUITES", {"ui": ("letty", 1)}), \
                patch.object(gate, "UI_EXPECTED", {"linux": 1}), \
                patch.object(gate, "current", return_value=record), \
                patch.object(gate, "log_text", return_value=output), \
                patch.object(gate, "sha", return_value="log"):
            return gate.suites(Path("linux"), build, "source", minimums=True)

    def test_complete_ui_allows_additional_assertions(self):
        self.assertEqual(self.check_ui()["ui"]["checks"], 2)

    def test_record_count_must_match_actual_log(self):
        with self.assertRaisesRegex(RuntimeError, "assertion count"):
            self.check_ui(count=3)

    def test_changed_log_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "hash/identity"):
            self.check_ui(log_hash="tampered")

    def test_missing_ui_batch_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "feature batch"):
            self.check_ui(omit_batch=True)


if __name__ == "__main__":
    unittest.main()
