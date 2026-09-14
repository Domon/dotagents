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
