# frozen_string_literal: true

class ScoreBenchmarkRun
  KIND_WEIGHTS = { "text" => 1.0, "image" => 1.4, "audio" => 1.8 }.freeze

  def self.call(run)
    new(run).call
  end

  def initialize(run)
    @run = run
  end

  def call
    weight = KIND_WEIGHTS[@run.corpus.kind]
    weight = 1.0 if weight.nil?
    # compute the score
    score = Weissman::Score.new(ratio: @run.original_bytes.to_f / @run.compressed_bytes.to_f * weight,
                                seconds: @run.duration_seconds)
    @run.update!(weissman_score: process_result(score.value))
    score
  end

  def compression_ratio
    @run.original_bytes.to_f / @run.compressed_bytes.to_f
  end

  def process_result(value)
    value.presence || @run.weissman_score || 0.0
  end
end
