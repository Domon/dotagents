# frozen_string_literal: true

module Leaderboard
  RunCard = Data.define(:codec_slug, :score, :tier_label, :placement) do
    def self.for(run, board:)
      placement = Placement.call(run, board:)

      new(
        codec_slug: run.codec_slug,
        score: run.weissman_score,
        tier_label: Tiers.label(placement.tier),
        placement:
      )
    end

    def ranked?
      placement.rank.positive?
    end
  end
end
