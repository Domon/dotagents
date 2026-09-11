#!/usr/bin/env ruby
# frozen_string_literal: true

# Stop hook: price the finished turn from the transcript and show a summary.
#
# Reads the hook input JSON on stdin, parses the session transcript JSONL,
# sums API usage since the last genuine user prompt, prices it with the
# per-model table below, and emits
# {"systemMessage": ...} so Claude Code shows one line after each turn.
# Appends full detail to ~/.claude/logs/turn-costs.jsonl.
#
# Accounting rules:
# - One API response can span several JSONL lines (thinking/text/tool_use
#   blocks) that repeat the same message.id and usage — dedup by id or the
#   cost is over-counted ~2-3x.
# - Turn boundaries are genuine user prompts: not isMeta, not isSidechain,
#   not tool_result messages, not [SYSTEM NOTIFICATION]/task-notification
#   re-invocations (those bill to the turn that spawned them), and not
#   <local-command-stdout> echoes of local slash commands.
# - The turn's final assistant message is flushed to the transcript
#   asynchronously and often lands AFTER Stop fires (verified 2026-07-23:
#   single-request turns saw 0 requests and reported nothing). The parse
#   therefore retries until the turn's last message has stop_reason
#   "end_turn" (not "tool_use"), giving up after ~2.4s, then reports what
#   it has. A turn that still shows no requests logs a diagnostic record
#   instead of disappearing silently.
# - Sidechain (subagent) usage inside a turn is counted and reported
#   separately. Background agents whose transcripts live outside this file
#   are NOT counted.
# - 1h cache writes bill at 2x base input, 5m at 1.25x, reads at 0.1x.
# - inference_geo == "us" applies the 1.1x data-residency multiplier.
#
# Prices are $/MTok (base input, 5m cache write, 1h cache write, cache
# read, output) from https://platform.claude.com/docs/en/about-claude/pricing
# as of 2026-09-03. Update when models or prices change.
# Fable 5.1 / Mythos 5.1 cache reads are 0.025x base (all others 0.1x), so
# their rows must precede the "claude-fable-5" prefix they also match.

require "fileutils"
require "json"

