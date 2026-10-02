# Claude Code

Everything under this folder mirrors `~/.claude`. `rake link` from the
repository root links each file into place, and `rake settings:overrides`
merges `settings.overrides.json` into the live settings file.

## Status line

`scripts/statusline.sh` prints model, effort, working directory, session id,
cost, and context usage on one line, shortening the directory only as far as
the terminal width demands. `scripts/subagent-statusline.rb` does the same
for subagents. To use them without the rest of the repository, copy the two
scripts and add to `~/.claude/settings.json`:

```json
{
  "statusLine": { "type": "command", "command": "bash ~/.claude/scripts/statusline.sh" },
  "subagentStatusLine": { "type": "command", "command": "~/.claude/scripts/subagent-statusline.rb" }
}
```

## Turn cost

`hooks/turn-cost.rb` is a Stop hook that prices the turn just finished from
the session transcript, shows one line in Claude Code, and appends the detail
to `~/.claude/logs/turn-costs.jsonl`. Prices live in a table at the top of
the script; update them when models or prices change.

## Banned words

`hooks/ban-words.rb` is a PreToolUse hook that blocks newly written text
using four filler terms: "surface" and "affordance" as nouns, "load-bearing",
and "clamp" in any form, the last because the word hides which direction a
limit works. The aim is to stop new uses without blocking references to
things that already exist or legitimate verbs. Three mechanisms do that:

- Word boundaries. The patterns match the standalone word only, so compound
  identifiers such as `surfaceTint` or `paint_surface` never match, even in
  new code. The verbs "surfacing" and "surfaced" are never matched, and
  "clamp" in call syntax (`clamp(`, `std::clamp`, `Math.clamp`, `_.clamp`) is
  an API name, not prose.
- Baseline diff. For Write and Edit the hook reads the file's current content
  and blocks only a word whose type is not already present, so a file that
  already says "surface" can keep saying it.
- Confirm on re-run. A pattern cannot tell the noun "surface" from the verb in
  "react-router surfaces the request". The first hit blocks with guidance; if
  the agent judges the use legitimate and re-runs the identical call within
  fifteen minutes, it passes once. No user prompt is involved, and every
  block and override is logged.

Scanned: Write content and Edit new strings, diffed against the file on disk;
and for Bash, text that `git commit`, `gh pr create|edit|comment|review` and
`gh api` writes carry inline or in a file named by `-F`, `--file`,
`--body-file`, `--input` or `body=@file`. Exempt: files beside the hook's real
location, `~/.claude/hooks` and `settings.json`, and agent instruction files
(`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`) where the rule itself is spelled out.

Logs: one JSON line per block or override in `~/.claude/ban-words.log`, and
pending confirmations in `~/.claude/.ban-words-pending.json`, both kept
owner-readable only. `BAN_WORDS_LOG` and `BAN_WORDS_PENDING` override the
paths, which the tests use. Logging never affects the decision.

## Comment lint

`hooks/comment-lint.rb` is a PreToolUse hook that blocks newly written code
whose comments drift from the default of writing none. Two shapes are
refused: a run of more than two consecutive whole-line comments, and a
comment written in the change/review register — "mirrors", "the fix",
"previously", "note that", "this ensures", "regression guard" — words about
the pull request rather than about the code, which stop making sense to
anyone who never saw it. The same three mechanisms as the banned-words hook
keep it out of the way:

- Whole-line comments only. A trailing comment after code never joins a run,
  so annotated data tables and end-of-line notes are untouched.
- Baseline diff. Runs and register words already on disk never block again,
  so editing a file that has walls does not fight the hook.
- Confirm on re-run. For the rare caveat the code cannot express, re-running
  the identical call once passes it through; both events are logged.

Comment syntax is recognised per extension: `#` for Ruby, Python, shell and
config formats, `//` and `/* */` for the C family, `--` for SQL, and CSS
comments. Any other extension is ignored. Exempt: files beside the hook's
real location, anything under `~/.claude/hooks`, and `*.stories.tsx`, where
long descriptive blocks are the point.

Logs: one JSON line per block or override in `~/.claude/comment-lint.log`,
and pending confirmations in `~/.claude/.comment-lint-pending.json`, both
kept owner-readable only. `COMMENT_LINT_LOG` and `COMMENT_LINT_PENDING`
override the paths, which the tests use.

## Tidy gates

Two hooks make a /tidy pass part of committing and pushing Ruby, in the
main session and inside subagents alike.

- `hooks/require-tidy.rb` (PreToolUse, Bash) denies `git commit` when the
  commit contains Ruby, including files a `git add` earlier in the same
  command is about to stage, and no pass exists since `HEAD`; and `git push` when
  the branch changed Ruby and no whole-branch pass exists on the pushed
  commit or one of its ancestors. The denial names the exact arguments:
  `/tidy <repo> git diff <HEAD sha>` or `/tidy <repo> git diff <base> <tip>`.
  When the command would add new Ruby files, the denial first asks for a
  plain `git add` of them, since `git diff` does not show untracked files.
  When the session's last tidy fork in that repository was skipped, the
  denial also says why, quoting the arguments when they were the problem.
  Generated schema files (`db/schema.rb`, `db/*_schema.rb`), deletes, tags
  and pushes to `main` or `master` are not gated.
- `hooks/record-tidy-pass.rb` (SubagentStop) records a pass when a fork of
  the tidy skill finishes with its Removals and Out of scope sections,
  taking the shas from the arguments the fork received. The agent never
  writes a pass itself.

Passes live in `~/.local/state/dotagents/tidy/<worktree key>/`
(`$XDG_STATE_HOME` when set), one folder per worktree, managed by
`hooks/lib/tidy_passes.rb`.

Both hooks append one JSON line per event to
`~/.local/state/dotagents/tidy/events.jsonl`, with the time, session id,
subagent id and repository: `deny` and `allow` for a gated commit or push
(allowed commands that needed no pass are not logged), `record` for a pass,
`skip` with the reason when a tidy fork finished without recording one, and
`error` when a hook failed; errors never block. `rake tidy:report` summarises
the last seven days (`DAYS=` to change): counts, the median time from a denial
to its release, a row per repository, every denial never released in its
session, skips by reason, and recent errors.
