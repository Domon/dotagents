# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "time"

class TidyPasses
  MISSING_SECTIONS = "missing sections"

  def self.state_dir
    base = ENV["XDG_STATE_HOME"].to_s
    File.join(base.empty? ? File.expand_path("~/.local/state") : base, "dotagents", "tidy")
  end

  def self.for(dir)
    return nil unless dir && File.directory?(dir)

    out, _err, status = Open3.capture3("git", "-C", dir, "rev-parse", "--show-toplevel")
    status.success? ? new(File.realpath(out.chomp)) : nil
  end

  def self.events_path
    File.join(state_dir, "events.jsonl")
  end

  def self.events
    parsed = File.readlines(events_path).filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
    parsed.grep(Hash)
  rescue SystemCallError
    []
  end

  def self.skip_since_last_pass(session_id, repo)
    return nil unless session_id

    events.reverse_each do |event|
      next unless event["session_id"] == session_id
      return nil if event["event"] == "record" && event["repo"] == repo
      return event if event["event"] == "skip" && event["args"].include?(repo)
    end
    nil
  end

  def self.log_error(hook, exception)
    log_event("error", "hook" => hook, "message" => "#{exception.class}: #{exception.message}")
  end

  def self.log_event(name, fields = {})
    FileUtils.mkdir_p(state_dir)
    line = JSON.generate({ "at" => Time.now.utc.iso8601, "event" => name }.merge(fields.compact))
    File.open(events_path, "a") { |file| file.puts(line) }
    nil
  rescue SystemCallError
    nil
  end

  attr_reader :toplevel

  def initialize(toplevel)
    @toplevel = toplevel
  end

  def dir
    File.join(self.class.state_dir, Digest::SHA256.hexdigest(toplevel)[0, 16])
  end

  def record(base, tip = nil, details = {})
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, [base, tip].compact.join("-")), "#{JSON.generate(details)}\n")
  end

  def pass_since?(head, recorded_after: nil)
    pass_files(head).any? { |path| recorded_after.nil? || File.mtime(path).to_i >= recorded_after }
  end

  def branch_tips(base)
    branch_passes.filter_map { |pass_base, tip| tip if pass_base == base }
  end

  private

  def pass_files(head)
    names = [head] + branch_passes.filter_map { |base, tip| "#{base}-#{tip}" if tip == head }
    names.map { |name| File.join(dir, name) }.select { |path| File.exist?(path) }
  end

  def branch_passes
    return [] unless Dir.exist?(dir)

    Dir.children(dir).filter_map { |name| name.split("-", 2) if name.include?("-") }
  end
end
