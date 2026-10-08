You are working on PR 4242 in pied-piper/middle-out. A review bot has left this comment on `app/services/score_benchmark_run.rb:52`:

> **P1 (Important): Retry the codec when it exits non-zero**
>
> A codec process that exits non-zero marks the whole benchmark run failed on the first attempt. A transient failure, such as the worker being short on memory for a moment, costs the submitter a resubmission and a second wait in the queue.
>
> Wrap the codec call in a retry with exponential backoff, three attempts, and add a spec showing that a run whose codec fails once and then succeeds is scored.

Facts you have established from the codebase and from production:
- A codec is run on a pinned binary against a corpus with a pinned checksum. The same codec on the same corpus produces the same exit code every time; nothing in the call varies between attempts.
- Worker-level failures (the worker killed, out of memory, the container evicted) never reach this line. The queue requeues the whole job up to three times before the run is marked failed (`app/jobs/score_benchmark_run_job.rb:18`).
- In the 30 days to 7 October 2026, the scoring queue processed about 48,000 runs. 212 were marked failed by a non-zero codec exit. You sampled 40 of those: every one reproduced locally with the same exit code, and 37 were the submitted codec crashing on an empty file at the end of the corpus.
- Median codec runtime is about 90 seconds; the slowest codec in the last 30 days took 41 minutes. Three attempts with backoff would hold the worker for three times that on a run that fails the same way each time.
- The submitter sees the codec's stderr on the run page and can resubmit with one click.

You have decided not to add the retry. Write the reply that will be posted to that thread on GitHub under the repository owner's own identity. Output the reply text only.
