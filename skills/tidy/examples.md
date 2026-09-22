# Worked examples

## Shapes the voices keep finding

| Shape | The move |
|---|---|
| Orchestrator (use case / controller / job) doing domain logic or persistence inline | Move Function: an intention-named model method owns the whole operation (e.g. score-and-transition-and-save); orchestrator shrinks to one tell per item |
| Ask-then-act on another object's data (`x.value.presence \|\| Owner.default ...`) | Tell, don't ask: push the decision into the data's owner |
| Nilable lookup every caller guards (`HASH[key]` → nil) | Total function: `fetch(key) { fallback }`; exactly one owner for the fallback |
| Assignment inside a condition (`if (x = find_by(...))`) | Hoist: assignment on its own line; the condition reads as a plain question |
| Comment restating WHAT, or orientation/purpose | Delete it. Keep only a decision, invariant, or gotcha — orientation belongs in the commit |
| Build-then-mutate construction | Construct complete objects: `new(a:, b:, c:)` in one expression |
| Dense fallback chain (`a.presence \|\| b \|\| {}`) | Explicit branches that read as the real cases (existing vs. new) |
| Same lookup/expression repeated across sibling methods | Extract Method: one intention-named private reader/predicate in the same class; callers read as questions (see "Move, or extract in place?") |
| Dense expression — 3+ chained calls, or a conditional folded into one line | Extract Variable (Beck's Explaining Temporary Variable): one intention-named temp per idea, in place; escalate to Extract Method only when the name is needed beyond this call site |
| Two public names built from the same words reordered, or one weak word apart | Rename Function: write both calls out in full and read them together; the reader must be able to tell which is which from the names alone |
| Comment block >2 lines at a definition or call | 1-line TL;DR stays at the top; each caveat moves inline above the exact statement it explains; multi-case prose becomes itemized cases; first try the rename/extraction that makes the sentence superfluous |
| Keyword argument on a single-parameter method | Change Function Declaration: positional |
| A layer that only delegates — body is one call, or it re-fetches data its caller already holds | Inline Function; anything that exists only to cross a boundary must name the tax it pays |
| Configuration restating a default (explicit index names, redundant options) | Delete |

## Move, or extract in place?

Move Function (Example 1) when the receiver owns the operation and has real behavior to join. Extract a private method in place (Example 3) when the "owner" is a thin get/update store — there the local method IS the end state, not a half-move, and a private method is never "a new layer".

Below both sits Extract Variable — Beck's Explaining Temporary Variable — the first rung for a dense expression: names, no new structure (Example 4). A method extracted to serve one call site joins the class's interface just to name an expression; prefer explaining variables there, and when the logic is genuinely complex, extract a class rather than accumulating helper methods.

## Worked evolutions

Each example below is staged the way a review round tends to go: the smell, a
half-step a reviewer sends back, and the shape that gets accepted. All of it is
set in one invented codebase, middle-out, a compression benchmark service where
codecs and corpora are submitted, benchmark runs are scored, and a leaderboard
ranks them. When a /tidy finding matches a stage-1 shape, propose the final stage
directly — don't make the human walk the path again.

## Example 1: the state change that belonged to the model

A use case that scores a finished benchmark run. Scoring is three writes that
must land together: the score, the timestamp, the status.

### Stage 0 — orchestrator does everything (the smell)

```ruby
# use case
def perform
  run = BenchmarkRun.find(@run_id)
  ratio = run.original_bytes.fdiv(run.compressed_bytes)
  run.weissman_score = Weissman::Score.for(ratio:, seconds: run.elapsed_seconds)
  run.scored_at = Time.current
  run.status = "scored"
  run.save!
end
```

Problems: the use case reads four attributes off the run to compute a value only
the run can be wrong about; three assignments and a save cooperate on one
transition, so any other writer (a backfill job, a console fix) has to know all
four lines; "scored" is a string the model never sees.

### Stage 1 — half-move: model method, but only for the arithmetic

```ruby
# model
def compute_score
  Weissman::Score.for(ratio: original_bytes.fdiv(compressed_bytes), seconds: elapsed_seconds)
end

# use case
run.weissman_score = run.compute_score
run.scored_at = Time.current
run.status = "scored"
run.save!
```

Better (the formula has an owner) but still a half-measure: the transition is
still assembled outside the model, and `compute_score` is a public method whose
only caller is about to assign its result back to the same object.

### Stage 2 — the model owns the whole operation (the target shape)

```ruby
# use case
def perform
  BenchmarkRun.find(@run_id).score!
end

# model
def score!
  update!(
    weissman_score: Weissman::Score.for(ratio: compression_ratio, seconds: elapsed_seconds),
    scored_at: Time.current,
    status: SCORED
  )
end

def compression_ratio
  original_bytes.fdiv(compressed_bytes)
end
```

Why this is the end state:

- **The model owns its semantics** — "score this run" is one named operation;
  every writer gets the three-field invariant, not just this use case.
- **One expression, one write** — `update!` with all three fields says the
  transition is atomic; three assignments and a `save!` only implied it.
- **The magic string has a home** — `SCORED` lives beside the other statuses on
  the model, where the next reader looks for it.
- **The ratio is a reader, not a temp** — it is a fact about the run, asked for
  by the leaderboard too; a public reader is the right rung for a name that
  travels.
- **No behaviour change** — same three fields, same values, same single save.
  A tidy pass that cannot say this sentence about a stage has found a design
  change, and points it out instead of making it.

## Example 2: comments answer questions, or die

From the same kind of round:

- `# work out the compression ratio` above `original_bytes.fdiv(compressed_bytes)`
  → **deleted** (narrates WHAT; the rename to `compression_ratio` said it).
- A reviewer's "what if the corpus was withdrawn after this run finished?" → answered
  in place with one WHY line at the guard: the run keeps its score and drops off
  the leaderboard, because the leaderboard joins on live corpora. Kept, because no
  code says what the consumer relies on.

Rule of thumb: a comment must answer a question a reader would actually ask in two
years. Narration fails; decisions, invariants, and failure-mode contracts pass —
said in one line.

## Example 3: extract in place when the owner is a thin store

Sibling controller actions repeat the same reach into a corpus registry, a thin
fetch-by-slug store with no behavior of its own. Moving the operation there would
be ceremony — the end state is same-class extraction.

### Stage 0 — the same reach repeated

```ruby
def show
  entry = Corpus::Registry.fetch(params[:slug])
  render_success(checksum: entry.fetch("checksum"), fetched_at: entry.fetch("fetched_at"))
end

def refresh
  entry = Corpus::Registry.fetch(params[:slug])
  return head :not_modified if entry.fetch("fetched_at") > 1.day.ago
  Corpus::Registry.refresh(params[:slug])
  head :accepted
end

def stale?
  Corpus::Registry.fetch(params[:slug]).fetch("fetched_at") <= 1.day.ago
end
```

### End state — extract private readers, move nothing

```ruby
def show
  render_success(checksum: entry.fetch("checksum"), fetched_at: fetched_at)
end

def refresh
  return head :not_modified unless stale?
  Corpus::Registry.refresh(params[:slug])
  head :accepted
end

private

def entry = Corpus::Registry.fetch(params[:slug])
def fetched_at = entry.fetch("fetched_at")
def stale? = fetched_at <= 1.day.ago
```

- One reader owns the fetch and the key strings; guards read as the questions they ask.
- `Corpus::Registry` is a thin store — a method there for one caller is ceremony. This
  is the destination, not Example 1's half-move.
- Plain readers, no memoization: `refresh` reads then writes, so a cached entry
  would lie to the next line.
- The inverted guard in `refresh` fell out of naming the predicate; `stale?`
  already existed and was the question being asked.

## Example 4: explaining variables before extraction

The guard that admits a submitted corpus into the benchmark pool. Three rules,
one line.

### Stage 0 — the dense one-liner (the smell)

```ruby
def accept!(corpus)
  raise CorpusRejected unless corpus.size_bytes.between?(MIN_BYTES, MAX_BYTES) && corpus.files.any? { |file| SAMPLE_EXTENSIONS.include?(file.extension) } && Corpus.where(checksum: corpus.checksum).where.not(id: corpus.id).none?

  corpus.update!(status: ACCEPTED)
end
```

### Stage 1 — wrong rung: a method extracted for one call site

```ruby
def accept!(corpus)
  raise CorpusRejected unless acceptable?(corpus)

  corpus.update!(status: ACCEPTED)
end

def acceptable?(corpus)
  corpus.size_bytes.between?(MIN_BYTES, MAX_BYTES) &&
    corpus.files.any? { |file| SAMPLE_EXTENSIONS.include?(file.extension) } &&
    Corpus.where(checksum: corpus.checksum).where.not(id: corpus.id).none?
end
```

Rejected in review, twice over: the class interface grew to serve one call site, and
"acceptable" restates the caller's verb — the reader still decodes three clauses to
learn what acceptance means.

### Stage 2 — Extract Variable (the target shape)

```ruby
def accept!(corpus)
  within_size_limits = corpus.size_bytes.between?(MIN_BYTES, MAX_BYTES)
  has_sample_file = corpus.files.any? { |file| SAMPLE_EXTENSIONS.include?(file.extension) }
  duplicate = Corpus.where(checksum: corpus.checksum).where.not(id: corpus.id).exists?

  raise CorpusRejected unless within_size_limits && has_sample_file && !duplicate

  corpus.update!(status: ACCEPTED)
end
```

Why this is the end state:

- **Beck's Explaining Temporary Variable** (Fowler: Extract Variable; 1st-ed
  "Introduce Explaining Variable") — one temp per idea, and the `raise` line reads
  as the rule itself: sized right, has a sample, not a duplicate.
