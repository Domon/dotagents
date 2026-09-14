---
name: codex-review
description: Send every unpushed commit, message and patch, to Codex for review against AGENTS.md, fix what it finds, and record its approval so the push can proceed. Use before finishing work in this repository or when the Stop hook asks for it.
argument-hint: "[model] [notes for the reviewer]"
allowed-tools: Bash(codex *), Bash(git *), Bash(rake *), Bash(mktemp *), Bash(grep *), Bash(cat *), Bash(wc *), Read
---

# Codex review of unpushed commits

Codex reviews each unpushed commit as one unit, its message and its patch,
against the Reviewing section of AGENTS.md. Approval is recorded per sha
under `.git/codex-review`; `.githooks/pre-push` refuses a push without it.
Amending a commit changes its sha, so an amended commit is reviewed again.

Arguments: a model name starting with `gpt-` overrides the default from
`~/.codex/config.toml` and is passed as `-m <model>`; any other text is
appended to the prompt as notes from the user.

Never push. Never run Codex in the background: the session id printed on
stderr is needed for the next round. Always `-s read-only`.

## 1. What is pending

```sh
rake review:status
```

Each line is `approved` or `pending`. With nothing pending, say so and stop.

## 2. Round 1

Bash timeout 600000.

```sh
DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-review.XXXXXX")
rake review:bundle > "$DIR/commits.md"
wc -c < "$DIR/commits.md"
codex exec -s read-only -C "$(git rev-parse --show-toplevel)" -o "$DIR/round-1.md" "$(cat <<'PROMPT'
You are reviewing commits of this repository before they are pushed. Read AGENTS.md first: "What this repository is" lists what must never appear, "Reviewing" is the guideline for both the patch and the message of a commit, and "The imagined codebase" is the only source of example names.

The commits follow in the stdin block, oldest first, each with its full message and its patch. Review the message and the patch of every commit against the guideline. Report each finding as: `file:line` or `message`, then P0 (must fix), P1 (should fix) or P2 (optional), then what is wrong and how to fix it.

For each commit end with one line, `<sha>: APPROVED` or `<sha>: REVISE`. A commit is REVISE when it has a P0 or P1 finding.

Priorities: employer-specific content anywhere in a patch or message is P0 and the reason this review exists. Do not report design alternatives, hypothetical edge cases or defensive additions above P2; this repository prefers readable code over complete edge-case coverage.

End your answer with exactly one line: `VERDICT: APPROVED` when every commit is approved, otherwise `VERDICT: REVISE`.
PROMPT
)" < "$DIR/commits.md" 2> "$DIR/round-1.log"
SESSION=$(grep -m1 'session id:' "$DIR/round-1.log" | awk '{print $NF}')
echo "DIR=$DIR SESSION=$SESSION"
```

Shell variables do not survive between tool calls. Every later command that
mentions `$DIR` or `$SESSION` takes the printed values pasted in literally.

When the bundle is larger than 512000 bytes, pass `</dev/null` instead of
the file and add to the prompt: "The commits are: <shas>. Run `git show
<sha>` for each." When the user passed notes, append them to the prompt
under "Notes from the user:".

## 3. Read the verdict

Read `$DIR/round-1.md` and show it to the user verbatim under the heading
`## Codex review, round 1`.

- `VERDICT: APPROVED` → step 5.
- `VERDICT: REVISE` → step 4.
- No verdict line → step 4 with no fixes, asking for the verdict.

## 4. Fix and resubmit (rounds 2 to 5)

Fix every P0. Fix a P1 when it is a guideline violation you can point at;
when a P1 reads as a design preference, or you are unsure, stop and ask the
user before changing anything. Do not act on P2 findings: list them for the
user and decline them in the resubmission. Fix in the commit the finding
belongs to. `BASE=$(git rev-parse @{u})`.

- Tip commit, patch finding: change the files, `git add`, `git commit --amend --no-edit`.
- Tip commit, message finding: `git commit --amend -F "$DIR/msg.txt"` after writing the new message there.
- Older commit, patch finding: stage the fix, `git commit -q --fixup=<sha>`, then `GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash "$BASE"`.
- Older commit, message finding: write the message to `$DIR/msg.txt`, then
  `GIT_SEQUENCE_EDITOR="sed -i '' 's/^pick <short sha>/reword <short sha>/'" GIT_EDITOR="cp $DIR/msg.txt" git rebase -i "$BASE"`.

A finding you disagree with, or that contradicts what the user asked for,
stays unfixed and is reported with the reason. Run `rake test` and
`rake audit` after the changes, then resubmit (Bash timeout 600000, N = round):

```sh
codex exec resume -c 'sandbox_mode="read-only"' "$SESSION" "Changes made: <one line per finding: fixed how, or declined why>. The commits were amended, so their shas changed. The current unpushed commits, oldest first, are: $(git rev-list --reverse @{u}..HEAD | tr '\n' ' '). Run git show on each and re-review message and patch. Do not re-raise a finding that is fixed. End with the per-commit lines and the VERDICT line as before." </dev/null > "$DIR/round-N.md" 2> "$DIR/round-N.log"
```

Show `$DIR/round-N.md` under `## Codex review, round N` and go back to
step 3. After five rounds without approval: list what remains, record
nothing, stop.

If `resume` fails, run step 2 again as a fresh session and continue.

## 5. Record the approval

```sh
rake review:record SESSION="$SESSION"
rake review:status
```

Report the rounds taken, the recorded shas, and anything declined. If
`codex` is missing or not logged in, say so (`brew install codex`,
`codex login`) and record nothing.
