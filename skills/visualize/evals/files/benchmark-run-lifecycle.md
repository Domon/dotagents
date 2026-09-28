I just joined the middle-out team and I don't get how a benchmark run goes from "submitted" to a leaderboard score. Could you visualize it for me?

This is the code involved (you have no other access to the repository):

```ruby
# app/models/benchmark_run.rb
class BenchmarkRun < ApplicationRecord
  belongs_to :codec
  belongs_to :corpus
  enum :status, { queued: 0, compressing: 1, scoring: 2, scored: 3, failed: 4 }
  MAX_ATTEMPTS = 3
end

# app/controllers/benchmark_runs_controller.rb
class BenchmarkRunsController < ApplicationController
  def create
    run = BenchmarkRun.create!(codec_id: params.require(:codec_id), corpus_id: params.require(:corpus_id), status: :queued)
    CompressCorpusJob.perform_later(run.id)
    render json: { id: run.id, status: run.status }, status: :accepted
  end
end

# app/jobs/compress_corpus_job.rb
class CompressCorpusJob < ApplicationJob
  retry_on Timeout::Error, attempts: BenchmarkRun::MAX_ATTEMPTS
  discard_on Codec::Crashed do |job, _error|
    BenchmarkRun.find(job.arguments.first).update!(status: :failed)
  end

  def perform(run_id)
    run = BenchmarkRun.find(run_id)
    run.update!(status: :compressing)
    result = Sandbox.compress(run.codec, run.corpus, timeout: 10.minutes)
    run.update!(status: :scoring, compressed_bytes: result.bytes, seconds: result.seconds)
    ScoreBenchmarkRun.perform(run)
  end
end

# app/services/score_benchmark_run.rb
class ScoreBenchmarkRun
  include UseCase

  def initialize(run)
    @run = run
  end

  def perform
    score = Weissman::Score.new(run: @run, baseline: @run.corpus.baseline_run).value
    @run.update!(status: :scored, weissman_score: score)
    Leaderboard.for(@run.corpus).place(@run)
  end
end
```
