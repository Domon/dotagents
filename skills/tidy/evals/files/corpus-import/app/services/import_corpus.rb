# frozen_string_literal: true

class ImportCorpus
  def initialize(path, name:)
    @path = path
    @name = name
  end

  def import
    checksum = Digest::SHA256.file(@path).hexdigest.downcase
    existing = Corpus.find_by(checksum: checksum)
    return existing if existing

    Corpus.create!(name: @name, sample_path: @path)
  end
end
