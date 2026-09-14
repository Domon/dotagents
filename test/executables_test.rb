# frozen_string_literal: true

require "minitest/autorun"

class ExecutablesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_every_hook_and_script_is_executable
    files = Dir[File.join(ROOT, "claude", "{hooks,scripts}", "*")]
    refute_empty files
    files.each { |file| assert File.executable?(file), "#{file} is not executable" }
  end

  def test_every_hook_and_script_has_a_shebang
    Dir[File.join(ROOT, "claude", "{hooks,scripts}", "*")].each do |file|
      assert_match(/\A#!/, File.read(file, 2), "#{file} has no shebang")
    end
  end
end
