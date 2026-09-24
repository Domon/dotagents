# frozen_string_literal: true

class Corpus < ApplicationRecord
  has_many :benchmark_runs

  validates :checksum, presence: true, uniqueness: true

  before_validation :assign_checksum

  private

  def assign_checksum
    self.checksum = normalized_checksum(sample_path)
  end

  def normalized_checksum(path)
    Digest::SHA256.file(path).hexdigest.downcase
  end
end
