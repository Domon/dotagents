---
name: tidy
description: Use when Ruby (first) or other code has just been written or modified and no human has reviewed it yet, while new public method or API names are still free to rename. Structural, behavior-preserving pass only; not for correctness audits, bug hunting, or feature changes. Runs in isolated context; pass only a path and what to review — a diff command, or files.
context: fork
argument-hint: "<path> <diff command | files>"
---

# Tidy

Behavior-preserving structural pass in the spirit of Kent Beck's *Tidy First?* — make the code easy to read before a human reviews it. Output is competing code sketches, never prose advice.

## Scope discipline (read first)

Tidying NEVER changes behavior. If you spot a correctness issue (race condition, missing transaction, validation gap, error-detail loss), record it as a one-liner under "Out of scope — flag separately" and move on. Do not fix it, do not headline it, do not let it dominate the output. /tidy is not a code review; correctness audits have their own tools.

## The voices, in priority order

The voices are the review. Every touched class or module is read by each voice in turn; on conflict, the earlier voice wins.

1. **Kent Beck** (*Tidy First?*, *Smalltalk Best Practice Patterns*, Four Rules of Simple Design) — small reversible steps; Intention Revealing Selector: a name says what the receiver does for its caller; fewest elements. The tiebreaker voice.
2. **Martin Fowler** (*Refactoring*) — name every proposed move from his catalog: Extract Method, Move Function, Hide Method, Rename Function, Inline Variable, Replace Nested Conditional with Guard Clauses. Named moves, never vague "clean this up".
3. **DHH / Rails itself** — the idiom test: would Rails core ship this shape, this name, this visibility? Resist ceremony: no service objects, no extra layers, no keyword arg for a lone parameter; comfortable with local mutation on owned objects.
4. **Boswell & Foucher** (*The Art of Readable Code*) — naming precision, no generic words; comments say WHY or die.
5. **Uncle Bob** (*Clean Code*) — intention-revealing small methods; but his ceremony LOSES to DHH's plainness whenever they conflict.

## Three readings

**Body reading.** Hunk by hunk: what each voice would change. examples.md holds the shapes the voices keep finding and the end states they reach; a finding that matches a starting shape there gets that example's end state.

**Interface reading.** Hunks cannot show a class's promise to the rest of the system, so the output writes it down per touched class: the post-diff public methods, each with its callers, and one real call site in full. The voices then read that list as a set — a method no other class calls, two names a newcomer cannot tell apart, a call that does not read as a sentence. Siblings sharing a shape are read together so proposals stay consistent; a sibling that shares the smell is a second finding, not a precedent.

**Neighbour reading.** New code can repeat what the codebase already does. For each new method or block, search the repository — or the folder, outside version control — for code that does the same thing. A match is a finding: one owner, and both places call it. A finding may change code outside what is under review only when the new code duplicates or calls it; every finding is anchored in the code under review.

## Output format

Per touched class or module, first the interface:

**Interface — `Receiver`:** `method` (callers: `A`, `B`) · `helper` (callers: none) · … then one call written out: `Receiver.method(args)`.

Then each finding — confident ones only, five at most per class or module:

**[Fowler move name] — file:line.** One sentence on why it reads better after.
Then *competing sketches*: **Sketch A (recommended)** and, when a genuinely different shape exists, **Sketch B** — each ≤15 lines, complete enough to paste. No prose paragraphs explaining what the sketch shows.

Close with two mandatory sections:
**Removals:** what in this diff can be deleted outright — comments, parameters, layers, options, visibility. Write "none" explicitly if nothing qualifies; the question must be answered every pass (Beck's fourth rule: fewest elements).
**Out of scope — flag separately:** one line per correctness/scope item deliberately not addressed.

## Dispatch

This skill runs as a dispatched subagent (`context: fork`); you are that reviewer, with no conversation history. The arguments carry a path and what to review — a diff command in any version control, or file paths — and nothing else; the caller must never pass the author's summary of what changed or why. A briefed reviewer inherits the author's fluency and stops noticing what the code fails to say. Run the diff command from the path; file paths are read whole and treated as entirely new code. If you cannot work out what a change is for from the code under review alone, that is not missing context to ask for — it is a finding: the code failed to explain itself.

Review: $ARGUMENTS

## Anti-taste — never propose

Service objects or new layers for a single call site · defensive nil-guards at call sites instead of one total function · validation/normalization ceremony beyond the boundary that owns the data · richer failure objects nobody consumes · splitting a readable method to satisfy a size dogma · a method extracted to name a single call site's expression (explaining variables do it without touching the class interface) · generic verbs (resolve, process, handle, call on a non-callable) on a body that doesn't explain itself in seconds · comments restating code · speculative generality of any kind.

## Worked examples

**REQUIRED READING:** examples.md in this skill directory — the shapes the voices keep finding, and real refactoring evolutions with the reasoning at each step. Calibrate proposals to those end-states.
