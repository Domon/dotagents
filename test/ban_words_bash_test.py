"""Tests for ban-words.py's Bash arm. Run: python3 ban_words_bash_test.py

The Bash arm scans freshly authored text in commands that publish it. It already
covered `git commit` and `gh pr create|edit`; a review reply goes out via
`gh api .../comments`, and its text often arrives as `-F body=@file` rather than
inline in the command.
"""
import importlib.util
import pathlib
import tempfile
import unittest

HOOK = pathlib.Path(__file__).resolve().parent.parent / "claude" / "hooks" / "ban-words.py"
spec = importlib.util.spec_from_file_location("ban_words", HOOK)
ban_words = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ban_words)

# Sample text the hook must flag, and text it must not. Kept as constants so the
# intent of each case reads without the words being repeated in every assertion.
FLAGGED = "an affordance that is load-bearing"
CLEAN = "The limit is a soft one. A queue at 51 drains normally."


class BashArmTest(unittest.TestCase):
    def blocked(self, cmd):
        return ban_words.blocked_words("Bash", {"command": cmd})

    # --- paths already covered ----------------------------------------------

    def test_git_commit_carrying_a_banned_word_is_blocked(self):
        self.assertTrue(self.blocked(f'git commit -m "{FLAGGED}"'))

    def test_gh_pr_create_carrying_a_banned_word_is_blocked(self):
        self.assertTrue(self.blocked(f'gh pr create --body "{FLAGGED}"'))

    def test_clean_git_commit_passes(self):
        self.assertFalse(self.blocked(f'git commit -m "{CLEAN}"'))

    # --- the gap: comment bodies --------------------------------------------

    def test_review_comment_reply_is_scanned(self):
        cmd = ("gh api repos/pied-piper/middle-out/pulls/4242/comments -X POST "
               f'-F in_reply_to=123 -f body="{FLAGGED}"')
        self.assertTrue(self.blocked(cmd))

    def test_issue_comment_is_scanned(self):
        cmd = f'gh api repos/pied-piper/middle-out/issues/4242/comments -f body="{FLAGGED}"'
        self.assertTrue(self.blocked(cmd))

    def test_gh_pr_comment_subcommand_is_scanned(self):
        self.assertTrue(self.blocked(f'gh pr comment 4242 --body "{FLAGGED}"'))

    def test_gh_pr_review_is_scanned(self):
        self.assertTrue(self.blocked(f'gh pr review 4242 --comment --body "{FLAGGED}"'))

    def test_patch_of_a_pr_body_is_scanned(self):
        cmd = ("gh api repos/pied-piper/middle-out/pulls/4242 -X PATCH "
               f'-f body="{FLAGGED}"')
        self.assertTrue(self.blocked(cmd))

    def test_clean_comment_body_passes(self):
        cmd = ("gh api repos/pied-piper/middle-out/pulls/4242/comments -X POST "
               f'-F in_reply_to=123 -f body="{CLEAN}"')
        self.assertFalse(self.blocked(cmd))

    # --- the harder gap: body read from a file -------------------------------

    def write_temp(self, text):
        fh = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False)
        fh.write(text + "\n")
        fh.close()
        return fh.name

    def test_body_from_a_file_is_resolved_and_scanned(self):
        path = self.write_temp(f"This reply mentions {FLAGGED}.")
        cmd = ("gh api repos/pied-piper/middle-out/pulls/4242/comments -X POST "
               f"-F body=@{path}")
        self.assertTrue(self.blocked(cmd))

    def test_clean_body_from_a_file_passes(self):
        path = self.write_temp(CLEAN)
        cmd = ("gh api repos/pied-piper/middle-out/pulls/4242/comments -X POST "
               f"-F body=@{path}")
        self.assertFalse(self.blocked(cmd))

    def test_lowercase_f_flag_with_a_file_is_also_resolved(self):
        path = self.write_temp(f"This reply mentions {FLAGGED}.")
        cmd = f"gh api repos/pied-piper/middle-out/issues/4242/comments -f body=@{path}"
        self.assertTrue(self.blocked(cmd))

    def test_a_missing_body_file_does_not_raise(self):
        cmd = ("gh api repos/pied-piper/middle-out/pulls/4242/comments "
               "-F body=@/nonexistent/nowhere.md")
        self.assertFalse(self.blocked(cmd))

    # --- commands that must stay untouched ----------------------------------

    def test_reading_a_pr_body_is_not_scanned(self):
        self.assertFalse(self.blocked("gh api repos/pied-piper/middle-out/pulls/4242 --jq .body"))

    def test_searching_for_a_banned_word_is_not_scanned(self):
        self.assertFalse(self.blocked(f'grep -rn "{FLAGGED}" app/'))


if __name__ == "__main__":
    unittest.main(verbosity=2)
