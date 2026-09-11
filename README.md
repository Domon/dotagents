# dotagents

Reusable configuration for AI coding agents, kept in one repository and
linked into each tool's own directory. Today it holds Claude Code pieces;
the layout leaves room for Codex and Pi.

```
skills/                    tool-neutral SKILL.md directories (coming)
claude/
  settings.overrides.json  keys merged into ~/.claude/settings.json
  scripts/                 status line scripts, linked into ~/.claude/scripts
```

## Install

Requires Ruby and `jq`.

```sh
git clone git@github.com:Domon/dotagents.git ~/.dotagents
cd ~/.dotagents
cp .audit-terms.example .audit-terms   # then edit
rake install
```

`rake install` does three things, each also available on its own:

- `rake link` symlinks every file in `claude/scripts` into `~/.claude/scripts`.
  Existing symlinks are replaced; a real file in the way stops the task.
- `rake settings:overrides` deep-merges `claude/settings.overrides.json` into
  `~/.claude/settings.json`. Keys in the overrides file win; every other key
  in your settings is left alone. The previous file is copied to
  `~/.claude/backups/` first. `rake settings:diff` shows the change without
  writing.
- `rake githooks` sets `core.hooksPath` so `rake audit` runs before each commit.

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

## Audit

`rake audit` fails when any file contains a term from `.audit-terms`, an
absolute `/Users/...` path, or an email address. `.audit-terms` is gitignored
so the list itself is never published; `.audit-terms.example` shows the
format.

## Development

```sh
rake test
```

## License

MIT
