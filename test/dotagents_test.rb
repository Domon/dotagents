# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../lib/dotagents"

class DeepMergeTest < Minitest::Test
  def test_override_wins_on_conflict_and_local_keys_survive
    live = { "statusLine" => { "type" => "command", "command" => "old" }, "env" => { "LOCAL" => "x" } }
    over = { "statusLine" => { "command" => "new", "padding" => 0 } }
    merged = Dotagents.deep_merge(live, over)
    assert_equal({ "type" => "command", "command" => "new", "padding" => 0 }, merged["statusLine"])
    assert_equal({ "LOCAL" => "x" }, merged["env"])
  end

  def test_arrays_are_replaced_not_unioned
    merged = Dotagents.deep_merge({ "hooks" => { "Stop" => ["a"] } }, { "hooks" => { "Stop" => ["b"] } })
    assert_equal ["b"], merged["hooks"]["Stop"]
  end
end

class MergeSettingsTest < Minitest::Test
  HOME = File.join("/Users", "someone")

  def live
    {
      "model" => "m",
      "hooks" => {
        "Stop" => [{ "hooks" => [
          { "type" => "command", "command" => "agent-deck hook-handler" },
          { "type" => "command", "command" => "#{HOME}/.claude/hooks/turn-cost.rb", "timeout" => 15 }
        ] }]
      }
    }
  end

  def tilde_entry
    { "type" => "command", "command" => "~/.claude/hooks/turn-cost.rb", "timeout" => 15, "statusMessage" => "cost" }
  end

  def merge(overrides)
    Dotagents.merge_settings(live, overrides)
  end

  def test_tilde_command_replaces_absolute_one_in_place
    merged = merge({ "hooks" => { "Stop" => [{ "hooks" => [tilde_entry] }] } })
    assert_equal [live["hooks"]["Stop"][0]["hooks"][0], tilde_entry], merged["hooks"]["Stop"][0]["hooks"]
  end

  def test_unknown_command_is_appended
    extra = { "type" => "command", "command" => "echo hi" }
    merged = merge({ "hooks" => { "Stop" => [{ "hooks" => [extra] }] } })
    assert_equal 3, merged["hooks"]["Stop"][0]["hooks"].size
    assert_equal extra, merged["hooks"]["Stop"][0]["hooks"].last
  end

  def test_new_matcher_group_and_new_event_are_added
    merged = merge({ "hooks" => {
      "Stop" => [{ "matcher" => "x", "hooks" => [tilde_entry] }],
      "SessionStart" => [{ "hooks" => [tilde_entry] }]
    } })
    assert_equal [nil, "x"], merged["hooks"]["Stop"].map { |group| group["matcher"] }
    assert_equal [{ "hooks" => [tilde_entry] }], merged["hooks"]["SessionStart"]
  end

  def test_other_keys_still_deep_merge
    merged = merge({ "model" => "n", "env" => { "A" => "1" } })
    assert_equal "n", merged["model"]
    assert_equal({ "A" => "1" }, merged["env"])
    assert_equal live["hooks"], merged["hooks"]
  end

  def test_live_without_hooks_takes_override_hooks
    overrides = { "hooks" => { "Stop" => [{ "hooks" => [tilde_entry] }] } }
    assert_equal overrides["hooks"], Dotagents.merge_settings({ "model" => "m" }, overrides)["hooks"]
  end

  def test_idempotent
    overrides = { "hooks" => { "Stop" => [{ "hooks" => [tilde_entry] }] } }
    once = merge(overrides)
    assert_equal once, Dotagents.merge_settings(once, overrides)
  end

  def test_same_hook_in_another_language_replaces_in_place
    renamed_entry = tilde_entry.merge("command" => "~/.claude/hooks/turn-cost.py")
    merged = merge({ "hooks" => { "Stop" => [{ "hooks" => [renamed_entry] }] } })
    assert_equal ["agent-deck hook-handler", "~/.claude/hooks/turn-cost.py"],
                 merged["hooks"]["Stop"][0]["hooks"].map { |entry| entry["command"] }
  end

  def test_same_name_in_another_directory_is_a_different_hook
    refute Dotagents::Hooks.same_command?("~/.claude/hooks/a.rb", "~/.claude/scripts/a.rb")
    assert Dotagents::Hooks.same_command?("bash ~/.claude/scripts/a.sh", "bash #{HOME}/.claude/scripts/a")
  end
