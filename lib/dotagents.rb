# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require "time"

module Dotagents
  def self.deep_merge(base, overrides)
    base.merge(overrides) do |_key, old, new|
      old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
    end
  end

  def self.leaf_changes(before, after, path = nil)
    if before.is_a?(Hash) && after.is_a?(Hash)
      (before.keys | after.keys).flat_map { |key| leaf_changes(before[key], after[key], [path, key].compact.join(".")) }
    elsif before.is_a?(Array) && after.is_a?(Array) && before.size == after.size
      before.zip(after).each_with_index.flat_map { |(old, new), i| leaf_changes(old, new, "#{path}[#{i}]") }
    elsif before == after
      []
    else
      [[path, before, after]]
    end
  end

  def self.merge_settings(live, overrides)
    live.merge(overrides) do |key, old, new|
      if key == "hooks"
        Hooks.merge(old, new)
      elsif old.is_a?(Hash) && new.is_a?(Hash)
        deep_merge(old, new)
      else
        new
      end
    end
  end

  module Hooks
    def self.merge(live, overrides)
      live.merge(overrides) { |_event, old_groups, new_groups| merge_groups(old_groups, new_groups) }
    end

    def self.merge_groups(live_groups, override_groups)
      override_groups.reduce(live_groups) do |groups, override|
        index = groups.index { |group| group["matcher"] == override["matcher"] }
        next groups + [override] unless index

        entries = merge_entries(groups[index].fetch("hooks", []), override.fetch("hooks", []))
        groups.dup.tap { |result| result[index] = groups[index].merge("hooks" => entries) }
      end
    end

    def self.merge_entries(live_entries, override_entries)
      override_entries.reduce(live_entries) do |entries, override|
        index = entries.index { |entry| same_command?(entry["command"], override["command"]) }
        next entries + [override] unless index

        entries.dup.tap { |result| result[index] = override }
      end
    end

    def self.same_command?(left, right)
      home_agnostic(left) == home_agnostic(right)
    end

    def self.home_agnostic(command)
      command.to_s
             .gsub(%r{/Users/[^/\s"']+}, "~")
             .gsub(%r{(/[^/\s"']+)\.\w+(?=["'\s]|\z)}, '\1')
    end
  end

  def self.link_entries(source_dir, target_dir, out: $stdout)
    return unless Dir.exist?(source_dir)

    FileUtils.mkdir_p(target_dir)
    Dir.children(source_dir).sort.each do |name|
      source = File.join(source_dir, name)
      target = File.join(target_dir, name)
      next out.puts("ok    #{target}") if linked?(target, source)
      raise "#{target} exists and is not a symlink; move it aside first" if File.exist?(target) && !File.symlink?(target)

      FileUtils.rm_f(target)
      FileUtils.ln_s(source, target)
      out.puts "link  #{target} -> #{source}"
    end
    prune_dangling(source_dir, target_dir, out)
  end

  def self.prune_dangling(source_dir, target_dir, out)
    Dir.children(target_dir).sort.each do |name|
      target = File.join(target_dir, name)
      next unless File.symlink?(target)

      destination = File.readlink(target)
      next unless destination.start_with?("#{source_dir}/") && !File.exist?(destination)

      FileUtils.rm(target)
      out.puts "prune #{target}"
    end
  end

  def self.linked?(target, source)
    File.symlink?(target) && File.readlink(target) == source
  end

  class SettingsOverrides
    def initialize(live_path:, overrides_path:, backup_dir:)
      @live_path = live_path
      @overrides_path = overrides_path
      @backup_dir = backup_dir
    end

    def diff
      return "no changes\n" if changes.empty?

      Dotagents.leaf_changes(live, merged).map do |path, before, after|
        "#{path}\n  before: #{before.to_json}\n  after:  #{after.to_json}\n"
      end.join
    end

    def apply(out: $stdout)
      out.print diff
      return false if changes.empty?

      backup if live_exists?
      write_atomically(JSON.pretty_generate(merged) + "\n")
      true
    end

    private

    def live_exists?
      File.exist?(@live_path)
    end

    def live
      @live ||= live_exists? ? JSON.parse(File.read(@live_path)) : {}
    end

    def overrides
      @overrides ||= JSON.parse(File.read(@overrides_path))
    end

    def merged
      Dotagents.merge_settings(live, overrides)
    end

    def changes
      merged.select { |key, value| live[key] != value }
    end

    def backup
      FileUtils.mkdir_p(@backup_dir)
      stamp = Time.now.strftime("%Y%m%d-%H%M%S")
      FileUtils.cp(@live_path, File.join(@backup_dir, "#{File.basename(@live_path)}.#{stamp}"))
    end

    def write_atomically(content)
      tmp = "#{@live_path}.tmp"
      File.write(tmp, content, perm: live_mode)
      File.rename(tmp, @live_path)
    end

    def live_mode
      live_exists? ? File.stat(@live_path).mode & 0o777 : 0o666
    end
  end

  class Audit
    PATTERNS = {
      "absolute home path" => %r{/Users/\w+},
      "email address" => %r{[\w.+-]+@[\w-]+\.[\w.-]+\w(?![\w.-]*[:/])}
    }.freeze

    Finding = Struct.new(:file, :line, :label)
    GitError = Class.new(StandardError)

    def initialize(root:, terms_path: File.join(root, ".audit-terms"), files: nil, staged: false)
      @root = root
      @terms_path = terms_path
      @files = files
      @staged = staged
    end

    def findings
      files.flat_map { |file| scan(file) }
    end

    def run(out: $stdout)
      unless File.exist?(@terms_path)
        out.puts "audit: #{@terms_path} is missing; copy .audit-terms.example and fill it in"
        return false
      end

      results = findings
      results.each { |f| out.puts "#{f.file}:#{f.line}: #{f.label}" }
      out.puts(results.empty? ? "audit: clean (#{files.size} files)" : "audit: #{results.size} finding(s)")
      results.empty?
    rescue GitError => e
      out.puts "audit: #{e.message}"
      false
    end

    private

    def terms
      @terms ||= File.readlines(@terms_path, chomp: true)
                     .map(&:strip)
                     .reject { |term| term.empty? || term.start_with?("#") }
    end

    def files
      @files ||= @staged ? staged_files : working_tree_files
    end

    def working_tree_files
      git("ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0")
    end

    def staged_files
      git("diff", "--cached", "-z", "--name-only", "--diff-filter=d").split("\0")
    end

    def content(file)
      @staged ? staged_content(file) : working_tree_content(file)
    end

    def staged_content(file)
      git("show", ":#{file}")
    end

    def working_tree_content(file)
      path = File.join(@root, file)
      File.file?(path) ? File.read(path) : ""
    end

    def git(*args)
      out, error, status = Open3.capture3("git", "-C", @root, *args)
      raise GitError, "git #{args.first} failed in #{@root}: #{error.strip}" unless status.success?

      out
    end

    def scan(file)
      body = content(file)
      return [] if binary?(body)

      body.each_line(chomp: true).with_index(1).flat_map do |line, number|
        labels_for(line).map { |label| Finding.new(file, number, label) }
      end
    end

    def labels_for(line)
      term_labels = terms.select { |term| line.downcase.include?(term.downcase) }.map { |term| "term #{term.inspect}" }
      pattern_labels = PATTERNS.select { |_, pattern| line.match?(pattern) }.keys
      term_labels + pattern_labels
    end

    def binary?(body)
      body.byteslice(0, 8_000).include?("\0")
    end
  end

  class CodexReview
    ZERO_SHA = /\A0+\z/

    def self.for(dir)
      out, _err, status = Open3.capture3("git", "-C", dir, "rev-parse", "--show-toplevel", "--absolute-git-dir")
      return nil unless status.success?

      root, git_dir = out.split("\n")
      new(root: root, git_dir: git_dir)
    end

    def initialize(root:, git_dir:)
      @root = root
      @git_dir = git_dir
    end

    def record_dir
      File.join(@git_dir, "codex-review")
    end

    def approved?(sha)
      File.exist?(File.join(record_dir, sha))
    end

    def unapproved(shas)
      shas.reject { |sha| approved?(sha) }
    end

    def pending
      unapproved(unpushed)
    end

    def record!(sha, session:)
      FileUtils.mkdir_p(record_dir)
      record = { "sha" => sha, "subject" => subject(sha), "session" => session,
                 "approved_at" => Time.now.utc.iso8601 }
      File.write(File.join(record_dir, sha), JSON.generate(record) + "\n")
      record
    end

    def unpushed
      git("rev-list", "--reverse", "@{u}..HEAD").to_s.split
    end

    def pushed(local_sha, remote_sha, remote_name)
      exclude = remote_sha.match?(ZERO_SHA) ? ["--not", "--remotes=#{remote_name}"] : ["^#{remote_sha}"]
      git("rev-list", "--reverse", local_sha, *exclude).to_s.split
    end

    def subject(sha)
      git("log", "-1", "--format=%s", sha).to_s.chomp
    end

    def bundle(shas)
      shas.map do |sha|
        message = git("log", "-1", "--format=%B", sha).to_s
        patch = git("show", "--stat", "--patch", "--format=", sha).to_s
        "# Commit #{sha}\n\n## Message\n\n```\n#{message}```\n\n## Patch\n\n```diff\n#{patch}```\n"
      end.join("\n")
    end

    private

    def git(*args)
      out, _err, status = Open3.capture3("git", "-C", @root, *args)
      status.success? ? out : nil
    end
  end
end
