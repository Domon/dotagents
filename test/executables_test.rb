# frozen_string_literal: true

require "minitest/autorun"

class ExecutablesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  FILES = (Dir[File.join(ROOT, "claude", "{hooks,scripts}", "*")] +
           Dir[File.join(ROOT, ".claude", "hooks", "*")] +
           Dir[File.join(ROOT, ".githooks", "*")]).reject { |path| File.directory?(path) }

  def test_every_hook_and_script_is_executable
    refute_empty FILES
    FILES.each { |file| assert File.executable?(file), "#{file} is not executable" }
  end

  def test_every_hook_and_script_has_a_shebang
    FILES.each do |file|
      assert_match(/\A#!/, File.read(file, 2), "#{file} has no shebang")
    end
  end
end
