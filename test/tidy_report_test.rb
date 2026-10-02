# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../lib/dotagents"

class TidyReportTest < Minitest::Test
  HOME = "/home/submitter"
  REPO = "/home/submitter/src/middle-out"
  OTHER = "/home/submitter/src/pied-piper-site"
  NOW = Time.utc(2026, 9, 30, 12, 0, 0)

  def at(minutes_ago)
    (NOW - (minutes_ago * 60)).iso8601
  end

  def report(events)
    Dotagents::TidyReport.new(events, since: NOW - (7 * 86_400), home: HOME).to_s
  end

  def deny(minutes_ago, session:, repo: REPO, kind: "commit", agent: nil)
    { "at" => at(minutes_ago), "event" => "deny", "kind" => kind, "repo" => repo, "sha" => "a" * 40,
      "tidy_command" => "/tidy #{repo} git diff #{'a' * 40}", "session_id" => session, "agent_id" => agent }.compact
  end

  def allow(minutes_ago, session:, repo: REPO, kind: "commit")
    { "at" => at(minutes_ago), "event" => "allow", "kind" => kind, "repo" => repo, "sha" => "a" * 40,
      "session_id" => session }
  end

  def test_counts_denials_releases_passes_skips_and_errors
    text = report([deny(30, session: "s1"), allow(26, session: "s1"),
                   { "at" => at(27), "event" => "record", "repo" => REPO, "base" => "a" * 40 },
                   { "at" => at(20), "event" => "skip", "reason" => "missing sections", "session_id" => "s2" },
                   { "at" => at(10), "event" => "error", "hook" => "require-tidy", "message" => "RuntimeError: boom" }])
    assert_includes text, "1 denied · 1 released · 0 unresolved · 1 pass recorded · 1 skipped · 1 error"
    assert_includes text, "denial to release: median 4m 0s"
    assert_includes text, "missing sections  1"
    assert_includes text, "require-tidy  RuntimeError: boom"
  end

  def test_a_denial_is_released_only_by_a_later_allow_in_the_same_session_repo_and_kind
    text = report([allow(40, session: "s1"), deny(30, session: "s1"), allow(20, session: "s2"),
                   allow(15, session: "s1", kind: "push"), allow(10, session: "s1", repo: OTHER)])
    assert_includes text, "1 denied · 0 released · 1 unresolved"
    clock = Time.iso8601(at(30)).getlocal.strftime("%Y-%m-%d %H:%M")
    assert_includes text, "Unresolved denials\n  #{clock}  ~/src/middle-out  commit  session s1\n" \
                          "    /tidy ~/src/middle-out git diff #{'a' * 40}"
  end

  def test_groups_by_repository_with_home_shortened
    text = report([deny(30, session: "s1"), allow(20, session: "s1"), deny(10, session: "s2", repo: OTHER, agent: "a9")])
    assert_includes text, "~/src/middle-out        1 denied  1 released  0 passes"
    assert_includes text, "~/src/pied-piper-site   1 denied  0 released  0 passes"
    assert_includes text, "commit  session s2  agent a9"
  end

  def test_an_empty_log_says_so
    assert_includes report([]), "No tidy gate events"
  end

  def test_covering_keeps_only_the_window_and_ignores_events_that_are_not_objects
    events = [deny(60 * 24 * 10, session: "old"), 5, [1], { "event" => "deny" }, deny(30, session: "new")]
    text = Dotagents::TidyReport.covering(events, days: 7, now: NOW, home: HOME).to_s
    assert_includes text, "session new"
    refute_includes text, "session old"
  end
end
