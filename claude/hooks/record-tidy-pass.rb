#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require File.join(File.dirname(File.realpath(__FILE__)), "lib", "tidy_passes")

module RecordTidyPass
  SKILL_LINE = %r{\ABase directory for this skill: .*/skills/tidy/?\z}
  REVIEW_LINE = /^Review: (.+)$/
  GIT_DIFF = /\A(?<path>.+?) git diff (?<base>\h{40})(?: (?<tip>\h{40}))?\z/
  SECTIONS = ["Removals:", "Out of scope"].freeze

  module_function

  def run(input)
    return unless SECTIONS.all? { |section| input["last_assistant_message"].to_s.include?(section) }

    prompt = first_prompt(input["agent_transcript_path"]).to_s
    return unless prompt.lines.first.to_s.chomp.match?(SKILL_LINE)

    args = prompt[REVIEW_LINE, 1].to_s.strip
    match = GIT_DIFF.match(args) or return
    path = File.expand_path(match[:path].gsub(/\A["']|["']\z/, ""))
    passes = TidyPasses.for(path) or return
    return unless passes.toplevel == File.realpath(path)

    passes.record(match[:base], match[:tip], "args" => args, "session_id" => input["session_id"],
                                            "agent_id" => input["agent_id"], "recorded_at" => Time.now.utc.iso8601)
  end

  def first_prompt(path)
    return nil unless path && File.file?(path)

    File.foreach(path) do |line|
      entry = JSON.parse(line)
      next unless entry["type"] == "user"

      content = entry.dig("message", "content")
      return content if content.is_a?(String)

      return Array(content).filter_map { |part| part["text"] if part.is_a?(Hash) }.join("\n")
    end
    nil
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    RecordTidyPass.run(JSON.parse($stdin.read))
  rescue StandardError => e
    TidyPasses.log("record-tidy-pass #{e.class}: #{e.message}")
  end
  exit 0
end
