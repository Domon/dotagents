# frozen_string_literal: true

require_relative "ban_words_helper"

class PrivateFilesTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @log = File.join(@dir, "ban-words.log")
    @pending = File.join(@dir, "pending.json")
    @saved = [BanWords.log_path, BanWords.pending_path]
    BanWords.log_path = @log
    BanWords.pending_path = @pending
  end

  def teardown
    BanWords.log_path, BanWords.pending_path = @saved
    FileUtils.remove_entry(@dir)
  end

  def mode(path)
    File.stat(path).mode & 0o777
  end

  def log_once
    BanWords.log_event({ "tool_name" => "Write", "tool_input" => { "content" => "x" } }, ["x"], "block")
  end

  def test_log_is_created_owner_only
    log_once
    assert_equal 0o600, mode(@log)
  end

  def test_pending_state_is_created_owner_only
    BanWords.confirm_pending("k")
    assert_equal 0o600, mode(@pending)
  end

  def test_a_symlinked_log_path_is_refused
    target = File.join(@dir, "elsewhere.log")
    File.symlink(target, @log)
    log_once
    refute File.exist?(target)
  end

  def test_existing_world_readable_log_is_tightened
    File.write(@log, "old\n")
    File.chmod(0o644, @log)
    log_once
    assert_equal 0o600, mode(@log)
    assert_equal "old", File.readlines(@log, chomp: true).first
  end

  def test_second_identical_key_within_the_window_confirms
    refute BanWords.confirm_pending("k")
    assert BanWords.confirm_pending("k")
    refute BanWords.confirm_pending("k")
  end
end
