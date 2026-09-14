# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/dotagents"

module CodexReviewRepo
  ROOT = File.expand_path("..", __dir__)
  RUBY_PATH = { "PATH" => "#{File.dirname(RbConfig.ruby)}:#{ENV.fetch('PATH')}" }.freeze

  def git(root, *args)
    Open3.capture3(RUBY_PATH, "git", "-C", root, *args)
  end

  def git!(root, *args)
    out, err, status = git(root, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end

  def commit(root, name, message)
    File.write(File.join(root, name), "#{name} #{Time.now.to_f}\n")
    git!(root, "add", name)
    git!(root, "-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", message)
    git!(root, "rev-parse", "HEAD").chomp
  end

  def with_repo
    Dir.mktmpdir do |base|
      origin = File.join(base, "origin.git")
      git!(base, "init", "-q", "--bare", "-b", "main", origin)
      root = File.join(base, "repo")
      git!(base, "clone", "-q", origin, root)
      git!(root, "config", "user.name", "t")
      git!(root, "config", "user.email", %w[t example.com].join("@"))
      git!(root, "config", "commit.gpgsign", "false")
      git!(root, "checkout", "-q", "-b", "main")
      commit(root, "base.txt", "base")
      git!(root, "push", "-q", "-u", "origin", "main")
      yield root, Dotagents::CodexReview.for(root)
    end
  end
end

class CodexReviewTest < Minitest::Test
  include CodexReviewRepo

  def test_for_returns_nil_outside_a_repository
    Dir.mktmpdir { |dir| assert_nil Dotagents::CodexReview.for(dir) }
  end

  def test_unpushed_lists_new_commits_oldest_first
    with_repo do |root, review|
      assert_empty review.unpushed
      a = commit(root, "a.txt", "first")
      b = commit(root, "b.txt", "second")
      assert_equal [a, b], review.unpushed
    end
  end

  def test_unpushed_is_empty_without_an_upstream
    Dir.mktmpdir do |root|
      git!(root, "init", "-q", "-b", "main")
      assert_empty Dotagents::CodexReview.for(root).unpushed
    end
  end

  def test_record_marks_a_sha_approved_and_stores_the_subject
    with_repo do |root, review|
      sha = commit(root, "a.txt", "first")
      refute review.approved?(sha)
      review.record!(sha, session: "sess-1")
      assert review.approved?(sha)
      record = JSON.parse(File.read(File.join(root, ".git", "codex-review", sha)))
      assert_equal({ "sha" => sha, "subject" => "first", "session" => "sess-1" }, record.slice("sha", "subject", "session"))
      assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, record["approved_at"])
    end
  end

  def test_pending_excludes_approved_commits
    with_repo do |root, review|
      a = commit(root, "a.txt", "first")
      b = commit(root, "b.txt", "second")
      review.record!(a, session: "s")
      assert_equal [b], review.pending
      assert_equal [b], review.unapproved([a, b])
    end
  end

  def test_bundle_carries_message_and_patch_per_commit
    with_repo do |root, review|
      sha = commit(root, "a.txt", "Add a\n\nBody line.")
      text = review.bundle([sha])
      assert_includes text, "# Commit #{sha}"
      assert_includes text, "Add a\n\nBody line."
      assert_includes text, "+++ b/a.txt"
    end
  end

  def test_subject_reads_the_first_line
    with_repo do |root, review|
      sha = commit(root, "a.txt", "Add a\n\nBody line.")
      assert_equal "Add a", review.subject(sha)
    end
  end

  def test_pushed_uses_the_remote_object_when_it_exists
    with_repo do |root, review|
      base = git!(root, "rev-parse", "origin/main").chomp
      a = commit(root, "a.txt", "first")
      b = commit(root, "b.txt", "second")
      assert_equal [a, b], review.pushed(b, base, "origin")
    end
  end

  def test_pushed_uses_the_remote_refs_for_a_new_branch
    with_repo do |root, review|
      git!(root, "checkout", "-q", "-b", "feature")
      a = commit(root, "a.txt", "first")
      assert_equal [a], review.pushed(a, "0" * 40, "origin")
    end
  end
