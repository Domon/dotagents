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

  def test_event_appends_one_json_line
    TidyPasses.log_event("deny", "kind" => "commit", "session_id" => "s1")
    TidyPasses.log_error("record-tidy-pass", RuntimeError.new("boom"))
    first, second = File.readlines(TidyPasses.events_path).map { |line| JSON.parse(line) }
    assert_equal({ "event" => "deny", "kind" => "commit", "session_id" => "s1" }, first.except("at"))
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, first["at"])
    assert_equal "error", second["event"]
  end

  def test_event_drops_empty_fields
    TidyPasses.log_event("allow", "kind" => "push", "agent_id" => nil)
    refute JSON.parse(File.read(TidyPasses.events_path)).key?("agent_id")
  end
end
