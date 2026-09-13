"""Tests that ban-words.py keeps its log and pending state readable by the owner only."""
import importlib.util
import os
import pathlib
import tempfile
import unittest

HOOK = pathlib.Path(__file__).resolve().parent.parent / "claude" / "hooks" / "ban-words.py"
spec = importlib.util.spec_from_file_location("ban_words", HOOK)
ban_words = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ban_words)


def mode(path):
    return os.stat(path).st_mode & 0o777


class PrivateFilesTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.log = os.path.join(self.dir.name, "ban-words.log")
        self.pending = os.path.join(self.dir.name, "pending.json")
        self.saved = ban_words.LOG_PATH, ban_words.PENDING_PATH
        ban_words.LOG_PATH, ban_words.PENDING_PATH = self.log, self.pending

    def tearDown(self):
        ban_words.LOG_PATH, ban_words.PENDING_PATH = self.saved
        self.dir.cleanup()

    def test_log_is_created_owner_only(self):
        ban_words.log_event({"tool_name": "Write", "tool_input": {"content": "x"}}, ["x"], "block")
        self.assertEqual(0o600, mode(self.log))

    def test_pending_state_is_created_owner_only(self):
        ban_words.confirm_pending("k")
        self.assertEqual(0o600, mode(self.pending))

    def test_a_symlinked_log_path_is_refused(self):
        target = os.path.join(self.dir.name, "elsewhere.log")
        os.symlink(target, self.log)
        ban_words.log_event({"tool_name": "Write", "tool_input": {"content": "x"}}, ["x"], "block")
        self.assertFalse(os.path.exists(target))

    def test_existing_world_readable_log_is_tightened(self):
        with open(self.log, "w") as f:
            f.write("old\n")
        os.chmod(self.log, 0o644)
        ban_words.log_event({"tool_name": "Write", "tool_input": {"content": "x"}}, ["x"], "block")
        self.assertEqual(0o600, mode(self.log))
        with open(self.log) as f:
            self.assertEqual("old", f.readline().strip())


if __name__ == "__main__":
    unittest.main(verbosity=2)
