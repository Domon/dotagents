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

  def test_events_is_empty_without_a_log
    assert_empty TidyPasses.events
  end

  def test_skip_since_last_pass_finds_the_latest_skip_for_this_session_and_repository
    repo = "/srv/pied-piper/middle-out"
    TidyPasses.log_event("skip", "reason" => "not a git diff", "args" => "#{repo} git diff HEAD", "session_id" => "s1")
    TidyPasses.log_event("skip", "reason" => "missing sections", "args" => "#{repo} git diff #{'a' * 40}", "session_id" => "s1")
    TidyPasses.log_event("skip", "reason" => "not a git diff", "args" => "#{repo} git diff HEAD", "session_id" => "s2")
    TidyPasses.log_event("skip", "reason" => "not a git diff", "args" => "/srv/elsewhere git diff HEAD", "session_id" => "s1")
    assert_equal "missing sections", TidyPasses.skip_since_last_pass("s1", repo)["reason"]
    assert_nil TidyPasses.skip_since_last_pass("s3", repo)
  end

  def test_a_later_pass_clears_the_skip
    repo = "/srv/pied-piper/middle-out"
    TidyPasses.log_event("skip", "reason" => "not a git diff", "args" => "#{repo} git diff HEAD", "session_id" => "s1")
    TidyPasses.log_event("record", "repo" => repo, "base" => "a" * 40, "session_id" => "s1")
    assert_nil TidyPasses.skip_since_last_pass("s1", repo)
  end

  def test_no_session_means_no_skip
    TidyPasses.log_event("skip", "reason" => "not a git diff", "args" => "/srv/x git diff HEAD")
    assert_nil TidyPasses.skip_since_last_pass(nil, "/srv/x")
  end

  def test_events_skips_broken_lines
    TidyPasses.log_event("record", "repo" => "/srv/x")
    File.open(TidyPasses.events_path, "a") { |file| file.puts("not json", "5", "[1]") }
    TidyPasses.log_event("skip", "reason" => "not a git diff", "args" => "/srv/x git diff HEAD", "session_id" => "s1")
    assert_equal %w[record skip], TidyPasses.events.map { |event| event["event"] }
  end

  def test_event_drops_empty_fields
    TidyPasses.log_event("allow", "kind" => "push", "agent_id" => nil)
    refute JSON.parse(File.read(TidyPasses.events_path)).key?("agent_id")
  end
end
