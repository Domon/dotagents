# frozen_string_literal: true

class BenchmarkRun
  attr_reader :id, :codec_slug, :weissman_score, :submitted_at, :notes

  def initialize(id:, codec_slug:, weissman_score: nil, submitted_at: Time.at(0), notes: {})
    @id = id
    @codec_slug = codec_slug
    @weissman_score = weissman_score
    @submitted_at = submitted_at
    @notes = notes
  end
end
