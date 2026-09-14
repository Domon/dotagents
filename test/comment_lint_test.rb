# frozen_string_literal: true

# Tests for comment-lint.rb. Run: ruby comment_lint_test.rb

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "../claude/hooks/comment-lint"

class CommentLintTest < Minitest::Test
  HOOK = File.expand_path("../claude/hooks/comment-lint.rb", __dir__)

  # --- run parsing -----------------------------------------------------------

  def test_no_comments_yields_no_runs
    assert_empty CommentLint.comment_runs("const a = 1;\nconst b = 2;\n", ".ts")
  end

  def test_counts_consecutive_slash_lines_as_one_run
    text = "// one\n// two\n// three\nconst a = 1;\n"
    runs = CommentLint.comment_runs(text, ".ts")
    assert_equal 1, runs.size
    assert_equal 3, runs.first[:content_lines]
  end

  def test_jsdoc_delimiters_and_blank_stars_are_not_content
    text = "/**\n * one fact\n *\n * second fact\n */\nexport function f() {}\n"
    runs = CommentLint.comment_runs(text, ".ts")
    assert_equal 1, runs.size
    assert_equal 2, runs.first[:content_lines]
  end

  def test_separated_single_liners_are_separate_runs
    text = "// one\nconst a = 1;\n// two\nconst b = 2;\n// three\nconst c = 3;\n"
    runs = CommentLint.comment_runs(text, ".ts")
    assert_equal 3, runs.size
    assert runs.all? { |r| r[:content_lines] == 1 }
  end

  def test_hash_comments_in_ruby_and_yaml
    assert_equal 3, CommentLint.comment_runs("# a\n# b\n# c\nx = 1\n", ".rb").first[:content_lines]
    assert_equal 3, CommentLint.comment_runs("# a\n# b\n# c\nkey: true\n", ".yml").first[:content_lines]
  end

  def test_trailing_comments_do_not_form_runs
    text = "const a = 1; // why a\nconst b = 2; // why b\nconst c = 3; // why c\n"
    assert_empty CommentLint.comment_runs(text, ".ts")
  end

  # --- decision --------------------------------------------------------------

  def edit_input(new_string, file_path: "/tmp/x/app.ts", session: "s1")
    { "session_id" => session, "tool_name" => "Edit",
      "tool_input" => { "file_path" => file_path, "old_string" => "OLD", "new_string" => new_string } }
  end

  def decide(data)
    Dir.mktmpdir do |dir|
      env = { "COMMENT_LINT_LOG" => File.join(dir, "log"),
              "COMMENT_LINT_PENDING" => File.join(dir, "pending.json") }
      out, status = Open3.capture2(env, RbConfig.ruby, HOOK, stdin_data: JSON.generate(data))
      assert status.success?, "hook must always exit 0"
      out.empty? ? nil : JSON.parse(out)
    end
  end

  def assert_denied(result, mentioning: nil)
    refute_nil result, "expected a deny, got approve"
    assert_equal "deny", result.dig("hookSpecificOutput", "permissionDecision")
    reason = result.dig("hookSpecificOutput", "permissionDecisionReason")
    assert_includes reason, mentioning if mentioning
  end

  def test_approves_two_line_run
    assert_nil decide(edit_input("// one\n// two\nconst a = 1;\n"))
  end

  def test_blocks_three_line_run
    assert_denied decide(edit_input("// one\n// two\n// three\nconst a = 1;\n")), mentioning: "3 consecutive"
  end

  def test_blocks_ruby_wall_in_new_write
    data = { "session_id" => "s1", "tool_name" => "Write",
             "tool_input" => { "file_path" => "/tmp/x/new_model.rb",
                               "content" => "# a\n# b\n# c\n# d\nclass NewModel\nend\n" } }
    assert_denied decide(data), mentioning: "4 consecutive"
  end

  def test_register_word_in_new_comment_blocks
    assert_denied decide(edit_input("// Mirrors the compression tier MiddleOutCard applies.\nreturn null;\n")),
                  mentioning: "mirrors"
  end

  def test_register_word_in_code_approves
    assert_nil decide(edit_input("const mirrors = allMirrors.filter(Boolean);\n"))
  end

  def test_common_first_person_idiom_approves
    assert_nil decide(edit_input("// In test env seeds don't run, so we fall back to a factory.\nconst a = 1;\n"))
  end

  def test_singular_mirror_approves
    assert_nil decide(edit_input("// Each shard must mirror the pied-piper index layout.\nconst a = 1;\n"))
  end

  def test_stories_tsx_exempt
    assert_nil decide(edit_input("// a\n// b\n// c\n// d\n", file_path: "/tmp/x/MiddleOutPanel.stories.tsx"))
  end

  def test_hooks_dir_exempt
    path = File.expand_path("~/.claude/hooks/some-hook.rb")
    assert_nil decide(edit_input("# a\n# b\n# c\n", file_path: path))
  end

  def test_prose_files_approve
    assert_nil decide(edit_input("line\nline\nline\n", file_path: "/tmp/x/notes.md"))
  end

  def test_multiedit_new_strings_are_scanned
    data = { "session_id" => "s1", "tool_name" => "MultiEdit",
             "tool_input" => { "file_path" => "/tmp/x/app.ts",
                               "edits" => [{ "old_string" => "a", "new_string" => "const a = 1;" },
                                           { "old_string" => "b", "new_string" => "// x\n// y\n// z\n" }] } }
    assert_denied decide(data)
  end

  def test_malformed_stdin_approves
    out, status = Open3.capture2(RbConfig.ruby, HOOK, stdin_data: "not json")
    assert status.success?
    assert_empty out
  end

  # --- baseline: pre-existing comments never re-block -------------------------

  def test_run_already_on_disk_approves
    Dir.mktmpdir do |dir|
      wall = "// a\n// b\n// c\n// d\n"
      path = File.join(dir, "app.ts")
      File.write(path, "const before = 1;\n#{wall}const after = 2;\n")
      env = { "COMMENT_LINT_LOG" => File.join(dir, "log"),
              "COMMENT_LINT_PENDING" => File.join(dir, "pending.json") }
      data = edit_input("#{wall}const changed = 3;\n", file_path: path)
      out, status = Open3.capture2(env, RbConfig.ruby, HOOK, stdin_data: JSON.generate(data))
      assert status.success?
      assert_empty out
    end
  end

  # --- confirm-on-resubmit ----------------------------------------------------

  def test_identical_resubmit_overrides_and_both_are_logged
    Dir.mktmpdir do |dir|
      log = File.join(dir, "log")
      env = { "COMMENT_LINT_LOG" => log, "COMMENT_LINT_PENDING" => File.join(dir, "pending.json") }
      stdin = JSON.generate(edit_input("// one\n// two\n// three\n"))

      first, = Open3.capture2(env, RbConfig.ruby, HOOK, stdin_data: stdin)
      assert_equal "deny", JSON.parse(first).dig("hookSpecificOutput", "permissionDecision")

      second, = Open3.capture2(env, RbConfig.ruby, HOOK, stdin_data: stdin)
      assert_empty second

      actions = File.readlines(log).map { |l| JSON.parse(l)["action"] }
      assert_equal %w[block override], actions
    end
  end

  def run_hook(dir, new_string, file_path: "/tmp/x/app.ts")
    env = { "COMMENT_LINT_LOG" => File.join(dir, "log"),
            "COMMENT_LINT_PENDING" => File.join(dir, "pending.json") }
    Open3.capture2(env, RbConfig.ruby, HOOK,
                   stdin_data: JSON.generate(edit_input(new_string, file_path: file_path)))
  end

  def log_record(dir)
    JSON.parse(File.read(File.join(dir, "log")))
  end

  # --- logging for later effectiveness review -------------------------------

  def test_block_log_records_offending_run_text
    Dir.mktmpdir do |dir|
      run_hook(dir, "// alpha\n// beta\n// gamma\n")
      walls = log_record(dir)["walls"]
      assert_equal 3, walls.first["lines"]
      assert_includes walls.first["text"], "beta"
    end
  end

  def test_block_log_records_register_words
    Dir.mktmpdir do |dir|
      run_hook(dir, "// Mirrors the compression tier.\nreturn null;\n")
      assert_equal ["mirrors"], log_record(dir)["words"]
    end
  end

  def test_long_wall_text_is_truncated_in_log
    Dir.mktmpdir do |dir|
      run_hook(dir, Array.new(3) { |i| "// #{i} #{'x' * 300}" }.join("\n") + "\n")
      assert_operator log_record(dir)["walls"].first["text"].length, :<=, 400
    end
  end

  def test_approve_that_adds_comments_logs_a_stat_record
    Dir.mktmpdir do |dir|
      out, = run_hook(dir, "// one\n// two\nconst a = 1;\n")
      assert_empty out
      record = log_record(dir)
      assert_equal "stat", record["action"]
      assert_equal 2, record["new_comment_lines"]
      assert_equal 2, record["max_run"]
    end
  end

  def test_plain_code_edit_logs_nothing
    Dir.mktmpdir do |dir|
      out, = run_hook(dir, "const a = 1;\n")
      assert_empty out
      refute File.exist?(File.join(dir, "log"))
    end
  end

  def test_delimiter_only_comment_logs_no_stat
    Dir.mktmpdir do |dir|
      out, = run_hook(dir, "/**\n */\nconst a = 1;\n")
      assert_empty out
      refute File.exist?(File.join(dir, "log"))
    end
  end

  def test_preexisting_comment_run_logs_no_stat
    Dir.mktmpdir do |dir|
      wall = "// a\n// b\n// c\n// d\n"
      path = File.join(dir, "app.ts")
      File.write(path, "const before = 1;\n#{wall}")
      run_hook(dir, "#{wall}const changed = 2;\n", file_path: path)
      refute File.exist?(File.join(dir, "log"))
    end
  end

  def test_different_text_after_block_blocks_again
    Dir.mktmpdir do |dir|
      env = { "COMMENT_LINT_LOG" => File.join(dir, "log"),
              "COMMENT_LINT_PENDING" => File.join(dir, "pending.json") }
      first_stdin = JSON.generate(edit_input("// one\n// two\n// three\n"))
      Open3.capture2(env, RbConfig.ruby, HOOK, stdin_data: first_stdin)

      second_stdin = JSON.generate(edit_input("// uno\n// dos\n// tres\n"))
      out, = Open3.capture2(env, RbConfig.ruby, HOOK, stdin_data: second_stdin)
      assert_equal "deny", JSON.parse(out).dig("hookSpecificOutput", "permissionDecision")
    end
  end

  # --- private files and hook-dir exemption ----------------------------------

  def modes_after_a_block
    Dir.mktmpdir do |dir|
      log = File.join(dir, "log")
      pending = File.join(dir, "pending.json")
      env = { "COMMENT_LINT_LOG" => log, "COMMENT_LINT_PENDING" => pending }
      stdin = JSON.generate(edit_input("// one\n// two\n// three\n"))
      Open3.capture2(env, RbConfig.ruby, HOOK, stdin_data: stdin)
      yield log, pending
    end
  end

  def test_log_and_pending_state_are_created_owner_only
    modes_after_a_block do |log, pending|
      assert_equal 0o600, File.stat(log).mode & 0o777
      assert_equal 0o600, File.stat(pending).mode & 0o777
    end
  end

  def test_a_symlinked_log_path_is_refused
    Dir.mktmpdir do |dir|
      log = File.join(dir, "log")
      target = File.join(dir, "elsewhere.log")
      File.symlink(target, log)
      env = { "COMMENT_LINT_LOG" => log, "COMMENT_LINT_PENDING" => File.join(dir, "pending.json") }
      stdin = JSON.generate(edit_input("// one\n// two\n// three\n"))
      Open3.capture2(env, RbConfig.ruby, HOOK, stdin_data: stdin)
      refute File.exist?(target)
    end
  end

  def test_files_beside_the_hook_are_exempt
    assert CommentLint.exempt?(File.join(CommentLint::HOOK_DIR, "other-hook.rb"))
    assert CommentLint.exempt?("/elsewhere/.claude/hooks/x.rb")
    refute CommentLint.exempt?("/tmp/x/app.ts")
  end
end
