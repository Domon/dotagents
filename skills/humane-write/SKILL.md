---
name: humane-write
description: Use before writing prose a person will read in any medium, such as a PR description, a review comment or reply, a commit message body, a chat message or a document. These are the rules for the shape of the text, not a drafting process; to draft text published under the author's name, with stops for the author to confirm the claim first, use humane-draft.
---

# Humane write

The rules for prose a person reads. Read them before the first sentence and run the checks on the draft. Process skills build on this one: `humane-draft` adds the stops that let the author confirm the claim before a body exists, and `humane-review` adds the shape of a review report. This skill is what they share.

Two rules of thumb. Everything else depends on context.

1. **Inverted pyramid.** Start from the conclusion, the overview, the proposal. The reader
   gets the most important fact first and can stop as soon as they have what they need.
2. **Simple plain English.** No jargon, no invented clever words.

## The shape

**Sentence one is the claim you want the reader to leave with.** Not the finding restated,
not what you are about to do, not what you concede. If the reader stops after sentence one,
they have your position.

Then the evidence for that claim. Then anything that qualifies it, nested under the claim
it qualifies.

**The last sentence is the last piece of evidence.** Text that has said what it came to say
stops there. An offer to file a ticket, a note on what would change your mind, a summary of
what you just wrote — each one is the author's to make, not yours to volunteer.

Everything below is a check on a draft you have already written. Do not turn them into a
style checklist and do not enumerate cases — a rule that fits one piece of writing usually
does not fit the next one.

## Checks

**What is the conclusion, and is it in sentence one?**
Read only the first sentence. Does it carry the position? An opener that grants the other
side forces the rest of the text to take it back, which is how one position turns into two.

**Does this term do work in this sentence, for this reader?**
Filenames, identifiers and `file:line` refs are precise and often exactly right. The
question is never where they sit but whether the sentence needs them. A term that saves
you a paraphrase is decoration; a term that IS the subject earns its place.

**Is this claim mine to make, and can I cite it?**
A comparative or superlative about how the system behaves — busiest, slowest, hottest,
most-used, expensive, negligible, rarely — is a measurement claim. Cite the measurement or
cut the word.

**Is this caveat attached to its claim, or fused into it?**
A qualification nested under what it qualifies stays readable. The same qualification
welded into the claim's own sentence makes both harder to read.

**Am I stating a property, or an attitude?**
"Nobody minds a late score" is an attitude, and it is the author's to hold, not yours to
voice. The property underneath it is the reply: "a score that arrives after the leaderboard
is built goes into the next build, and nothing reads the table between builds."

**Will this fact still be true when it is read?**
Facts that move want a date and a round number: "about 2,000 codecs on the leaderboard,
as of October 2026" survives; "1,987 of 64,203 submissions (3.1%)" is stale by next month
and reads as precision theatre.

## Investigation

How you found something is legitimate content. It is not an opening. Nobody begins by
narrating their debugging session. Lead with what you found; append how you found it below,
or in a `<details>` block when it is low-level.