end

class PrePushHookTest < Minitest::Test
  include CodexReviewRepo

  def enable_hooks(root)
    git!(root, "config", "core.hooksPath", File.join(ROOT, ".githooks"))
  end

  def test_push_is_refused_while_a_commit_lacks_approval
    with_repo do |root, _review|
      base = git!(root, "rev-parse", "origin/main").chomp
      sha = commit(root, "a.txt", "first")
      enable_hooks(root)
      _out, err, status = git(root, "push", "-q", "origin", "main")
      refute status.success?
      assert_includes err, "#{sha[0, 7]} first"
      assert_includes err, "/codex-review"
      assert_equal base, git!(root, "rev-parse", "origin/main").chomp
    end
  end

  def test_push_proceeds_once_every_commit_is_approved
    with_repo do |root, review|
      a = commit(root, "a.txt", "first")
      b = commit(root, "b.txt", "second")
      review.record!(a, session: "s")
      review.record!(b, session: "s")
      enable_hooks(root)
      _out, err, status = git(root, "push", "-q", "origin", "main")
      assert status.success?, err
      assert_equal b, git!(root, "rev-parse", "origin/main").chomp
    end
  end

  def test_new_branch_is_refused_then_allowed
    with_repo do |root, review|
      git!(root, "checkout", "-q", "-b", "feature")
      sha = commit(root, "a.txt", "first")
      enable_hooks(root)
      _out, _err, status = git(root, "push", "-q", "-u", "origin", "feature")
      refute status.success?
      review.record!(sha, session: "s")
      _out, err, status = git(root, "push", "-q", "-u", "origin", "feature")
      assert status.success?, err
    end
  end

  def test_deleting_a_remote_branch_is_allowed
    with_repo do |root, _review|
      git!(root, "push", "-q", "origin", "main:feature")
      enable_hooks(root)
      _out, err, status = git(root, "push", "-q", "origin", "--delete", "feature")
      assert status.success?, err
    end
  end
end

class StopHookTest < Minitest::Test
  include CodexReviewRepo

  HOOK = File.join(ROOT, ".claude", "hooks", "codex-review-stop.rb")

  def stop(cwd, extra = {})
    input = JSON.generate({ "cwd" => cwd, "hook_event_name" => "Stop" }.merge(extra))
    out, status = Open3.capture2(RbConfig.ruby, HOOK, stdin_data: input)
    assert status.success?, "stop hook must exit 0"
    out.empty? ? nil : JSON.parse(out)
  end

  def test_blocks_while_an_unpushed_commit_lacks_approval
    with_repo do |root, _review|
      sha = commit(root, "a.txt", "first")
      result = stop(root)
      assert_equal "block", result["decision"]
      assert_includes result["reason"], sha[0, 7]
      assert_includes result["reason"], "/codex-review"
    end
  end

  def test_silent_once_every_commit_is_approved
    with_repo do |root, review|
      sha = commit(root, "a.txt", "first")
      review.record!(sha, session: "s")
      assert_nil stop(root)
    end
  end

  def test_silent_with_nothing_unpushed
    with_repo { |root, _review| assert_nil stop(root) }
  end

  def test_silent_on_the_continuation_after_its_own_block
    with_repo do |root, _review|
      commit(root, "a.txt", "first")
      assert_nil stop(root, "stop_hook_active" => true)
    end
  end

  def test_silent_outside_a_repository
    Dir.mktmpdir { |dir| assert_nil stop(dir) }
  end

  def test_malformed_input_is_ignored
    out, status = Open3.capture2(RbConfig.ruby, HOOK, stdin_data: "not json")
    assert status.success?
    assert_empty out
  end
end
