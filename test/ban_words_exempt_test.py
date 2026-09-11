"""Tests for ban-words.py's path exemptions. Run: python3 ban_words_exempt_test.py"""
import importlib.util
import pathlib
import unittest

HOOK = pathlib.Path(__file__).resolve().parent.parent / "claude" / "hooks" / "ban-words.py"
spec = importlib.util.spec_from_file_location("ban_words", HOOK)
ban_words = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ban_words)


class ExemptPathTest(unittest.TestCase):
    def test_files_beside_the_hooks_real_location_are_exempt(self):
        self.assertTrue(ban_words.exempt(str(HOOK.parent / "neighbour.rb")))

    def test_the_hook_itself_reached_through_a_symlink_is_exempt(self):
        link = pathlib.Path("/tmp/ban-words-link.py")
        if link.is_symlink():
            link.unlink()
        link.symlink_to(HOOK)
        try:
            self.assertTrue(ban_words.exempt(str(link)))
        finally:
            link.unlink()

    def test_claude_config_and_agent_instruction_files_are_exempt(self):
        self.assertTrue(ban_words.exempt("/tmp/home/.claude/settings.json"))
        self.assertTrue(ban_words.exempt("/tmp/home/.claude/hooks/other.sh"))
        self.assertTrue(ban_words.exempt("/tmp/middle-out/AGENTS.md"))

    def test_ordinary_paths_are_not_exempt(self):
        self.assertFalse(ban_words.exempt("/tmp/middle-out/app/models/user.rb"))
        self.assertFalse(ban_words.exempt(""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
