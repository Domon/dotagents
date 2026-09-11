# frozen_string_literal: true

require "json"
require "fileutils"

module Dotagents
  def self.deep_merge(base, overrides)
    base.merge(overrides) do |_key, old, new|
      old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
    end
  end

  def self.link_entries(source_dir, target_dir, out: $stdout)
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

      changes.map do |key, value|
        "#{key}\n  before: #{live[key].to_json}\n  after:  #{value.to_json}\n"
      end.join
    end

    def apply(out: $stdout)
      out.print diff
      return false if changes.empty?

      backup if File.exist?(@live_path)
      write_atomically(@live_path, JSON.pretty_generate(merged) + "\n")
      true
    end

    private

    def live
      @live ||= File.exist?(@live_path) ? JSON.parse(File.read(@live_path)) : {}
    end

    def overrides
      @overrides ||= JSON.parse(File.read(@overrides_path))
    end

    def merged
      Dotagents.deep_merge(live, overrides)
    end

    def changes
      merged.select { |key, value| live[key] != value }
    end

    def backup
      FileUtils.mkdir_p(@backup_dir)
      stamp = Time.now.strftime("%Y%m%d-%H%M%S")
      FileUtils.cp(@live_path, File.join(@backup_dir, "#{File.basename(@live_path)}.#{stamp}"))
    end

    def write_atomically(path, content)
      tmp = "#{path}.tmp"
      File.write(tmp, content)
      File.rename(tmp, path)
    end
  end

  class Audit
    PATTERNS = {
      "absolute home path" => %r{/Users/\w+},
      "email address" => %r{[\w.+-]+@[\w-]+\.[\w.-]+\w(?![\w.-]*[:/])}
    }.freeze

    ALLOW_MARKER = "audit:allow"

    Finding = Struct.new(:file, :line, :label)

    def initialize(root:, terms_path: File.join(root, ".audit-terms"), files: nil)
      @root = root
      @terms_path = terms_path
      @files = files
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
    end

    private

    def terms
      @terms ||= File.readlines(@terms_path, chomp: true)
                     .map(&:strip)
                     .reject { |term| term.empty? || term.start_with?("#") }
    end

    def files
      @files ||= `git -C #{@root} ls-files -z --cached --others --exclude-standard`.split("\0")
    end

    def scan(file)
      path = File.join(@root, file)
      return [] unless File.file?(path) && text?(path)

      File.foreach(path, chomp: true).with_index(1).flat_map do |line, number|
        next [] if line.include?(ALLOW_MARKER)

        labels_for(line).map { |label| Finding.new(file, number, label) }
      end
    end

    def labels_for(line)
      term_labels = terms.select { |term| line.downcase.include?(term.downcase) }.map { |term| "term #{term.inspect}" }
      pattern_labels = PATTERNS.select { |_, pattern| line.match?(pattern) }.keys
      term_labels + pattern_labels
    end

    def text?(path)
      !File.binread(path, 8_000).to_s.include?("\0")
    end
  end
end
