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

  def test_diff_lists_only_changed_top_level_keys
    diff = subject.diff
    assert_includes diff, "statusLine"
    refute_includes diff, "model"
  end
end

class AuditTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    File.write(File.join(@dir, ".audit-terms"), "# comment\nAcme Corp\n\nPROJ-\n")
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

  def test_flags_terms_case_insensitively_with_line_numbers
    file = write("a.md", "fine\nsee acme corp ticket PROJ-12\n")
    labels = audit(file).findings.map { |f| [f.line, f.label] }
    assert_equal [[2, 'term "Acme Corp"'], [2, 'term "PROJ-"']], labels
  end

  def test_flags_absolute_home_paths_and_emails
    file = write("b.sh", "cd /Users/someone/x\nmail someone@example.com\n") # audit:allow
    assert_equal ["absolute home path", "email address"], audit(file).findings.map(&:label)
  end

  def test_ssh_urls_are_not_emails
    file = write("r.md", "git clone git@github.com:someone/repo.git\nscp x user@host:/tmp\n")
    assert_empty audit(file).findings
  end

  def test_allow_marker_skips_a_line
    file = write("t.rb", "flag /Users/someone here # audit:allow\n")
    assert_empty audit(file).findings
  end

  def test_clean_file_passes_and_binary_is_skipped
    clean = write("c.txt", "nothing here\n")
    binary = write("d.bin", "acme corp\0\xFF".b)
    assert audit(clean, binary).run(out: StringIO.new)
  end

  def test_missing_terms_file_fails
    File.delete(File.join(@dir, ".audit-terms"))
    out = StringIO.new
    refute audit.run(out: out)
    assert_includes out.string, "missing"
  end
end
