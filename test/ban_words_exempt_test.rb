# frozen_string_literal: true

require_relative "ban_words_helper"

class ExemptPathTest < Minitest::Test
  def test_files_beside_the_hooks_real_location_are_exempt
    assert BanWords.exempt?(File.join(BanWords::HOOK_DIR, "neighbour.rb"))
  end

  def test_the_hook_itself_reached_through_a_symlink_is_exempt
    Dir.mktmpdir do |dir|
      link = File.join(dir, "ban-words-link.rb")
      File.symlink(File.join(BanWords::HOOK_DIR, "ban-words.rb"), link)
      assert BanWords.exempt?(link)
    end
  end

  def test_claude_config_and_agent_instruction_files_are_exempt
    assert BanWords.exempt?("/tmp/home/.claude/settings.json")
    assert BanWords.exempt?("/tmp/home/.claude/hooks/other.sh")
    assert BanWords.exempt?("/tmp/middle-out/AGENTS.md")
  end

  def test_ordinary_paths_are_not_exempt
    refute BanWords.exempt?("/tmp/middle-out/app/models/user.rb")
    refute BanWords.exempt?("")
    refute BanWords.exempt?(nil)
  end
end
