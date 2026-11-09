"""Exercise orchestration failures without Docker, SSH or production access."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CommandsTest(unittest.TestCase):
    def test_server_cleanup_preserves_success_and_test_failure(self):
        for test_exit in (0, 7):
            with self.subTest(test_exit=test_exit), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                docker = folder / "docker"
                docker.write_text('''#!/bin/bash
printf '%s|%s|%s\\n' "$*" "$WOONA_STORAGE_ROOT_HOST" "$WOONA_POSTGRES_ROOT" >> "$COMMAND_LOG"
if [[ "$*" == *'unittest discover'* ]]; then
    touch "$WOONA_STORAGE_ROOT_HOST/synthetic"
    exit "$TEST_EXIT"
fi
''')
                docker.chmod(0o700)
                env = dict(os.environ, PATH=f"{folder}:{os.environ['PATH']}",
                           COMMAND_LOG=str(folder / "calls"), TEST_EXIT=str(test_exit),
                           WOONA_POSTGRES_ROOT="/existing-database", COMPOSE_FILE="/other-stack.yaml")
                result = subprocess.run([str(ROOT / "woona"), "check", "server"],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, test_exit, result.stderr)
                calls = (folder / "calls").read_text().splitlines()
                self.assertIn("down -v --remove-orphans", calls[-1])
                self.assertTrue(any("--user 0 --entrypoint chown" in row for row in calls))
                storage = Path(calls[-1].split("|")[1])
                self.assertFalse(storage.exists())
                self.assertTrue(all("-p woona-check-" in row for row in calls))
                self.assertTrue(all(row.endswith("|postgres_data") for row in calls))
                self.assertTrue(all(f"-f {ROOT}/shared/compose.yaml" in row for row in calls))

    def test_unknown_command_does_not_run_any_action(self):
        result = subprocess.run([str(ROOT / "woona"), "deploy"], capture_output=True)
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
