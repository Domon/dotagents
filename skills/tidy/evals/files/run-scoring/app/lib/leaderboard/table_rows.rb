# frozen_string_literal: true

module Leaderboard
  class TableRows
    def initialize(runs)
      @runs = runs
    end

    def to_a
      @runs.each_with_index.map do |run, index|
        entry = Entry.new(run, index + 1, self)
        [entry.label_rank, entry.display_name, entry.score_text]
      end
    end
  end
end
