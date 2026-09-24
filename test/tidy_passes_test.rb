# frozen_string_literal: true

require_relative "tidy_repo_helper"

class TidyPassesTest < Minitest::Test
  include TidyRepo

  def test_for_returns_nil_outside_a_repository
    Dir.mktmpdir { |dir| assert_nil TidyPasses.for(dir) }
    assert_nil TidyPasses.for(nil)
    assert_nil TidyPasses.for(File.join(@state, "missing"))
  end

  def test_state_dir_follows_xdg_state_home
    assert_equal File.join(@state, "dotagents", "tidy"), TidyPasses.state_dir
    ENV["XDG_STATE_HOME"] = ""
    assert_equal File.expand_path("~/.local/state/dotagents/tidy"), TidyPasses.state_dir
  end

  def test_a_subdirectory_resolves_to_its_top_level
    with_repo do |root|
      FileUtils.mkdir_p(File.join(root, "app"))
      assert_equal root, TidyPasses.for(File.join(root, "app")).toplevel
    end
  end

  def test_commit_pass_counts_for_its_base
    with_repo do |root|
      head = git!(root, "rev-parse", "HEAD")
      passes = TidyPasses.for(root)
      refute passes.pass_since?(head)
      passes.record(head, nil, "args" => "x")
      assert passes.pass_since?(head)
      assert_equal({ "args" => "x" }, JSON.parse(File.read(File.join(passes.dir, head))))
    end
  end

  def test_branch_pass_counts_for_its_tip_and_is_listed_by_base
    base = "a" * 40
    tip = "b" * 40
    with_repo do |root|
      passes = TidyPasses.for(root)
      passes.record(base, tip)
      assert passes.pass_since?(tip)
      refute passes.pass_since?(base)
      assert_equal [tip], passes.branch_tips(base)
      assert_empty passes.branch_tips(tip)
    end
  end

  def test_worktrees_on_the_same_commit_do_not_share_passes
    with_repo do |root|
      head = git!(root, "rev-parse", "HEAD")
      other = File.join(File.dirname(root), "other")
      git!(root, "worktree", "add", "-q", "--detach", other, "HEAD")
      TidyPasses.for(root).record(head)
      refute TidyPasses.for(other).pass_since?(head)
    end
  end

  def test_log_appends_a_line
    TidyPasses.log("record-tidy-pass RuntimeError: boom")
    assert_match(/Z record-tidy-pass RuntimeError: boom\n\z/, File.read(File.join(TidyPasses.state_dir, "hook.log")))
  end
end
