# frozen_string_literal: true

# Minimal tests for turn-cost.rb. Run: ruby turn_cost_test.rb
#
# The end-to-end expectations were cross-checked byte-for-byte against
# turn-cost.py (the original Python implementation, since deleted) on
# 2026-07-24, over this fixture and 10 real session transcripts.

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "../claude/hooks/turn-cost"

class TurnCostTest < Minitest::Test
  HOOK = File.expand_path("../claude/hooks/turn-cost.rb", __dir__)

  def test_fmt_tokens
    assert_equal "999", TurnCost.fmt_tokens(999)
    assert_equal "2K", TurnCost.fmt_tokens(1500)
    assert_equal "82K", TurnCost.fmt_tokens(82_000)
    assert_equal "22K", TurnCost.fmt_tokens(22_500) # half-to-even, like Python's :.0f
    assert_equal "1.5M", TurnCost.fmt_tokens(1_500_000)
    assert_equal "3.5M", TurnCost.fmt_tokens(3_460_000)
  end

  def test_fmt_money_rounds_the_exact_double_like_python
    x = 0.01 + 0.02 + 0.005 # accumulates to 0.034999999999999996
    assert_equal "$0.03", TurnCost.fmt_money(x) # naive format("%.2f", x) says "$0.04"
    assert_equal "$0.05", TurnCost.fmt_money(0.045000000000000005)
  end

  def test_rates_for
    assert_nil TurnCost.rates_for("")
    assert_nil TurnCost.rates_for("gpt-5.6")
    assert_equal [10, 12.50, 20, 1.00, 50], TurnCost.rates_for("claude-fable-5")
    assert_equal [10, 12.50, 20, 0.25, 50], TurnCost.rates_for("claude-fable-5-1")
    assert_equal [10, 12.50, 20, 0.25, 50], TurnCost.rates_for("claude-mythos-5-1")
    assert_equal [2, 2.50, 4, 0.20, 10], TurnCost.rates_for("claude-sonnet-5")
  end

  def test_split_cost_prefers_explicit_1h_field_over_legacy_total
    usage = { "cache_creation" => { "ephemeral_1h_input_tokens" => 1000 },
              "cache_creation_input_tokens" => 9999, "output_tokens" => 200 }
    _, _, tokens, known = TurnCost.split_cost(usage, "claude-fable-5")
    assert_equal 0, tokens["write_5m"]
    assert_equal 1000, tokens["write_1h"]
    assert known
  end

  def test_split_cost_falls_back_to_legacy_5m_field
    usage = { "cache_creation_input_tokens" => 2000 }
    cost, _, tokens, = TurnCost.split_cost(usage, "claude-fable-5")
    assert_equal 2000, tokens["write_5m"]
    assert_in_delta 2000 * 12.5 / 1e6, cost
  end

  def test_split_cost_applies_us_geo_multiplier_and_flags_unknown_models
    usage = { "input_tokens" => 1_000_000, "inference_geo" => "us" }
    cost, _, _, known = TurnCost.split_cost(usage, "claude-zenith-9")
    assert_in_delta 11.0, cost # unknown model priced at fable rates, x1.1 geo
    refute known
  end

  def test_user_prompt_detection
    assert TurnCost.user_prompt?({ "type" => "user", "message" => { "content" => "hello" } })
    assert TurnCost.user_prompt?({ "type" => "user", "message" => { "content" => [{ "type" => "text", "text" => "hi" }] } })
    refute TurnCost.user_prompt?({ "type" => "assistant", "message" => { "content" => "hello" } })
    refute TurnCost.user_prompt?({ "type" => "user", "isMeta" => true, "message" => { "content" => "hello" } })
    refute TurnCost.user_prompt?({ "type" => "user", "isSidechain" => true, "message" => { "content" => "hello" } })
    refute TurnCost.user_prompt?({ "type" => "user", "message" => { "content" => [{ "type" => "tool_result" }] } })
    refute TurnCost.user_prompt?({ "type" => "user", "message" => { "content" => "[SYSTEM NOTIFICATION] done" } })
    refute TurnCost.user_prompt?({ "type" => "user", "message" => { "content" => "see <task-notification> above" } })
    refute TurnCost.user_prompt?({ "type" => "user", "message" => { "content" => "  <local-command-stdout>x</local-command-stdout>" } })
  end

  # One turn covering: message-id dedup, sidechain accounting, a [SYSTEM
  # NOTIFICATION] that must NOT start a new turn, the legacy 5m cache field,
  # and an unknown model priced at fallback rates.
  FIXTURE = [
    { "type" => "user", "message" => { "content" => "hello" } },
    { "type" => "assistant", "timestamp" => "2026-07-24T00:00:01Z",
      "message" => { "id" => "msg_1", "model" => "claude-fable-5", "stop_reason" => "tool_use",
                     "usage" => { "input_tokens" => 100,
                                  "cache_creation" => { "ephemeral_1h_input_tokens" => 1000 },
                                  "cache_read_input_tokens" => 5000, "output_tokens" => 200 } } },
    { "type" => "assistant", "timestamp" => "2026-07-24T00:00:01Z", # duplicate of msg_1 -> ignored
      "message" => { "id" => "msg_1", "model" => "claude-fable-5", "stop_reason" => "tool_use",
                     "usage" => { "input_tokens" => 100,
                                  "cache_creation" => { "ephemeral_1h_input_tokens" => 1000 },
                                  "cache_read_input_tokens" => 5000, "output_tokens" => 200 } } },
    { "type" => "assistant", "isSidechain" => true, "timestamp" => "2026-07-24T00:00:02Z",
      "message" => { "id" => "msg_2", "model" => "claude-haiku-4-5-20251001", "stop_reason" => "end_turn",
                     "usage" => { "input_tokens" => 1000, "output_tokens" => 1000 } } },
    { "type" => "user", "message" => { "content" => "[SYSTEM NOTIFICATION] background task done" } },
    { "type" => "assistant", "timestamp" => "2026-07-24T00:00:03Z",
      "message" => { "id" => "msg_3", "model" => "claude-fable-5", "stop_reason" => "tool_use",
                     "usage" => { "cache_creation_input_tokens" => 2000, "output_tokens" => 400 } } },
    { "type" => "assistant", "timestamp" => "2026-07-24T00:00:04Z",
      "message" => { "id" => "msg_4", "model" => "claude-zenith-9", "stop_reason" => "end_turn",
                     "usage" => { "input_tokens" => 50, "output_tokens" => 100 } } },
  ].freeze

  EXPECTED_MESSAGE = "💰 turn 1: $0.09 (cache-write $0.04 + cache-read $0.01 + out $0.03 + subagents $0.01) · " \
                     "3 req · 3K written, 5K read, 700 out · Σ $0.09 ~est. unknown model prices!"

  def test_end_to_end_matches_reference_output
    Dir.mktmpdir do |home|
      transcript = File.join(home, "transcript.jsonl")
      File.write(transcript, FIXTURE.map { |e| JSON.generate(e) }.join("\n") + "\n")
      input = JSON.generate({ "transcript_path" => transcript, "session_id" => "test-session" })
      out, status = Open3.capture2({ "HOME" => home }, RbConfig.ruby, HOOK, stdin_data: input)

      assert status.success?
      assert_equal EXPECTED_MESSAGE, JSON.parse(out).fetch("systemMessage")

      record = JSON.parse(File.read(File.join(home, ".claude/logs/turn-costs.jsonl")))
      record.delete("ts")
      assert_equal(
        { "session_id" => "test-session", "turn" => 1, "cost" => 0.0865,
          "subagent_cost" => 0.006, "requests" => 3,
          "breakdown" => { "input" => 0.0015, "write" => 0.045, "read" => 0.005, "output" => 0.035 },
          "tokens" => { "input" => 150, "write_5m" => 2000, "write_1h" => 1000, "read" => 5000, "output" => 700 },
          "models" => { "claude-fable-5" => 0.081, "claude-zenith-9" => 0.0055 },
          "session_cost" => 0.0925 },
        record
      )
    end
  end
end
