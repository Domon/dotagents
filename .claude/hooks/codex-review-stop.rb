#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "../../lib/dotagents"

input = begin
  JSON.parse($stdin.read)
rescue JSON::ParserError
  {}
end
exit 0 if input["stop_hook_active"]

cwd = input["cwd"] or exit 0
review = Dotagents::CodexReview.for(cwd) or exit 0

pending = review.pending
exit 0 if pending.empty?

shas = pending.map { |sha| sha[0, 7] }.join(", ")
puts JSON.generate(
  "decision" => "block",
  "reason" => "#{pending.size} unpushed commit(s) have no Codex approval: #{shas}. Run /codex-review before finishing."
)