end

class SettingsOverridesTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @live = File.join(@dir, "settings.json")
    @over = File.join(@dir, "settings.overrides.json")
    @backups = File.join(@dir, "backups")
    File.write(@live, JSON.generate({ "model" => "m", "statusLine" => { "type" => "command", "command" => "old" } }))
    File.write(@over, JSON.generate({ "statusLine" => { "type" => "command", "command" => "new" } }))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def subject
    Dotagents::SettingsOverrides.new(live_path: @live, overrides_path: @over, backup_dir: @backups)
  end

  def test_apply_writes_merged_file_keeps_local_keys_and_backs_up
    assert subject.apply(out: StringIO.new)
    written = JSON.parse(File.read(@live))
    assert_equal "new", written.dig("statusLine", "command")
    assert_equal "m", written["model"]
    assert_equal 1, Dir.children(@backups).size
    assert_match(/\Asettings\.json\.\d{8}-\d{6}\z/, Dir.children(@backups).first)
  end

  def test_apply_is_idempotent
    subject.apply(out: StringIO.new)
    refute subject.apply(out: StringIO.new)
    assert_equal 1, Dir.children(@backups).size
  end

  def test_diff_lists_changed_leaves_by_path
    assert_equal "statusLine.command\n  before: \"old\"\n  after:  \"new\"\n", subject.diff
  end

  def test_apply_preserves_permissions_of_live_file
    File.chmod(0o600, @live)
    subject.apply(out: StringIO.new)
    assert_equal 0o600, File.stat(@live).mode & 0o777
  end
end

class LeafChangesTest < Minitest::Test
  def test_recurses_into_hashes_and_same_length_arrays
    before = { "hooks" => { "Stop" => [{ "hooks" => [{ "command" => "a" }, { "command" => "b" }] }] }, "model" => "m" }
    after = { "hooks" => { "Stop" => [{ "hooks" => [{ "command" => "a" }, { "command" => "c" }] }] }, "model" => "m" }
    assert_equal [["hooks.Stop[0].hooks[1].command", "b", "c"]], Dotagents.leaf_changes(before, after)
  end

  def test_arrays_of_different_length_and_new_keys_are_leaves
    assert_equal [["list", [1], [1, 2]], ["added", nil, true]],
                 Dotagents.leaf_changes({ "list" => [1] }, { "list" => [1, 2], "added" => true })
  end
end

class LinkEntriesTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @source = File.join(@dir, "source")
    @target = File.join(@dir, "target")
    FileUtils.mkdir_p(@source)
    File.write(File.join(@source, "a.sh"), "a")
    File.write(File.join(@source, "b.rb"), "b")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def link
    out = StringIO.new
    Dotagents.link_entries(@source, @target, out: out)
    out.string.lines(chomp: true)
  end

  def test_creates_target_dir_and_links_every_source_file
    output = link
    %w[a.sh b.rb].each do |name|
      assert_equal File.join(@source, name), File.readlink(File.join(@target, name))
    end
    assert_equal ["link  #{@target}/a.sh -> #{@source}/a.sh", "link  #{@target}/b.rb -> #{@source}/b.rb"], output
  end

  def test_is_idempotent_and_reports_existing_links_as_ok
    link
    assert_equal ["ok    #{@target}/a.sh", "ok    #{@target}/b.rb"], link
  end

  def test_replaces_symlink_pointing_elsewhere
    FileUtils.mkdir_p(@target)
    File.symlink(File.join(@dir, "stale"), File.join(@target, "a.sh"))
    link
    assert_equal File.join(@source, "a.sh"), File.readlink(File.join(@target, "a.sh"))
  end

  def test_leaves_unrelated_files_in_target_alone
    FileUtils.mkdir_p(@target)
    File.write(File.join(@target, "private.rb"), "mine")
    link
    assert_equal "mine", File.read(File.join(@target, "private.rb"))
  end

  def test_prunes_dangling_links_into_the_source_but_not_others
    FileUtils.mkdir_p(@target)
    File.symlink(File.join(@source, "gone.py"), File.join(@target, "gone.py"))
    File.symlink(File.join(@dir, "elsewhere"), File.join(@target, "foreign"))
    output = link
    assert_includes output, "prune #{@target}/gone.py"
    refute File.symlink?(File.join(@target, "gone.py"))
    assert File.symlink?(File.join(@target, "foreign"))
  end

  def test_refuses_to_overwrite_a_real_file
    FileUtils.mkdir_p(@target)
    File.write(File.join(@target, "a.sh"), "real")
    error = assert_raises(RuntimeError) { link }
    assert_match(/not a symlink/, error.message)
    assert_equal "real", File.read(File.join(@target, "a.sh"))
  end
