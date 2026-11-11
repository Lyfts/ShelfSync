import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "check_release.sh"


class CheckReleaseTest(unittest.TestCase):
    def check(self, status, payload):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            curl = root / "curl"
            curl.write_text('#!/bin/bash\nprintf "%s" "$BODY" > "$3"\nprintf "%s" "$STATUS"\n')
            curl.chmod(0o755)
            env = dict(os.environ, PATH=f"{temp}:{os.environ['PATH']}", GH_TOKEN="test",
                       GITHUB_API_URL="https://example.test", GITHUB_REPOSITORY="owner/repo",
                       VERSION="1.2.3", STATUS=str(status), BODY=payload)
            return subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)

    def test_release_states(self):
        assets = [{"name": name, "state": "uploaded"} for name in
                  ("shelfsync.koplugin.zip", "shelfsync-fetch-cookies.zip")]
        self.assertEqual(self.check(404, "{}").returncode, 0)
        self.assertEqual(self.check(200, json.dumps({"draft": False, "assets": assets[:1]})).returncode, 0)
        self.assertEqual(self.check(200, json.dumps({"draft": True, "assets": assets})).returncode, 0)
        self.assertNotEqual(self.check(200, json.dumps({"draft": False, "assets": assets})).returncode, 0)
        self.assertNotEqual(self.check(500, "{}").returncode, 0)
        self.assertNotEqual(self.check(200, "not json").returncode, 0)
        self.assertNotEqual(self.check(200, "{}").returncode, 0)


if __name__ == "__main__":
    unittest.main()