module TurnCost
  module_function

  PRICES = {
    "claude-fable-5-1" => [10, 12.50, 20, 0.25, 50],
    "claude-mythos-5-1" => [10, 12.50, 20, 0.25, 50],
    "claude-fable-5" => [10, 12.50, 20, 1.00, 50],
    "claude-mythos-5" => [10, 12.50, 20, 1.00, 50],
    "claude-opus-5" => [5, 6.25, 10, 0.50, 25],
    "claude-opus-4-8" => [5, 6.25, 10, 0.50, 25],
    "claude-opus-4-7" => [5, 6.25, 10, 0.50, 25],
    "claude-opus-4-6" => [5, 6.25, 10, 0.50, 25],
    "claude-opus-4-5" => [5, 6.25, 10, 0.50, 25],
    "claude-sonnet-5" => [2, 2.50, 4, 0.20, 10],
    "claude-sonnet-4-6" => [3, 3.75, 6, 0.30, 15],
    "claude-sonnet-4-5" => [3, 3.75, 6, 0.30, 15],
    "claude-haiku-4-5" => [1, 1.25, 2, 0.10, 5],
  }.freeze

  def log_path
    File.expand_path("~/.claude/logs/turn-costs.jsonl")
  end

  def rates_for(model)
    return nil if model.nil? || model.empty?

    PRICES.each do |prefix, rates|
      next unless model.start_with?(prefix)
      return rates
    end
    nil
  end

  # Returns [cost_usd, breakdown hash, tokens hash, known_model].
  def split_cost(usage, model)
    rates = rates_for(model)
    known = !rates.nil?
    p_in, p_w5, p_w1, p_rd, p_out = rates || PRICES["claude-fable-5"]
    cc = usage["cache_creation"] || {}
    w1 = cc["ephemeral_1h_input_tokens"] || 0
    w5 = cc["ephemeral_5m_input_tokens"]
    w5 = w1.zero? ? (usage["cache_creation_input_tokens"] || 0) : 0 if w5.nil?
    tokens = {
      "input" => usage["input_tokens"] || 0,
      "write_5m" => w5,
      "write_1h" => w1,
      "read" => usage["cache_read_input_tokens"] || 0,
      "output" => usage["output_tokens"] || 0,
    }
    geo = usage["inference_geo"] == "us" ? 1.1 : 1.0
    breakdown = {
      "input" => tokens["input"] * p_in * geo / 1e6,
      "write" => (tokens["write_5m"] * p_w5 + tokens["write_1h"] * p_w1) * geo / 1e6,
      "read" => tokens["read"] * p_rd * geo / 1e6,
      "output" => tokens["output"] * p_out * geo / 1e6,
    }
    [breakdown.values.sum, breakdown, tokens, known]
  end

  def user_prompt?(entry)
    return false if entry["type"] != "user" || entry["isMeta"] || entry["isSidechain"]

    content = (entry["message"] || {})["content"]
    case content
    when String
      text = content
    when Array
      return false if content.any? { |b| b.is_a?(Hash) && b["type"] == "tool_result" }
      first_text = content.find { |b| b.is_a?(Hash) && b["type"] == "text" }
      text = first_text && first_text["text"]
      return false if text.nil?
    else
      return false
    end
    !(text.start_with?("[SYSTEM NOTIFICATION") ||
      text.include?("<task-notification>") ||
      text.lstrip.start_with?("<local-command-stdout>"))
  end

  # Round like Python's float formatting: half-to-even on the EXACT value of
  # the double (Float#to_r is lossless). Ruby's own format("%.2f", x) instead
  # shortens x to its shortest repr first and rounds that — a double-rounding
  # that turns e.g. 0.034999999999999996 into "0.04" where Python says "0.03".
  # Needed to stay byte-identical with turn-cost.py, the reference version.
  def py_round(x, digits)
    x.to_r.round(digits, half: :even)
  end

  def fmt_money(x)
    format("$%.2f", py_round(x, 2).to_f)
  end

  def fmt_tokens(n)
    return "#{py_round(n / 1e6, 1).to_f}M" if n >= 1_000_000
    return "#{py_round(n / 1e3, 0)}K" if n >= 1000

    n.to_s
  end

  def emphasize(text, value, threshold)
    value > threshold ? "\e[1m#{text}\e[22m" : text
  end

  def parse(transcript_path)
    turn_count = 0
    session_cost = 0.0
    turn = nil
    last_stop_reason = nil
    seen_ids = {}
    File.foreach(transcript_path) do |line|
      begin
        entry = JSON.parse(line)
      rescue JSON::ParserError
        next
      end
      next unless entry.is_a?(Hash)

      if user_prompt?(entry)
        turn_count += 1
        last_stop_reason = nil
        turn = {
          "cost" => 0.0, "subagent_cost" => 0.0, "requests" => 0,
          "breakdown" => { "input" => 0.0, "write" => 0.0, "read" => 0.0, "output" => 0.0 },
          "tokens" => { "input" => 0, "write_5m" => 0, "write_1h" => 0, "read" => 0, "output" => 0 },
          "models" => {}, "unknown_models" => [],
        }
      elsif entry["type"] == "assistant" && !turn.nil?
        message = entry["message"] || {}
        usage = message["usage"]
        msg_id = message["id"] || entry["requestId"]
        next if !usage.is_a?(Hash) || usage.empty? || seen_ids.key?(msg_id)

        seen_ids[msg_id] = true
        model = message["model"] || ""
        cost, breakdown, tokens, known = split_cost(usage, model)
        session_cost += cost
        if entry["isSidechain"]
          turn["subagent_cost"] += cost
          next
        end
        last_stop_reason = message["stop_reason"]
        turn["cost"] += cost
        turn["requests"] += 1
        turn["breakdown"].each_key { |k| turn["breakdown"][k] += breakdown[k] }
        turn["tokens"].each_key { |k| turn["tokens"][k] += tokens[k] }
        turn["models"][model] = (turn["models"][model] || 0.0) + cost
        turn["unknown_models"] << model unless known || turn["unknown_models"].include?(model)
      end
    end
    [turn_count, session_cost, turn, last_stop_reason]
  end

  def append_log(record)
    FileUtils.mkdir_p(File.dirname(log_path))
    File.open(log_path, "a", 0o600) { |f| f.puts(JSON.generate(record)) }
  end

  def utc_now
    Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S+00:00")
  end

  def main
    hook_input = JSON.parse($stdin.read)
    transcript_path = hook_input.fetch("transcript_path")

    # The final assistant message may not be flushed yet when Stop fires.
    # Re-read until the turn looks complete (has requests and doesn't end
    # on a tool_use), for at most 6 x 0.4s.
    turn_count = session_cost = turn = last_stop_reason = nil
    6.times do
      turn_count, session_cost, turn, last_stop_reason = parse(transcript_path)
      break if !turn.nil? && turn["requests"] > 0 && last_stop_reason != "tool_use"

      sleep 0.4
    end

    return if turn.nil?

    if turn["requests"].zero?
      begin
        append_log({
          "ts" => utc_now,
          "session_id" => hook_input["session_id"],
          "turn" => turn_count,
          "requests" => 0,
          "note" => "no assistant usage after retries (flush race or local command)",
        })
      rescue SystemCallError, IOError
      end
      return
    end

    b = turn["breakdown"]
    t = turn["tokens"]
    total = turn["cost"] + turn["subagent_cost"]
    parts = ["cache-write #{fmt_money(b['write'])}", "cache-read #{fmt_money(b['read'])}",
             "out #{fmt_money(b['output'])}"]
    parts << "subagents #{fmt_money(turn['subagent_cost'])}" if turn["subagent_cost"] != 0
    flags = turn["unknown_models"].empty? ? "" : " ~est. unknown model prices!"
    message = format(
      "💰 turn %d: %s (%s) · %d req · %s written, %s read, %s out · Σ %s%s",
      turn_count, emphasize(fmt_money(total), total, 1.0), parts.join(" + "), turn["requests"],
      fmt_tokens(t["write_5m"] + t["write_1h"]), fmt_tokens(t["read"]), fmt_tokens(t["output"]),
      fmt_money(session_cost), flags
    )

    begin
      append_log({
        "ts" => utc_now,
        "session_id" => hook_input["session_id"],
        "turn" => turn_count,
        "cost" => py_round(turn["cost"], 6).to_f,
        "subagent_cost" => py_round(turn["subagent_cost"], 6).to_f,
        "requests" => turn["requests"],
        "breakdown" => b.transform_values { |v| py_round(v, 6).to_f },
        "tokens" => t,
        "models" => turn["models"].transform_values { |v| py_round(v, 6).to_f },
        "session_cost" => py_round(session_cost, 6).to_f,
      })
    rescue SystemCallError, IOError
    end

    puts JSON.generate({ "systemMessage" => message })
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    TurnCost.main
  rescue StandardError
    exit 0 # never block Claude over a cost display
  end
end
