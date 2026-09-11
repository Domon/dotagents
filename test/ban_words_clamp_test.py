"""Tests for ban-words.py's clamp term. Run: python3 ban_words_clamp_test.py

Call syntax (CSS clamp(), std::clamp, Math.clamp, _.clamp) is an API name and
must pass; the bare word in running text, in any inflection, must be flagged.
"""
import importlib.util
import pathlib
import unittest

HOOK = pathlib.Path(__file__).resolve().parent.parent / "claude" / "hooks" / "ban-words.py"
spec = importlib.util.spec_from_file_location("ban_words", HOOK)
ban_words = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ban_words)


class ClampTermTest(unittest.TestCase):
    def hits(self, text):
        return [w.lower() for w in ban_words.banned_words(text)]

    # --- call syntax passes -------------------------------------------------

    def test_css_clamp_function_passes(self):
        self.assertEqual(self.hits("font-size: clamp(1.75rem, 3vw + 1rem, 2.5rem);"), [])

    def test_std_clamp_passes(self):
        self.assertEqual(self.hits("auto v = std::clamp(x, lo, hi);"), [])

    def test_math_clamp_passes(self):
        self.assertEqual(self.hits("Math.clamp(v, 0, 1)"), [])

    def test_lodash_clamp_passes(self):
        self.assertEqual(self.hits("_.clamp(n, 0, 10)"), [])

    def test_inflected_call_passes(self):
        self.assertEqual(self.hits("clamps(a, b)"), [])

    # --- prose is flagged ---------------------------------------------------

    def test_bare_verb_is_flagged(self):
        self.assertEqual(self.hits("we clamp the value to the range"), ["clamp"])

    def test_past_tense_is_flagged(self):
        self.assertEqual(self.hits("the width is clamped to 10"), ["clamped"])

    def test_gerund_is_flagged(self):
        self.assertEqual(self.hits("Clamping the width avoids overflow"), ["clamping"])

    def test_space_before_paren_is_still_prose(self):
        self.assertEqual(self.hits("the clamp (a limit) applies"), ["clamp"])

    # --- Write arm end to end -----------------------------------------------

    def test_new_html_with_css_clamp_is_not_blocked(self):
        content = "<style>h1 { font-size: clamp(1rem, 2vw, 2rem); }</style>"
        self.assertEqual(
            ban_words.blocked_words("Write", {"file_path": "/nonexistent/brief.html", "content": content}),
            [])

    def test_new_doc_with_prose_clamp_is_blocked(self):
        content = "The retry delay is clamped at 30."
        self.assertEqual(
            ban_words.blocked_words("Write", {"file_path": "/nonexistent/brief.md", "content": content}),
            ["clamped"])


class HitContextTest(unittest.TestCase):
    def test_context_wraps_each_hit(self):
        text = "x" * 60 + " the value is clamped at ten " + "y" * 60
        ctx = ban_words.hit_contexts(text, ["clamped"], radius=10)
        self.assertEqual(ctx, ["value is clamped at ten yy"])

    def test_context_collapses_whitespace(self):
        ctx = ban_words.hit_contexts("a\n\n  surface\n\tb", ["surface"])
        self.assertEqual(ctx, ["a surface b"])

    def test_bash_context_includes_body_file_text(self):
        import tempfile
        fh = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False)
        fh.write("This reply names an affordance here.\n"); fh.close()
        cmd = f"gh api repos/o/r/pulls/1/comments -X POST -F body=@{fh.name}"
        text = ban_words.logged_text("Bash", {"command": cmd})
        [ctx] = ban_words.hit_contexts(text, ["affordance"])
        self.assertIn("names an affordance here", ctx)


if __name__ == "__main__":
    unittest.main(verbosity=2)
