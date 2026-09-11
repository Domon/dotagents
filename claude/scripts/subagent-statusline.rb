#!/usr/bin/env ruby

require "json"

MINIMUM_WIDTH = 20
AGENT_COLUMN_LIMIT = 24
DESCRIPTION_COLUMN_LIMIT = 32
DESCRIPTION_COLUMN_FLOOR = 12
LABEL_MINIMUM = 36
GUTTER = "  "
NESTING_INDENT = 2
MODEL_COLORS = { "fable" => 171, "opus" => 208, "sonnet" => 87, "haiku" => 114 }.freeze
EFFORT_COLOR = 245

def paint(text, color)
  return text if color.nil? || text.empty?

  "\e[38;5;#{color}m#{text}\e[39m"
end

def compact(count)
  return count.to_s if count < 1_000
  return "#{(count / 100.0).round / 10.0}k" if count < 1_000_000

  "#{(count / 100_000.0).round / 10.0}M"
end

def elapsed(millis)
  seconds = millis / 1000
  return "#{seconds}s" if seconds < 60
  return "#{seconds / 60}m #{seconds % 60}s" if seconds < 3_600

  "#{seconds / 3_600}h #{(seconds % 3_600) / 60}m"
end

def display_model(id)
  return nil if id.nil?

  base = id.sub(/\Aclaude-/, "")
  long_context = base.delete_suffix!("[1m]")
  family, *version = base.sub(/-\d{8}\z/, "").split("-")
  return id unless family&.match?(/\A[a-z]+\z/) && version.all? { |part| part.match?(/\A\d+\z/) }

  [family.capitalize, version.join("."), long_context && "1M"].compact.join(" ")
end

def sidecar(input, id)
  directory = File.join(File.dirname(input["transcript_path"].to_s), input["session_id"].to_s, "subagents")
  path = File.join(directory, "agent-#{id}.meta.json")
  path = Dir.glob(File.join(directory, "**", "agent-#{id}.meta.json")).first unless File.exist?(path)

  path && JSON.parse(File.read(path))
rescue StandardError
  nil
end

def truncate(text, width)
  return text if text.length <= width
  return "" if width < 2

  "#{text[0, width - 1]}…"
end

def agent_cell(task, meta)
  name = task["name"] || meta&.fetch("agentType", nil) || task["type"].to_s.sub(/\Alocal_/, "")
  truncate(name, AGENT_COLUMN_LIMIT)
end

def model_cell(task, input)
  model = display_model(task["model"])
  return ["", ""] if model.nil?

  effort = task["effort"] || input.dig("effort", "level") || ENV["CLAUDE_EFFORT"]
  color = MODEL_COLORS[model.split.first.downcase]

  [
    [model, effort].compact.join(" "),
    [paint(model, color), effort && paint(effort, EFFORT_COLOR)].compact.join(" ")
  ]
end

def status_cell(task, now_millis)
  segments = []

  tokens = task["tokenCount"].to_i
  if tokens.positive?
    window = task["contextWindowSize"]
    percent = window ? " (#{(tokens * 100.0 / window).round}%)" : ""
    segments << "↓ #{compact(tokens)}#{percent}"
  end

  if task["status"] == "running"
    segments << elapsed(now_millis - task["startTime"]) if task["startTime"]
  else
    segments << task["status"]
  end

  segments.join(" · ")
end

return unless __FILE__ == $PROGRAM_NAME

input = JSON.parse($stdin.read)
columns = input["columns"].to_i
now_millis = (Time.now.to_f * 1000).round

exit if columns < MINIMUM_WIDTH

rows = input.fetch("tasks", []).map do |task|
  meta = sidecar(input, task["id"])
  depth = [meta&.fetch("spawnDepth", nil) || 1, 1].max
  label = (task["label"] || task["description"]).to_s
  model, model_painted = model_cell(task, input)

  {
    id: task["id"],
    agent: agent_cell(task, meta),
    model: model,
    model_painted: model_painted,
    description: label == task["description"] ? "" : task["description"].to_s,
    label: label,
    status: status_cell(task, now_millis),
    indent: NESTING_INDENT * (depth - 1)
  }
end

exit if rows.empty?

widths = %i[agent model description status].to_h { |key| [key, rows.map { |row| row[key].length }.max] }

fixed_used = widths[:agent] + widths[:status] + GUTTER.length + 1
fixed_used += widths[:model] + GUTTER.length unless widths[:model].zero?
spare = columns - fixed_used - LABEL_MINIMUM - GUTTER.length
widths[:description] = [widths[:description], DESCRIPTION_COLUMN_LIMIT, spare].min
widths[:description] = 0 if widths[:description] < DESCRIPTION_COLUMN_FLOOR

rows.each do |row|
  fixed = [[row[:agent], row[:agent], widths[:agent]]]
  fixed << [row[:model], row[:model_painted], widths[:model]] unless widths[:model].zero?
  unless widths[:description].zero?
    description = truncate(row[:description], widths[:description])
    fixed << [description, description, widths[:description]]
  end

  width = columns - row[:indent]
  reserved = widths[:status].zero? ? 0 : widths[:status] + 1
  used = fixed.sum { |_, _, cell_width| cell_width + GUTTER.length }
  label = truncate(row[:label], width - used - reserved)
  gap = widths[:status].zero? ? 0 : [width - used - label.length - widths[:status], 1].max

  content = fixed.map { |text, painted, cell_width| painted + (" " * (cell_width - text.length)) }
                 .push(label).join(GUTTER) + (" " * gap) + row[:status].rjust(widths[:status])

  puts JSON.generate({ "id" => row[:id], "content" => content })
end
