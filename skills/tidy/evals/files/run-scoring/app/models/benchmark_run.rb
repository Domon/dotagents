# frozen_string_literal: true

class BenchmarkRun < ApplicationRecord
  belongs_to :codec
  belongs_to :corpus

  after_commit :score, on: :create

  private

  def score
    ScoreBenchmarkRun.call(self)
  end
end
