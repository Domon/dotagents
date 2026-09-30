# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../claude/hooks/lib/tidy_passes"

module TidyRepo
  ROOT = File.expand_path("..", __dir__)

  def setup
    @state = Dir.mktmpdir
    @previous_state = ENV["XDG_STATE_HOME"]
    ENV["XDG_STATE_HOME"] = @state
  end

  def teardown
    ENV["XDG_STATE_HOME"] = @previous_state
    FileUtils.rm_rf(@state)
  end

  def git!(root, *args)
    out, err, status = Open3.capture3("git", "-C", root, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out.chomp
  end

  def write(root, name, body = "#{name} #{Time.now.to_f}\n")
    path = File.join(root, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def commit(root, name, message = "change #{name}")
    write(root, name)
    git!(root, "add", name)
    git!(root, "-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", message)
    git!(root, "rev-parse", "HEAD")
  end

  def with_repo(dirname = "repo")
    Dir.mktmpdir do |base|
      origin = File.join(base, "origin.git")
      git!(base, "init", "-q", "--bare", "-b", "main", origin)
      root = File.join(base, dirname)
      git!(base, "clone", "-q", origin, root)
      git!(root, "config", "user.name", "t")
      git!(root, "config", "user.email", %w[t example.com].join("@"))
      git!(root, "config", "commit.gpgsign", "false")
      git!(root, "checkout", "-q", "-b", "main")
      commit(root, "README.md", "base")
      git!(root, "push", "-q", "-u", "origin", "main")
      git!(root, "remote", "set-head", "origin", "main")
      yield File.realpath(root)
    end
  end

  def events
    path = TidyPasses.events_path
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line).except("at") } : []
  end

  def run_hook(name, input)
    stdin = input.is_a?(String) ? input : JSON.generate(input)
    out, err, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "claude", "hooks", name), stdin_data: stdin)
    assert status.success?, "#{name} must exit 0: #{err}"
    out.empty? ? nil : JSON.parse(out)
  end
end
