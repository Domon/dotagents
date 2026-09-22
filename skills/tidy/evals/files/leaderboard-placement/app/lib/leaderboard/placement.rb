# frozen_string_literal: true

module Leaderboard
  module Placement
    UNRANKED = 0

    module_function

    def call(run, board:)
      ranked = ranked(board)
      rank = rank_of(run, ranked)
      return PlacementResult.new(rank: UNRANKED, tier: nil, margin: 0.0, displaces: false) if rank == UNRANKED

      PlacementResult.new(
        rank:,
        tier: tier_for(rank, ranked.length),
        margin: margin_over(run, ranked),
        displaces: displaces?(run, ranked)
      )
    end

    def ranked(board)
      board.select(&:weissman_score).sort_by { |other| [ -other.weissman_score, other.submitted_at ] }
    end

    def rank_of(run, ranked)
      return UNRANKED if run&.weissman_score.to_f.zero?

      index = ranked.index { |other| other.id == run.id }
      index ? index + 1 : UNRANKED
    end

    def tier_for(rank, total)
      Tiers.name_for(rank.fdiv(total))
    end

    def margin_over(run, ranked)
      runner_up = ranked.find { |other| other.weissman_score < run.weissman_score }
      return 0.0 unless runner_up

      (run&.weissman_score.to_f - runner_up.weissman_score).round(3)
    end

    def displaces?(run, ranked)
      return false if provisional?(run) || ranked.length < 2

      ranked.first.id == run.id && ranked[1].codec_slug != run.codec_slug
    end

    def provisional?(run)
      run.notes.fetch("provisional", false) == true
    end
  end
end
