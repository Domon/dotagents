# frozen_string_literal: true

require "rake/testtask"
require_relative "lib/dotagents"

CLAUDE_HOME = File.expand_path("~/.claude")

task default: :install

desc "Link scripts and hooks into ~/.claude, apply settings overrides, enable git hooks"
task install: %w[link settings:overrides githooks]

LINKED_DIRS = %w[scripts hooks].freeze

desc "Symlink each file in claude/{#{LINKED_DIRS.join(',')}} into the same directory under ~/.claude"
task :link do
  LINKED_DIRS.each do |dir|
    Dotagents.link_entries(File.join(__dir__, "claude", dir), File.join(CLAUDE_HOME, dir))
  end
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

namespace :audit do
  desc "Run the audit against staged content only, as the pre-commit hook does"
  task :staged do
    exit 1 unless Dotagents::Audit.new(root: __dir__, staged: true).run
  end
end

Rake::TestTask.new(:test) { |t| t.pattern = "test/*_test.rb" }

def codex_review
  Dotagents::CodexReview.for(__dir__) || abort("review: not a git repository")
end

namespace :review do
  desc "List unpushed commits and whether Codex has approved each"
  task :status do
    review = codex_review
    review.unpushed.each do |sha|
      puts "#{review.approved?(sha) ? 'approved' : 'pending '} #{sha[0, 7]} #{review.subject(sha)}"
    end
  end

  desc "Print the pending commits, message and patch, for the reviewer"
  task :bundle do
    review = codex_review
    abort "review: nothing pending" if review.pending.empty?
    print review.bundle(review.pending)
  end

  desc "Record Codex approval for every unpushed commit; SESSION=<codex session id>"
  task :record do
    session = ENV.fetch("SESSION") { abort "review: set SESSION to the Codex session id" }
    review = codex_review
    review.unpushed.each do |sha|
      review.record!(sha, session: session)
      puts "approved #{sha[0, 7]} #{review.subject(sha)}"
    end
  end
end