- **No interface growth** — the names live and die inside the method; nothing new
  to document, hide, or test in isolation.
- **Negation moved into the name** — `duplicate` with `exists?` reads at the use
  site; `none?` folded the negation into the query and made the reader flip it.
- **One cost, named** — Stage 0 short-circuited; here all three checks run even
  when the first fails, so an oversized corpus now costs one query it did not
  before. Same outcome, one extra read. If that query were expensive, the shape
  is successive guards, one `raise` each, not a return to the one-liner.
- **Escalate only when the name travels** — a second call site needing the same
  expression is the signal for Extract Method; genuinely complex logic extracts
  a class, not a pile of helper methods. (Example 1's `compression_ratio` is
  that escalation, made because two callers asked.)

## Growth protocol

When a human review round teaches a new preference: append a new example here as a
before/after pair with a one-line "why" per delta. Invent the example from the
move, in the imagined middle-out codebase (see AGENTS.md); never genericize the
code from the round itself. A renamed copy of private code is still private code.

## Example 5: names judged at the call site, comments at the point of need

Two sibling class methods on the leaderboard, written days apart:

```ruby
# Codecs ranked for a corpus. Ranks by Weissman score descending, then
# by submission time so an earlier identical score keeps its place.
# Runs from unverified submitters are left out entirely, not ranked
# last, because the public board must not show a score the submitter
# could not have produced. Scores are rounded only for display; the
# ordering uses the stored value so two runs that round the same do
# not swap places between page loads.
def self.ranked_codecs_for(corpus) ...

def self.codecs_ranked_on(corpus, limit:) ...
```

