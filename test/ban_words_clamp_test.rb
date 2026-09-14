# frozen_string_literal: true

require_relative "ban_words_helper"

class ClampTermTest < Minitest::Test
  def hits(text)
    BanWords.banned_words(text).map(&:downcase)
  end

  def written(path, content)
    BanWords.blocked_words("Write", { "file_path" => path, "content" => content })
  end

  def test_css_clamp_function_passes
    assert_empty hits("font-size: clamp(1.75rem, 3vw + 1rem, 2.5rem);")
  end

  def test_std_clamp_passes
    assert_empty hits("auto v = std::clamp(x, lo, hi);")
  end

  def test_math_clamp_passes
    assert_empty hits("Math.clamp(v, 0, 1)")
  end

  def test_lodash_clamp_passes
    assert_empty hits("_.clamp(n, 0, 10)")
  end

  def test_inflected_call_passes
    assert_empty hits("clamps(a, b)")
  end

  def test_bare_verb_is_flagged
    assert_equal ["clamp"], hits("we clamp the value to the range")
  end

  def test_past_tense_is_flagged
    assert_equal ["clamped"], hits("the width is clamped to 10")
  end

  def test_gerund_is_flagged
    assert_equal ["clamping"], hits("Clamping the width avoids overflow")
  end

  def test_space_before_paren_is_still_prose
    assert_equal ["clamp"], hits("the clamp (a limit) applies")
  end

  def test_new_html_with_css_clamp_is_not_blocked
    assert_empty written("/nonexistent/brief.html", "<style>h1 { font-size: clamp(1rem, 2vw, 2rem); }</style>")
  end

  def test_new_doc_with_prose_clamp_is_blocked
    assert_equal ["clamped"], written("/nonexistent/brief.md", "The retry delay is clamped at 30.")
  end
end

class HitContextTest < Minitest::Test
  def test_context_wraps_each_hit
    text = "#{"x" * 60} the value is clamped at ten #{"y" * 60}"
    assert_equal ["value is clamped at ten yy"], BanWords.hit_contexts(text, ["clamped"], 10)
  end

  def test_context_collapses_whitespace
    assert_equal ["a surface b"], BanWords.hit_contexts("a\n\n  surface\n\tb", ["surface"])
  end

  def test_bash_context_includes_body_file_text
    Dir.mktmpdir do |dir|
      path = File.join(dir, "reply.md")
      File.write(path, "This reply names an affordance here.\n")
      text = BanWords.logged_text("Bash", { "command" => "gh api repos/o/r/pulls/1/comments -X POST -F body=@#{path}" })
      assert_equal 1, BanWords.hit_contexts(text, ["affordance"]).size
      assert_includes BanWords.hit_contexts(text, ["affordance"]).first, "names an affordance here"
    end
  end
end
