# frozen_string_literal: true

require "shellwords"
require_relative "tidy_repo_helper"

class RequireTidyTest < Minitest::Test
  include TidyRepo

  def gate(command, cwd, extra = {})
    input = { "hook_event_name" => "PreToolUse", "tool_name" => "Bash", "cwd" => cwd,
              "tool_input" => { "command" => command } }.merge(extra)
    run_hook("require-tidy.rb", input)&.dig("hookSpecificOutput", "permissionDecisionReason")
  end

  def stage(root, name)
    write(root, name)
    git!(root, "add", name)
  end

  def head(root)
    git!(root, "rev-parse", "HEAD")
  end

  def test_commit_with_staged_ruby_and_no_pass_is_denied
    with_repo do |root|
      stage(root, "app/models/codec.rb")
      reason = gate("git commit -m 'Add codec'", root)
      assert_includes reason, "/tidy #{root} git diff #{head(root)}"
    end
  end

  def test_a_denial_is_logged_with_its_session_and_arguments
    with_repo do |root|
      stage(root, "app/models/codec.rb")
      gate("git commit -m 'Add codec'", root, "session_id" => "s1", "agent_id" => "a1")
      assert_equal [{ "event" => "deny", "kind" => "commit", "repo" => root, "sha" => head(root),
                      "tidy_command" => "/tidy #{root} git diff #{head(root)}", "session_id" => "s1", "agent_id" => "a1" }],
                   events
    end
  end

  def test_a_denial_explains_why_the_last_tidy_run_did_not_count
    with_repo do |root|
      stage(root, "app/models/codec.rb")
      narrowed = "#{root} git diff --cached #{head(root)} -- app/models"
      TidyPasses.log_event("skip", "reason" => "not a git diff", "args" => narrowed, "session_id" => "s1")
      reason = gate("git commit -m 'Add codec'", root, "session_id" => "s1")
      assert_includes reason, "Your last /tidy run here did not count (not a git diff): it was given `#{narrowed}`."
      assert_operator reason.index("/tidy #{root} git diff #{head(root)}`"), :<, reason.index("did not count")
      refute_includes gate("git commit -m 'Add codec'", root, "session_id" => "s2"), "did not count"
    end
  end

  def test_a_push_denial_explains_a_skipped_run_too
    with_repo do |root|
      git!(root, "checkout", "-q", "-b", "codec-picker")
      commit(root, "app/models/codec.rb")
      TidyPasses.log_event("skip", "reason" => "missing sections", "args" => "#{root} git diff x", "session_id" => "s1")
      reason = gate("git push -u origin codec-picker", root, "session_id" => "s1")
      assert_includes reason, "did not count: it ended without its Removals and Out of scope sections."
      refute_includes reason, "git diff x"
    end
  end

  def test_a_damaged_event_log_does_not_lift_a_denial
    with_repo do |root|
      stage(root, "app/models/codec.rb")
      FileUtils.mkdir_p(TidyPasses.state_dir)
      File.write(TidyPasses.events_path, "5\n[1]\nnot json\n")
      refute_nil gate("git commit -m 'Add codec'", root, "session_id" => "s1")
    end
  end

  def test_quoted_arguments_lose_their_backticks
    with_repo do |root|
      stage(root, "app/models/codec.rb")
      TidyPasses.log_event("skip", "reason" => "not a git diff", "args" => "`#{root} git diff HEAD`", "session_id" => "s1")
      assert_includes gate("git commit -m 'Add codec'", root, "session_id" => "s1"), "it was given `#{root} git diff HEAD`."
    end
  end

  def test_a_commit_allowed_by_a_pass_is_logged
    with_repo do |root|
      stage(root, "app/models/codec.rb")
      TidyPasses.for(root).record(head(root))
      gate("git commit -m 'Add codec'", root, "session_id" => "s1")
      assert_equal [{ "event" => "allow", "kind" => "commit", "repo" => root, "sha" => head(root),
                      "session_id" => "s1" }], events
    end
  end

  def test_a_push_denial_is_logged_with_both_shas
    with_repo do |root|
      base = head(root)
      git!(root, "checkout", "-q", "-b", "codec-picker")
      tip = commit(root, "app/models/codec.rb")
      gate("git push -u origin codec-picker", root, "session_id" => "s1")
      assert_equal [%w[deny push], "/tidy #{root} git diff #{base} #{tip}", tip],
                   [events.last.values_at("event", "kind"), events.last["tidy_command"], events.last["sha"]]
    end
  end

  def test_ungated_commands_log_nothing
    with_repo do |root|
      stage(root, "docs/benchmarks.md")
      gate("ls -la", root)
      gate("git status", root)
      gate("git commit -m 'Document benchmarks'", root)
      assert_empty events
    end
  end

  def test_a_hook_error_is_logged
    run_hook("require-tidy.rb", "not json")
    assert_equal({ "event" => "error", "hook" => "require-tidy" }, events.last.slice("event", "hook"))
  end

  def test_add_and_commit_in_one_command_is_gated
    with_repo do |root|
      write(root, "app/models/codec.rb")
      refute_nil gate("git add app/models/codec.rb && git commit -m 'Add codec'", root)
      refute_nil gate("git add -A && git commit -m 'Add codec'", root)
      refute_nil gate("git add . && git commit -m 'Add codec'", root)
    end
  end

  def test_denial_asks_to_stage_new_ruby_files_before_tidy
    with_repo do |root|
      write(root, "app/models/codec.rb")
      reason = gate("git add app/models/codec.rb && git commit -m 'Add codec'", root)
      assert_includes reason, "Stage the new files first: `git -C #{root} add app/models/codec.rb`"
      assert_operator reason.index("add app/models/codec.rb"), :<, reason.index("/tidy #{root}")
    end
  end

  def test_staging_hint_works_from_a_subdirectory_and_escapes_paths
    with_repo("middle out") do |root|
      write(root, "app/models/weissman score.rb")
      FileUtils.mkdir_p(File.join(root, "app"))
      reason = gate("git add 'models/weissman score.rb' && git commit -m 'Add score'", File.join(root, "app"))
      assert_includes reason, Shellwords.join(["git", "-C", root, "add", "app/models/weissman score.rb"])
    end
  end

  def test_tracked_changes_need_no_staging_step
    with_repo do |root|
      commit(root, "app/models/codec.rb")
      write(root, "app/models/codec.rb", "changed\n")
      refute_includes gate("git add app/models/codec.rb && git commit -m 'Change codec'", root), "Stage the new files"
    end
  end

  def test_adding_only_docs_ignores_unrelated_ruby
    with_repo do |root|
      write(root, "app/models/codec.rb")
      write(root, "docs/benchmarks.md")
      assert_nil gate("git add docs/benchmarks.md && git commit -m 'Document benchmarks'", root)
    end
  end

  def test_commit_is_allowed_after_a_commit_pass_on_head
    with_repo do |root|
      stage(root, "app/models/codec.rb")
      TidyPasses.for(root).record(head(root))
      assert_nil gate("git commit -m 'Add codec'", root)
    end
  end

  def test_commit_is_allowed_after_a_branch_pass_whose_tip_is_head
    with_repo do |root|
      stage(root, "app/models/codec.rb")
      TidyPasses.for(root).record("a" * 40, head(root))
      assert_nil gate("git commit -m 'Apply tidy sketches'", root)
    end
  end

  def test_commit_without_ruby_is_allowed
    with_repo do |root|
      stage(root, "docs/benchmarks.md")
      assert_nil gate("git commit -m 'Document benchmarks'", root)
    end
  end

  def test_generated_schema_alone_is_allowed
    with_repo do |root|
      stage(root, "db/schema.rb")
      stage(root, "db/queue_schema.rb")
      assert_nil gate("git commit -m 'Migrate'", root)
    end
  end

  def test_unstaged_ruby_does_not_count_for_a_plain_commit
    with_repo do |root|
      commit(root, "app/models/codec.rb")
      write(root, "app/models/codec.rb", "changed\n")
      stage(root, "docs/benchmarks.md")
      assert_nil gate("git commit -m 'Document benchmarks'", root)
    end
  end

  def test_all_flag_counts_unstaged_tracked_ruby
    with_repo do |root|
      commit(root, "app/models/codec.rb")
      write(root, "app/models/codec.rb", "changed\n")
      refute_nil gate("git commit -am 'Change codec'", root)
      refute_nil gate("git commit --all -m 'Change codec'", root)
    end
  end

  def test_pathspec_counts_unstaged_tracked_ruby
    with_repo do |root|
      commit(root, "app/models/codec.rb")
      write(root, "app/models/codec.rb", "changed\n")
      refute_nil gate("git commit app/models/codec.rb -m 'Change codec'", root)
    end
  end

  def test_amend_accepts_a_pass_on_the_parent
    with_repo do |root|
      parent = head(root)
      commit(root, "app/models/codec.rb")
      stage(root, "app/models/codec.rb")
      assert_includes gate("git commit --amend --no-edit", root), "git diff #{parent}"
      TidyPasses.for(root).record(parent)
      assert_nil gate("git commit --amend --no-edit", root)
    end
  end

  def test_amend_ignores_the_pass_that_let_the_original_commit_through
    with_repo do |root|
      parent = head(root)
      passes = TidyPasses.for(root)
      passes.record(parent)
      amended = commit(root, "app/models/codec.rb")
      committed_at = git!(root, "log", "-1", "--format=%ct").to_i
      File.utime(committed_at - 100, committed_at - 100, File.join(passes.dir, parent))
      stage(root, "app/models/codec.rb")
      assert_includes gate("git commit --amend --no-edit", root), "git diff #{parent}"
      passes.record(amended)
      assert_nil gate("git commit --amend --no-edit", root)
    end
  end

  def test_heredoc_message_mentioning_git_push_on_a_branch_with_ruby
    with_repo do |root|
      git!(root, "checkout", "-q", "-b", "codec-picker")
      commit(root, "app/models/codec.rb")
      stage(root, "docs/benchmarks.md")
      command = "git commit -m \"$(cat <<'EOF'\nDocument benchmarks\n\ngit push origin codec-picker comes next\nEOF\n)\""
      assert_nil gate(command, root)
    end
  end

  def test_message_naming_an_existing_path_does_not_widen_the_scope
    with_repo do |root|
      commit(root, "app/models/codec.rb")
      write(root, "app/models/codec.rb", "formatted\n")
      stage(root, "docs/benchmarks.md")
      assert_nil gate("git commit -m app", root)
    end
  end

  def test_pathspec_commit_counts_only_its_paths
    with_repo do |root|
      commit(root, "app/models/codec.rb")
      commit(root, "docs/benchmarks.md")
      write(root, "app/models/codec.rb", "formatted\n")
      write(root, "docs/benchmarks.md", "changed\n")
      assert_nil gate("git commit docs/benchmarks.md -m 'Document benchmarks'", root)
    end
  end

  def test_signing_key_option_is_not_read_as_all
    with_repo do |root|
      commit(root, "app/models/codec.rb")
      write(root, "app/models/codec.rb", "formatted\n")
      stage(root, "docs/benchmarks.md")
      assert_nil gate("git commit -Sabc123 -m 'Document benchmarks'", root)
    end
  end

  def test_push_on_a_master_trunk_is_gated
    Dir.mktmpdir do |base|
      origin = File.join(base, "origin.git")
      git!(base, "init", "-q", "--bare", "-b", "master", origin)
      root = File.join(base, "repo")
      git!(base, "init", "-q", "-b", "master", root)
      git!(root, "config", "user.name", "t")
      git!(root, "config", "user.email", %w[t example.com].join("@"))
      git!(root, "config", "commit.gpgsign", "false")
      git!(root, "remote", "add", "origin", origin)
      commit(root, "README.md", "base")
      git!(root, "push", "-q", "-u", "origin", "master")
      git!(root, "checkout", "-q", "-b", "codec-picker")
      commit(root, "app/models/codec.rb")
      refute_nil gate("git push -u origin codec-picker", root)
    end
  end

  def test_first_commit_is_allowed
    Dir.mktmpdir do |root|
      git!(root, "init", "-q", "-b", "main")
      stage(root, "app/models/codec.rb")
      assert_nil gate("git commit -m 'Start'", root)
    end
  end

  def test_git_dash_c_and_cd_pick_the_repository
    with_repo do |root|
      stage(root, "app/models/codec.rb")
      refute_nil gate("git -C #{root} commit -m 'Add codec'", @state)
      refute_nil gate("cd #{root} && git commit -m 'Add codec'", @state)
      refute_nil gate("GIT_EDITOR=true git -c core.hooksPath=/dev/null commit -m x", root)
    end
  end

  def test_cd_into_a_path_with_spaces
    with_repo("middle out") do |root|
      stage(root, "app/models/codec.rb")
      refute_nil gate("cd \"#{root}\" && git commit -m 'Add codec'", @state)
    end
  end

  def test_subagent_calls_are_gated_the_same
    with_repo do |root|
      stage(root, "app/models/codec.rb")
      refute_nil gate("git commit -m 'Add codec'", root, "agent_id" => "a1", "agent_type" => "implementer")
    end
  end

  def test_pass_in_another_worktree_does_not_count
    with_repo do |root|
      other = File.join(File.dirname(root), "other")
      git!(root, "worktree", "add", "-q", "--detach", other, "HEAD")
      stage(other, "app/models/codec.rb")
      TidyPasses.for(root).record(head(root))
      refute_nil gate("git commit -m 'Add codec'", other)
    end
  end

  def test_push_without_a_branch_pass_is_denied_with_both_shas
    with_repo do |root|
      base = head(root)
      git!(root, "checkout", "-q", "-b", "codec-picker")
      tip = commit(root, "app/models/codec.rb")
      reason = gate("git push -u origin codec-picker", root)
      assert_includes reason, "/tidy #{root} git diff #{base} #{tip}"
      assert_includes reason, "codec-picker"
    end
  end

  def test_push_is_allowed_with_a_pass_on_the_tip_or_an_ancestor
    with_repo do |root|
      base = head(root)
      git!(root, "checkout", "-q", "-b", "codec-picker")
      tip = commit(root, "app/models/codec.rb")
      TidyPasses.for(root).record(base, tip)
      assert_nil gate("git push -u origin codec-picker", root)
      commit(root, "app/models/corpus.rb")
      assert_nil gate("git push", root)
    end
  end

  def test_push_after_a_rebase_needs_a_new_branch_pass
    with_repo do |root|
      base = head(root)
      git!(root, "checkout", "-q", "-b", "codec-picker")
      tip = commit(root, "app/models/codec.rb")
      TidyPasses.for(root).record(base, tip)
      git!(root, "checkout", "-q", "main")
      commit(root, "docs/benchmarks.md")
      git!(root, "push", "-q", "origin", "main")
      git!(root, "checkout", "-q", "codec-picker")
      git!(root, "rebase", "-q", "main")
      refute_nil gate("git push --force-with-lease origin codec-picker", root)
    end
  end

  def test_push_of_a_branch_without_ruby_is_allowed
    with_repo do |root|
      git!(root, "checkout", "-q", "-b", "benchmark-docs")
      commit(root, "docs/benchmarks.md")
      assert_nil gate("git push -u origin benchmark-docs", root)
    end
  end

  def test_deletes_tags_and_trunk_pushes_are_allowed
    with_repo do |root|
      git!(root, "checkout", "-q", "-b", "codec-picker")
      commit(root, "app/models/codec.rb")
      assert_nil gate("git push origin --delete codec-picker", root)
      assert_nil gate("git push origin :codec-picker", root)
      assert_nil gate("git push --tags", root)
      assert_nil gate("git push origin codec-picker:main", root)
    end
  end

  def test_push_without_origin_is_allowed
    Dir.mktmpdir do |root|
      git!(root, "init", "-q", "-b", "codec-picker")
      git!(root, "config", "user.name", "t")
      git!(root, "config", "user.email", %w[t example.com].join("@"))
      git!(root, "config", "commit.gpgsign", "false")
      commit(root, "app/models/codec.rb")
      assert_nil gate("git push", root)
    end
  end

  def test_heredoc_message_mentioning_git_push
    with_repo do |root|
      git!(root, "checkout", "-q", "-b", "benchmark-docs")
      stage(root, "docs/benchmarks.md")
      command = "git commit -F - <<'EOF'\nDocument benchmarks\n\ngit push origin benchmark-docs comes next\nEOF"
      assert_nil gate(command, root)
    end
  end

  def test_unrelated_commands_and_non_repositories_are_allowed
    with_repo do |root|
      stage(root, "app/models/codec.rb")
      assert_nil gate("ls -la", root)
      assert_nil gate("git status", root)
    end
    Dir.mktmpdir { |dir| assert_nil gate("git commit -m x", dir) }
    assert_nil run_hook("require-tidy.rb", "not json")
  end
end