Hunk-by-hunk, each method looks fine. The interface pass catches both problems:

**Names.** Read the public methods together: `ranked_codecs_for` and
`codecs_ranked_on` are the same words reordered — nothing tells a newcomer that
one returns every codec and the other the top of the board. Write the calls out
in full and name from the sentence:

```ruby
Leaderboard.ranked_codecs_for(corpus)      # every codec, in order — keep
Leaderboard.top_codecs_for(corpus, limit:) # "the top N for this corpus"
```

**Comments.** The wall interleaves three concerns far from their lines. One-line
TL;DR; each caveat lands on the statement it explains:

```ruby
# Codecs ranked for a corpus, best Weissman score first.
def self.ranked_codecs_for(corpus)
  runs = BenchmarkRun.scored.where(corpus:)
  # The public board never shows a score its submitter could not have produced.
  runs = runs.joins(:submitter).merge(Submitter.verified)
  # Ordering uses the stored score, not the rounded display value, so equal
  # rounded scores do not swap places between page loads.
  runs.order(weissman_score: :desc, submitted_at: :asc).map(&:codec)
end
```

and the display note moves to the presenter, above the rounding it is about:

```ruby
    # Display only. The board orders on the stored value; see ranked_codecs_for.
    score.round(3)
```

The reasoning: names are read at call sites, so they are judged there — as a
set, not one at a time. Comments earn each line by sitting where the question
arises; a wall at the definition is the author's thinking transcript, not the
reader's answer.
