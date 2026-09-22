# frozen_string_literal: true

require_relative "../../../app/models/benchmark_run"
require_relative "../../../lib/leaderboard/placement_result"
require_relative "../../../app/lib/leaderboard/tiers"
require_relative "../../../app/lib/leaderboard/placement"

RSpec.describe Leaderboard::Placement do
  def run(id, codec, score, at: Time.at(id), notes: {})
    BenchmarkRun.new(id:, codec_slug: codec, weissman_score: score, submitted_at: at, notes:)
  end

  let(:board) { (1..10).map { |n| run(n, "codec-#{n}", 5.0 - n * 0.1) } }

  it "puts the best score first and in gold" do
    placement = described_class.call(board.first, board:)

    expect(placement).to have_attributes(rank: 1, tier: "gold", margin: 0.1, displaces: true)
  end

  it "breaks a tie in favour of the earlier submission" do
    early = run(11, "early", 4.95, at: Time.at(1))
    late = run(12, "late", 4.95, at: Time.at(2))

    expect(described_class.call(late, board: board + [ early, late ]).rank).to eq(2)
  end

  it "does not let a codec displace its own earlier run" do
    resubmission = run(13, "codec-1", 5.5)

    expect(described_class.call(resubmission, board: board + [ resubmission ]).displaces).to be(false)
  end

  it "leaves an unscored run unranked" do
    placement = described_class.call(run(14, "draft", nil), board:)

    expect(placement).to have_attributes(rank: 0, tier: nil, displaces: false)
  end

  it "treats a missing run as unranked" do
    expect(described_class.call(nil, board:).rank).to eq(0)
  end
end
