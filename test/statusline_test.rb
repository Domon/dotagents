# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"

SCRIPTS_DIR = File.expand_path("../claude/scripts", __dir__)
load File.join(SCRIPTS_DIR, "subagent-statusline.rb")

class DisplayModelTest < Minitest::Test
  CASES = {
    "claude-fable-5-1" => "Fable 5.1",
    "claude-opus-5[1m]" => "Opus 5 1M",
    "claude-haiku-4-5-20251001" => "Haiku 4.5",
    "claude-haiku-4-5-20251001[1m]" => "Haiku 4.5 1M",
    "gpt-6-astra" => "gpt-6-astra"
  }.freeze

  def test_table
    CASES.each { |id, expected| assert_equal expected, display_model(id), id }
  end

  def test_nil_passes_through
    assert_nil display_model(nil)
  end
end

class StatuslineTest < Minitest::Test
  SCRIPT = File.join(SCRIPTS_DIR, "statusline.sh")

  def render(cost)
    input = {
      "model" => { "display_name" => "Opus 5" },
      "workspace" => { "current_dir" => "/tmp" },
      "session_id" => "s",
      "cost" => { "total_cost_usd" => cost },
      "context_window" => { "used_percentage" => 10 }
    }
    output, = Open3.capture2({ "COLUMNS" => "120" }, "bash", SCRIPT, stdin_data: JSON.generate(input))
    output
  end

  def test_null_cost_renders_grey_zero
    assert_includes render(nil), "\e[38;5;246m$0.00"
  end

  def test_cost_over_fifty_renders_bold
    assert_includes render(51.2), "\e[1m$51.20"
  end
end
