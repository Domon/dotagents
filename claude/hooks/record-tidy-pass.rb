#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require File.join(File.dirname(File.realpath(__FILE__)), "lib", "tidy_passes")

module RecordTidyPass
  SKILL_LINE = %r{\ABase directory for this skill: .*/skills/tidy/?\z}
  REVIEW_LINE = /^Review: (.+)$/
  TRAILING = %r{[\s`'"—–\-,;:)]*}
  # At most one full stop: `..`, `...`, ^ and ~ after a sha name a different revision range.
  GIT_DIFF = /\A`*(?<path>.+?) git diff (?<base>\h{7,40})(?: (?<tip>\h{7,40}))?#{TRAILING}\.?#{TRAILING}\z/
  SECTIONS = [/^\W*Removals\b/i, /^\W*Out of scope\b/i].freeze

  module_function

  def run(input)
    prompt = first_prompt(input["agent_transcript_path"]).to_s
    return unless prompt.lines.first.to_s.chomp.match?(SKILL_LINE)

    ids = input.slice("session_id", "agent_id")
    args = prompt[REVIEW_LINE, 1].to_s.strip
    message = input["last_assistant_message"].to_s
    return log_skip(TidyPasses::MISSING_SECTIONS, args, ids) unless SECTIONS.all? { |section| message.match?(section) }

    match = GIT_DIFF.match(args) or return log_skip("not a git diff", args, ids)
    path = File.expand_path(match[:path].gsub(/\A["']|["']\z/, ""))
    passes = TidyPasses.for(path)
    return log_skip("not the top level", args, ids) unless passes && passes.toplevel == File.realpath(path)

    shas = match.values_at(:base, :tip).compact.map { |sha| passes.commit_sha(sha) }
    return log_skip("unknown commit", args, ids) if shas.include?(nil)

    base, tip = shas
    passes.record(base, tip, { "args" => args, "recorded_at" => Time.now.utc.iso8601 }.merge(ids))
    TidyPasses.log_event("record", { "repo" => passes.toplevel, "base" => base, "tip" => tip }.merge(ids))
  end

  def log_skip(reason, args, ids)
    TidyPasses.log_event("skip", { "reason" => reason, "args" => args }.merge(ids))
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
    TidyPasses.log_error("record-tidy-pass", e)
  end
  exit 0
end
