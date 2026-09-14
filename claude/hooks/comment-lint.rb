#!/usr/bin/env ruby
# frozen_string_literal: true

# PreToolUse hook (Write|Edit|MultiEdit): stop comment walls at generation time.
#
# Blocks a tool call whose NEW text adds either:
#   - a run of >CAP consecutive whole-line comment content lines, or
#   - a comment line written in the change/review register ("mirrors",
#     "the fix", "previously", ...) — words about this PR, not the code.
#
# Same three protections as ban-words.rb:
#   1. Whole-line comments only; trailing comments never form runs.
#   2. Baseline diff: runs/lines already on disk never re-block, so editing a
#      file that has walls doesn't fight the hook.
#   3. Confirm-on-resubmit: re-running the identical call once passes it
#      through (the rare justified wall), and both events are logged.
#
# Env overrides (used by tests): COMMENT_LINT_LOG, COMMENT_LINT_PENDING.

require "json"
require "digest"

module CommentLint
  CAP = 2 # consecutive comment content lines allowed without a confirm

  HASH_EXTS  = %w[.rb .rake .gemspec .py .sh .bash .zsh .fish .yml .yaml .toml .tf].freeze
  SLASH_EXTS = %w[.ts .tsx .mts .cts .js .jsx .mjs .cjs .go .rs .java .kt .swift .c .h .cpp .hpp .cs].freeze
  CSS_EXTS   = %w[.css .scss .less].freeze
  DASH_EXTS  = %w[.sql].freeze

  EXEMPT_PATH = %r{/\.claude/hooks/|\.stories\.tsx\z}
  HOOK_DIR = File.dirname(File.realpath(__FILE__))

  # "mirrors" (3rd-person verb) only: singular "mirror" and first-person "we"
  # measured too many legitimate uses in existing comments (2026-07-29).
  REGISTER = /\b(?:the fix|previously|note that|this ensures|regression guard|mirrors)\b/i

  MAX_BASELINE_BYTES = 2_000_000
  CONFIRM_WINDOW = 900 # seconds a pending confirm-on-resubmit stays valid

  LOG_PATH = ENV["COMMENT_LINT_LOG"] || File.expand_path("~/.claude/comment-lint.log")
  PENDING_PATH = ENV["COMMENT_LINT_PENDING"] || File.expand_path("~/.claude/.comment-lint-pending.json")

  def self.style_for(ext)
    ext = ext.downcase
    return { line: "#" } if HASH_EXTS.include?(ext)
    return { line: "//", block: true } if SLASH_EXTS.include?(ext)
    return { block: true } if CSS_EXTS.include?(ext)
    return { line: "--" } if DASH_EXTS.include?(ext)

    nil
  end

  # Runs of consecutive whole-line comments in `text`, as
  # [{content_lines:, text:}, ...] where :text is the marker-stripped content
  # (the shape compared against the on-disk baseline).
  def self.comment_runs(text, ext)
    style = style_for(ext)
    return [] unless style

    runs = []
    current = nil
    in_block = false

    text.each_line do |raw|
      line = raw.strip
      content = comment_content(line, style, in_block)
      if content
        in_block = block_continues?(line, style, in_block)
        current ||= { content_lines: 0, lines: [] }
        unless content.empty?
          current[:content_lines] += 1
          current[:lines] << content
        end
      else
        runs << current if current
        current = nil
      end
    end
    runs << current if current

    runs.each { |r| r[:text] = r.delete(:lines).join("\n") }
  end

  # The line's comment content ("" for a bare delimiter), or nil when the line
  # is not a whole-line comment.
  def self.comment_content(line, style, in_block)
    if in_block
      line.sub(%r{\A\*+/?\s*}, "").sub(%r{\s*\*+/.*\z}, "").strip
    elsif style[:line] && line.start_with?(style[:line])
      line.delete_prefix(style[:line]).strip
    elsif style[:block] && line.start_with?("/*")
      line.sub(%r{\A/\*+\s*}, "").sub(%r{\s*\*+/.*\z}, "").strip
    end
  end

  def self.block_continues?(line, style, in_block)
    return false unless style[:block]
    return !line.include?("*/") if in_block

    line.start_with?("/*") && !line.include?("*/")
  end

  def self.scanned_new_text(tool, tool_input)
    return tool_input["content"].to_s if tool == "Write"

    parts = [tool_input["new_string"]]
    (tool_input["edits"] || []).each { |e| parts << e["new_string"] }
    parts.compact.join("\n")
  end

  def self.read_baseline(path)
    return "" if path.nil? || path.empty? || File.size(path) > MAX_BASELINE_BYTES

    File.read(path, encoding: "utf-8")
  rescue StandardError
    ""
  end

  # Comment runs newly introduced by this call, and the violations among them.
  def self.analyze(new_text, baseline, ext)
    old_texts = comment_runs(baseline, ext).map { |r| r[:text] }
    old_lines = old_texts.flat_map { |t| t.split("\n") }
    new_runs = comment_runs(new_text, ext).reject { |r| old_texts.include?(r[:text]) }

    words = new_runs
            .flat_map { |r| r[:text].split("\n") }
            .reject { |l| old_lines.include?(l) }
            .flat_map { |l| l.scan(REGISTER) }
            .map(&:downcase).uniq

    { new_runs: new_runs,
      walls: new_runs.select { |r| r[:content_lines] > CAP },
      words: words }
  end

  def self.confirm_key(data, tool, tool_input)
    sig = [data["session_id"].to_s, tool, tool_input["file_path"].to_s,
           scanned_new_text(tool, tool_input)].join("\0")
    Digest::SHA256.hexdigest(sig)
  end

  # True if `key` was recorded recently (deliberate re-submit -> allow), else
  # record it and return false. Errors degrade to a plain hard block.
  def self.confirm_pending(key)
    now = Time.now.to_f
    pending = begin
      parsed = JSON.parse(File.read(PENDING_PATH))
      parsed.is_a?(Hash) ? parsed : {}
    rescue StandardError
      {}
    end
    pending.select! { |_, t| t.is_a?(Numeric) && now - t < CONFIRM_WINDOW }
    already = pending.key?(key)
    already ? pending.delete(key) : pending[key] = now
    private_open(PENDING_PATH, "w") { |file| file.write(JSON.generate(pending)) }
    already
  rescue StandardError
    false
  end

  def self.exempt?(path)
    return false if path.nil? || path.empty?
    return true if EXEMPT_PATH.match?(path)

    real = begin
      File.realdirpath(File.expand_path(path))
    rescue SystemCallError
      File.expand_path(path)
    end
    real == HOOK_DIR || real.start_with?("#{HOOK_DIR}/")
  end

  def self.private_open(path, mode)
    flags = File::WRONLY | File::CREAT | File::NOFOLLOW | (mode.include?("a") ? File::APPEND : File::TRUNC)
    File.open(path, flags, 0o600) do |file|
      file.chmod(0o600)
      yield file
    end
  end

  def self.log_event(data, action, fields)
    entry = { ts: Time.now.strftime("%FT%T%:z"), action: action,
              tool: data["tool_name"] }.merge(fields)
    entry.merge!(where: data.dig("tool_input", "file_path"),
                 cwd: data["cwd"], session: data["session_id"].to_s[0, 8])
    private_open(LOG_PATH, "a") { |file| file.puts(JSON.generate(entry)) }
  rescue StandardError
    nil
  end

  # The offending runs, with their text so a later review can judge each
  # block/override as justified or not.
  def self.wall_fields(walls)
    walls.map { |r| { lines: r[:content_lines], text: r[:text][0, 400] } }
  end

  def self.reason(details, file_path)
    <<~REASON
      comment-lint: #{details.join('; ')} in #{File.basename(file_path.to_s)}.
      Default is ZERO comments. A comment may state only a fact the reader cannot recover from the code — ONE line, directly above the exact line it explains (a second caveat line is the max; never a block at a definition). Fix: split each caveat to its own single line at its point of need, or delete it; decision rationale belongs in the commit message and PR, not the code. Words that point at THIS change or review (mirrors, the fix, previously, regression guard, note that, this ensures) don't survive for future readers — state the standing fact instead.
      Rare justified exception (a caveat the code cannot express, whose absence would mislead a future editor): RE-RUN this exact tool call unchanged and it passes; the override is logged. Never split a wall into fake short chunks or reword a register term to a synonym just to dodge the check — trim for the reader, or confirm deliberately.
    REASON
  end

  def self.main
    data = begin
      JSON.parse($stdin.read)
    rescue StandardError
      return
    end

    tool = data["tool_name"].to_s
    return unless %w[Write Edit MultiEdit].include?(tool)

    tool_input = data["tool_input"] || {}
    path = tool_input["file_path"].to_s
    return if exempt?(path)

    ext = File.extname(path)
    return unless style_for(ext)

    result = analyze(scanned_new_text(tool, tool_input), read_baseline(path), ext)
    walls, words, new_runs = result.values_at(:walls, :words, :new_runs)

    details = walls.map { |r| "a run of #{r[:content_lines]} consecutive comment lines (cap: #{CAP})" }
    details << "register words in new comments: #{words.join(', ')}" unless words.empty?

    if details.empty?
      # Denominator for later effectiveness review: every approved call that
      # still adds comment lines.
      content_runs = new_runs.select { |r| r[:content_lines] > 0 }
      if content_runs.any?
        log_event(data, "stat",
                  new_comment_lines: content_runs.sum { |r| r[:content_lines] },
                  max_run: content_runs.map { |r| r[:content_lines] }.max)
      end
      return
    end

    if confirm_pending(confirm_key(data, tool, tool_input))
      log_event(data, "override", details: details, walls: wall_fields(walls), words: words)
      return
    end

    log_event(data, "block", details: details, walls: wall_fields(walls), words: words)
    puts JSON.generate(
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: reason(details, path),
      }
    )
  end
end

CommentLint.main if $PROGRAM_NAME == __FILE__
