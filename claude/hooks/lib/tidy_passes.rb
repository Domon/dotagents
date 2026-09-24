# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "time"

class TidyPasses
  def self.state_dir
    base = ENV["XDG_STATE_HOME"].to_s
    File.join(base.empty? ? File.expand_path("~/.local/state") : base, "dotagents", "tidy")
  end

  def self.for(dir)
    return nil unless dir && File.directory?(dir)

    out, _err, status = Open3.capture3("git", "-C", dir, "rev-parse", "--show-toplevel")
    status.success? ? new(File.realpath(out.chomp)) : nil
  end

  def self.log(message)
    FileUtils.mkdir_p(state_dir)
    File.open(File.join(state_dir, "hook.log"), "a") { |file| file.puts("#{Time.now.utc.iso8601} #{message}") }
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

  def pass_since?(head)
    File.exist?(File.join(dir, head)) || branch_passes.any? { |_base, tip| tip == head }
  end

  def branch_tips(base)
    branch_passes.filter_map { |pass_base, tip| tip if pass_base == base }
  end

  private

  def branch_passes
    return [] unless Dir.exist?(dir)

    Dir.children(dir).filter_map { |name| name.split("-", 2) if name.include?("-") }
  end
end
