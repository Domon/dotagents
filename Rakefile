# frozen_string_literal: true

require "rake/testtask"
require_relative "lib/dotagents"

CLAUDE_HOME = File.expand_path("~/.claude")

task default: :install

desc "Link scripts into ~/.claude, apply settings overrides, enable git hooks"
task install: %w[link settings:overrides githooks]

desc "Symlink each file in claude/scripts into ~/.claude/scripts"
task :link do
  Dotagents.link_entries(File.join(__dir__, "claude", "scripts"), File.join(CLAUDE_HOME, "scripts"))
end

desc "Point core.hooksPath at .githooks so rake audit runs before every commit"
task :githooks do
  sh "git", "config", "core.hooksPath", ".githooks"
end

def settings_overrides
  Dotagents::SettingsOverrides.new(
    live_path: File.join(CLAUDE_HOME, "settings.json"),
    overrides_path: File.join(__dir__, "claude", "settings.overrides.json"),
    backup_dir: File.join(CLAUDE_HOME, "backups")
  )
end

namespace :settings do
  desc "Merge claude/settings.overrides.json into ~/.claude/settings.json (backs up first)"
  task :overrides do
    settings_overrides.apply
  end

  desc "Show what settings:overrides would change without writing"
  task :diff do
    print settings_overrides.diff
  end
end

desc "Fail if any tracked or untracked file contains a term from .audit-terms, an absolute /Users path, or an email"
task :audit do
  exit 1 unless Dotagents::Audit.new(root: __dir__).run
end

Rake::TestTask.new(:test) { |t| t.pattern = "test/*_test.rb" }
