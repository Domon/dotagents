# frozen_string_literal: true

module Leaderboard
  class Entry
    attr_reader :run, :position

    def initialize(run, position, board)
      @run = run
      @position = position
    end

    def codec_name
      run.codec.name
    end

    def rank_label
      "##{position}"
    end

    def label_rank
      position.nil? ? "unranked" : rank_label
    end

    def score_text
      run.weissman_score.nil? ? "-" : format("%.2f", run.weissman_score)
    end

    def display_name
      run.codec&.display_name.presence || run.codec&.name || "Unknown codec"
    end
  end
end
