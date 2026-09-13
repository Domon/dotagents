# dotagents

Reusable configuration for AI coding agents, kept in one repository and
linked into each tool's own directory. Today it holds Claude Code pieces;
the layout leaves room for Codex and Pi.

```
skills/                    tool-neutral SKILL.md directories (coming)
claude/
  settings.overrides.json  keys merged into ~/.claude/settings.json
  scripts/                 status line scripts, linked into ~/.claude/scripts
  hooks/                   Claude Code hooks, linked into ~/.claude/hooks
```

## Install

Requires Ruby, `jq`, and `python3` for the ban-words hook.

```sh
git clone git@github.com:Domon/dotagents.git ~/.dotagents
cd ~/.dotagents
cp .audit-terms.example .audit-terms   # replace the example terms with your own
rake install
```

`rake install` does three things, each also available on its own:

- `rake link` symlinks every file in `claude/scripts` and `claude/hooks` into
  the same directory under `~/.claude`. Existing symlinks are replaced; a real
  file in the way stops the task; files you keep there yourself are untouched.
- `rake settings:overrides` deep-merges `claude/settings.overrides.json` into
  `~/.claude/settings.json`. Keys in the overrides file win; every other key
  in your settings is left alone. Under `hooks`, entries are matched by
  command (a leading `/Users/<name>` counts as `~`) and replaced in place, so
  your own hooks in the same event keep running. The previous file is copied
  to `~/.claude/backups/` first. `rake settings:diff` shows the change without
  writing.
- `rake githooks` sets `core.hooksPath` so `rake audit:staged` runs before each commit.

## Status line

`claude/scripts/statusline.sh` prints model, effort, working directory,
session id, cost, and context usage on one line, shortening the directory
only as far as the terminal width demands. `subagent-statusline.rb` does the
same for subagents. To use them without the rest of the repo, copy the two
scripts and add to `~/.claude/settings.json`:

```json
{
  "statusLine": { "type": "command", "command": "bash ~/.claude/scripts/statusline.sh" },
  "subagentStatusLine": { "type": "command", "command": "~/.claude/scripts/subagent-statusline.rb" }
}
```

## Turn cost

`claude/hooks/turn-cost.rb` is a Stop hook that prices the turn just finished
from the session transcript, shows one line in Claude Code, and appends the
detail to `~/.claude/logs/turn-costs.jsonl`. Prices live in a table at the top
of the script; update them when models or prices change.

## Banned words

`claude/hooks/ban-words.py` is a PreToolUse hook that blocks newly written
text using four filler terms: "surface" and "affordance" as nouns,
"load-bearing", and "clamp" in any form. It scans Write and Edit content, and
text that `git commit`, `gh pr` and `gh api` publish commands carry inline or
as `-F body=@file`. Words already present in the file being edited are
allowed, and the agent can keep a genuine verb or domain term by re-running
the identical call once. Every block and override
is logged to `~/.claude/ban-words.log`, which the hook keeps readable by the
owner only. Requires `python3`.

## Audit

`rake audit` fails when any file contains a term from `.audit-terms`, an
absolute `/Users/...` path, or an email address. `.audit-terms` is gitignored
so the list itself is never published; `.audit-terms.example` shows the
format. A list with no terms, comments only, is valid: the path and email
checks run regardless.

`rake audit:staged` checks only the content staged for the next commit,
which is what the pre-commit hook runs: a file edited after `git add` is
judged by its staged copy, and untracked files are skipped.

## Development

```sh
rake test
```

## License

MIT
