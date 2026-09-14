#!/usr/bin/env ruby
# frozen_string_literal: true

# PreToolUse hook: deny newly authored text that uses vague filler nouns.
# Rules, override and logging are described in README.md under "Banned words".

require "digest"
require "json"
require "time"

module BanWords
  BANNED_TERMS = [
    "surfaces?",
    "affordances?",
    "load[-\\s]?bearing",
    "(?<![.:])clamp(?:s|ed|ing)?(?!\\()"
  ].freeze
  BANNED = /\b(?:#{BANNED_TERMS.join("|")})\b/i

  EXEMPT_PATH = %r{/\.claude/(?:hooks|settings)|/(?:CLAUDE|AGENTS|GEMINI)(?:\.[^/]*)?\.md\z}i
  HOOK_DIR = File.dirname(File.realpath(__FILE__))

  GIT_COMMIT = /\bgit\b[^|;&]*\bcommit\b/
  GH_PR_WRITE = /\bgh\s+pr\s+(?:create|edit|comment|review)\b/
  GH_API_WRITE = %r{\bgh\s+api\b[^|;&]*?(?:/(?:comments|reviews)\b|(?:-X|--method)\s*(?:POST|PATCH|PUT)\b)}i
  GH_BODY_FILE = /-{1,2}[fF]\s+\w+=@(\S+)/
  BODY_FILE_FLAG = /(?:--body-file|--input|--file|-F)\s+(?!\S*=)([^\s'"]+)/

  MAX_BASELINE_BYTES = 2_000_000
  CONFIRM_WINDOW = 900

  REASON =
    "ban-words hook: your new text introduces %s. Per-word rules:\n" \
    "- surface/affordance/load-bearing: banned as NOUNS naming a thing; rename precisely: " \
    "surface -> area / region / page / view / route / panel / section / API; " \
    "affordance -> button / link / control / toggle / menu / option; " \
    "load-bearing -> critical / required / relied-on / unsafe-to-remove. " \
    "A VERB use (e.g. \"react-router surfaces the request\" = exposes / reveals) or a real " \
    "existing domain term is fine -- do NOT downgrade to a weaker word; RE-RUN this exact " \
    "tool call unchanged and it passes.\n" \
    "- clamp (any form): banned as verb AND noun -- the word hides which direction the limit " \
    "works. Say the direction and outcome instead: floor -> \"raised to the minimum\" / " \
    "\"won't go below X\" / \"at least X\"; ceiling -> \"capped at X\" / \"lowered to the " \
    "maximum\" / \"at most X\"; both -> \"kept within X..Y\" / \"pinned into the range\". " \
    "A real API name in call syntax (CSS clamp(), std::clamp, _.clamp, Math.clamp) never " \
    "triggers; if the word is genuinely unavoidable, RE-RUN this exact tool call unchanged " \
    "and it passes.\n" \
    "(Sanctioned confirm; never split or obfuscate a word to dodge the check. Never triggers " \
    "anyway: the verbs 'surfacing'/'surfaced', call syntax like clamp( or std::clamp, compound " \
    "identifiers like surfaceTint or scrollClampGuard, and words already present in the " \
    "file being edited.)"

  class << self
    attr_accessor :log_path, :pending_path
  end
  self.log_path = ENV["BAN_WORDS_LOG"] || File.expand_path("~/.claude/ban-words.log")
  self.pending_path = ENV["BAN_WORDS_PENDING"] || File.expand_path("~/.claude/.ban-words-pending.json")

  module_function

  def exempt?(path)
    return false if path.nil? || path.empty?
    return true if EXEMPT_PATH.match?(path)

    real = real_path(File.expand_path(path))
    real == HOOK_DIR || real.start_with?("#{HOOK_DIR}/")
  end

  def real_path(path)
    File.realdirpath(path)
  rescue SystemCallError
    path
  end

  def banned_words(text)
    (text || "").scan(BANNED).each_with_object({}) { |word, seen| seen[word.downcase] ||= word }.values
  end

  def read_baseline(path)
    return "" if path.nil? || path.empty? || File.size(path) > MAX_BASELINE_BYTES

    File.read(path, encoding: "UTF-8").scrub("")
  rescue SystemCallError
    ""
  end

  def newly_introduced(new_text, baseline)
    existing = banned_words(baseline).map(&:downcase)
    banned_words(new_text).reject { |word| existing.include?(word.downcase) }
  end

  def scanned_new_text(tool, tool_input)
    case tool
    when "Write" then tool_input["content"] || ""
    when "Edit", "MultiEdit"
      parts = [tool_input["new_string"]] + (tool_input["edits"] || []).map { |edit| edit["new_string"] }
      parts.reject { |part| part.nil? || part.empty? }.join("\n")
    when "Bash" then tool_input["command"] || ""
    else ""
    end
  end

  def resolved_body_files(cmd)
    paths = cmd.scan(GH_BODY_FILE).flatten + cmd.scan(BODY_FILE_FLAG).flatten
    texts = paths.filter_map do |path|
      File.read(File.expand_path(path), MAX_BASELINE_BYTES, encoding: "UTF-8").to_s.scrub
    rescue SystemCallError
      nil
    end
    texts.empty? ? "" : "\n#{texts.join("\n")}"
  end

  def blocked_words(tool, tool_input)
    case tool
    when "Write", "Edit", "MultiEdit"
      path = tool_input["file_path"].to_s
      return [] if exempt?(path)

      newly_introduced(scanned_new_text(tool, tool_input), read_baseline(path))
    when "Bash"
      cmd = tool_input["command"] || ""
      return [] unless GIT_COMMIT.match?(cmd) || GH_PR_WRITE.match?(cmd) || GH_API_WRITE.match?(cmd)

      banned_words(cmd + resolved_body_files(cmd))
    else
      []
    end
  end

  def confirm_key(data, tool, tool_input)
    signature = [data["session_id"] || "", tool, tool_input["file_path"] || "", scanned_new_text(tool, tool_input)].join("\0")
    Digest::SHA256.hexdigest(signature.encode("UTF-8", invalid: :replace, undef: :replace))
  end

  def private_open(path, mode)
    flags = File::WRONLY | File::CREAT | File::NOFOLLOW | (mode.include?("a") ? File::APPEND : File::TRUNC)
    File.open(path, flags, 0o600) do |file|
      file.chmod(0o600)
      yield file
    end
  end

  def confirm_pending(key)
    now = Time.now.to_f
    pending = begin
      JSON.parse(File.read(pending_path))
    rescue SystemCallError, JSON::ParserError
      {}
    end
    pending = {} unless pending.is_a?(Hash)
    pending = pending.select { |_, stamp| stamp.is_a?(Numeric) && now - stamp < CONFIRM_WINDOW }
    already = pending.key?(key)
    if already
      pending.delete(key)
    else
      pending[key] = now
    end
    private_open(pending_path, "w") { |file| file.write(JSON.generate(pending)) }
    already
  rescue StandardError
    false
  end

  def logged_text(tool, tool_input)
    text = scanned_new_text(tool, tool_input)
    text += resolved_body_files(text) if tool == "Bash"
    text
  end

  def hit_contexts(text, hits, radius = 40)
    hits.filter_map do |word|
      match = /\b#{Regexp.escape(word)}\b/i.match(text || "")
      next unless match

      start = [0, match.begin(0) - radius].max
      text[start...(match.end(0) + radius)].split.join(" ")
    end
  end

  def log_event(data, hits, action)
    tool = data["tool_name"] || ""
    tool_input = data["tool_input"] || {}
    where = tool_input["file_path"]
    where = (tool_input["command"] || "")[0, 120] if where.nil? && tool == "Bash"
    entry = {
      "ts" => Time.now.iso8601,
      "action" => action,
      "tool" => tool,
      "words" => hits,
      "context" => hit_contexts(logged_text(tool, tool_input), hits),
      "where" => where,
      "cwd" => data["cwd"],
      "session" => (data["session_id"] || "")[0, 8]
    }
    private_open(log_path, "a") { |file| file.puts(JSON.generate(entry)) }
  rescue StandardError
    nil
  end

  def main(input = $stdin, output = $stdout)
    data = JSON.parse(input.read)
    return unless data.is_a?(Hash)

    tool = data["tool_name"] || ""
    tool_input = data["tool_input"] || {}
    hits = blocked_words(tool, tool_input)
    return if hits.empty?

    if confirm_pending(confirm_key(data, tool, tool_input))
      log_event(data, hits, "override")
      return
    end

    log_event(data, hits, "block")
    words = hits.map { |word| "\"#{word}\"" }.join(", ")
    output.puts JSON.generate({
      "hookSpecificOutput" => {
        "hookEventName" => "PreToolUse",
        "permissionDecision" => "deny",
        "permissionDecisionReason" => format(REASON, words)
      }
    })
  rescue JSON::ParserError
    nil
  end
end

BanWords.main if __FILE__ == $PROGRAM_NAME
