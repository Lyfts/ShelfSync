import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "tools" / "prepare_release.py"


class PrepareReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "tools").mkdir()
        (self.root / "tools" / SCRIPT.name).write_bytes(SCRIPT.read_bytes())
        self.changelog = self.root / "CHANGELOG.md"
        self.metadata = self.root / "_meta.lua"
        self.changelog.write_bytes(b"# Changelog\n\n## Unreleased\n\n- Change\n\n## 1.2.3\n- Old\n")
        self.metadata.write_text('return {\n  version = "1.2.3",\n}\n')

    def run_release(self, version, succeeds=True):
        result = subprocess.run([sys.executable, str(self.root / "tools" / SCRIPT.name), version],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, succeeds, result.stderr)
        return result

    def test_prepares_and_retries(self):
        self.run_release("1.2.4")
        self.assertEqual(self.changelog.read_text(),
                         "# Changelog\n\n## Unreleased\n\n## 1.2.4\n- Change\n\n## 1.2.3\n- Old\n")
        self.assertIn('version = "1.2.4"', self.metadata.read_text())
        self.assertIn("already prepared", self.run_release("1.2.4").stdout)

    def test_rejects_invalid_duplicate_and_older_versions(self):
        for version in ("1.2", "1.2.2", "1.2.3"):
            with self.subTest(version=version):
                self.run_release(version, succeeds=False)
        self.changelog.write_text(self.changelog.read_text() + "## Unreleased\n")
        self.run_release("1.2.4", succeeds=False)

    def test_preserves_windows_line_endings(self):
        self.changelog.write_bytes(self.changelog.read_bytes().replace(b"\n", b"\r\n"))
        self.run_release("1.2.4")
        content = self.changelog.read_bytes()
        self.assertNotIn(b"\n", content.replace(b"\r\n", b""))
        self.assertIn(b"## 1.2.4\r\n- Change", content)


if __name__ == "__main__":
    unittest.main()