end

class AuditTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    File.write(File.join(@dir, ".audit-terms"), "# comment\nHooli\n\nHOOLI-\n")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write(name, content)
    File.write(File.join(@dir, name), content)
    name
  end

  def audit(*files)
    Dotagents::Audit.new(root: @dir, files: files)
  end

  def git(root, *args)
    system("git", "-C", root, *args, exception: true)
  end

  def in_git_repo(name = "repo")
    Dir.mktmpdir do |base|
      root = File.join(base, name)
      Dir.mkdir(root)
      git(root, "init", "-q")
      git(root, "config", "user.name", "t")
      git(root, "config", "user.email", %w[t example.com].join("@"))
      git(root, "config", "commit.gpgsign", "false")
      File.write(File.join(root, ".gitignore"), ".audit-terms\n")
      File.write(File.join(root, ".audit-terms"), "Hooli\n")
      yield root
    end
  end

  def test_flags_terms_case_insensitively_with_line_numbers
    file = write("a.md", "fine\nsee hooli ticket HOOLI-12\n")
    labels = audit(file).findings.map { |f| [f.line, f.label] }
    assert_equal [[2, 'term "Hooli"'], [2, 'term "HOOLI-"']], labels
  end

  def test_flags_absolute_home_paths_and_emails
    home = File.join("/Users", "someone", "x")
    email = %w[someone example.com].join("@")
    file = write("b.sh", "cd #{home}\nmail #{email}\n")
    assert_equal ["absolute home path", "email address"], audit(file).findings.map(&:label)
  end

  def test_ssh_urls_are_not_emails
    file = write("r.md", "git clone git@github.com:someone/repo.git\nscp x user@host:/tmp\n")
    assert_empty audit(file).findings
  end

  def test_clean_file_passes_and_binary_is_skipped
    clean = write("c.txt", "nothing here\n")
    binary = write("d.bin", "hooli\0\xFF".b)
    assert audit(clean, binary).run(out: StringIO.new)
  end

  def test_missing_terms_file_fails
    File.delete(File.join(@dir, ".audit-terms"))
    out = StringIO.new
    refute audit.run(out: out)
    assert_includes out.string, "missing"
  end

  def test_lists_files_from_git_when_root_has_spaces
    in_git_repo("has space") do |root|
      File.write(File.join(root, "a.md"), "hooli\n")
      assert_equal ["a.md"], Dotagents::Audit.new(root: root).findings.map(&:file)
    end
  end

  def test_staged_mode_scans_staged_content_not_the_working_tree
    in_git_repo do |root|
      File.write(File.join(root, "a.md"), "hooli\n")
      git(root, "add", "a.md")
      File.write(File.join(root, "a.md"), "fine\n")
      assert_equal ["a.md"], Dotagents::Audit.new(root: root, staged: true).findings.map(&:file)
      assert_empty Dotagents::Audit.new(root: root).findings
    end
  end

  def test_staged_mode_ignores_files_that_are_not_staged
    in_git_repo do |root|
      File.write(File.join(root, "b.md"), "hooli\n")
      assert_empty Dotagents::Audit.new(root: root, staged: true).findings
      assert_equal ["b.md"], Dotagents::Audit.new(root: root).findings.map(&:file)
    end
  end

  def test_staged_mode_scans_a_renamed_and_edited_file_under_its_new_name
    in_git_repo do |root|
      File.write(File.join(root, "old.md"), "fine\n" * 20)
      git(root, "add", "old.md")
      git(root, "commit", "-q", "-m", "base")
      git(root, "mv", "old.md", "new.md")
      File.write(File.join(root, "new.md"), "fine\n" * 20 + "hooli\n")
      git(root, "add", "new.md")
      assert_equal ["new.md"], Dotagents::Audit.new(root: root, staged: true).findings.map(&:file)
    end
  end

  def test_run_fails_when_root_is_not_a_git_repository
    out = StringIO.new
    refute Dotagents::Audit.new(root: @dir).run(out: out)
    assert_includes out.string, "git ls-files failed"
  end
end
