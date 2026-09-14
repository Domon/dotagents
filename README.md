# dotagents

Reusable configuration for AI coding agents, kept in one repository and
linked into each tool's own directory. Today it holds Claude Code pieces;
the layout leaves room for Codex and Pi.

```
skills/                    tool-neutral SKILL.md directories (coming)
claude/
  README.md                what each Claude Code piece does
  settings.overrides.json  keys merged into ~/.claude/settings.json
  scripts/                 status line scripts, linked into ~/.claude/scripts
  hooks/                   Claude Code hooks, linked into ~/.claude/hooks
```

## Install

Requires Ruby and `jq`.

```sh
git clone git@github.com:Domon/dotagents.git ~/.dotagents
cd ~/.dotagents
cp .audit-terms.example .audit-terms   # replace the example terms with your own
rake install
```

`rake install` does three things, each also available on its own:

- `rake link` symlinks every file in `claude/scripts` and `claude/hooks` into
  the same directory under `~/.claude`. Existing symlinks are replaced, links
  into this repository whose source is gone are removed, a real file in the
  way stops the task, and files you keep there yourself are untouched.
- `rake settings:overrides` deep-merges `claude/settings.overrides.json` into
  `~/.claude/settings.json`. Keys in the overrides file win; every other key
  in your settings is left alone. Under `hooks`, entries are matched by
  command (a leading `/Users/<name>` counts as `~`, and the file extension is
  ignored so a hook survives a change of language) and replaced in place, so
  your own hooks in the same event keep running. The previous file is copied
  to `~/.claude/backups/` first. `rake settings:diff` shows the change without
  writing.
- `rake githooks` sets `core.hooksPath` so the audit runs before each commit.

## Components

| Tool        | Piece        | Purpose                                                   | Docs                                    |
| ----------- | ------------ | --------------------------------------------------------- | --------------------------------------- |
| Claude Code | status line  | model, effort, cwd, session, cost and context on one line | [claude/README.md](claude/README.md#status-line)  |
| Claude Code | turn cost    | Stop hook that prices each turn from the transcript       | [claude/README.md](claude/README.md#turn-cost)    |
| Claude Code | banned words | PreToolUse hook that blocks vague filler nouns in new text | [claude/README.md](claude/README.md#banned-words) |

## Development

```sh
rake test            # the whole suite
rake audit           # every file, against .audit-terms plus path and email checks
rake settings:diff   # what settings:overrides would change
```

`rake audit` fails when any file contains a term from `.audit-terms`, an
absolute `/Users/...` path, or an email address. `.audit-terms` is gitignored
so the list itself is never published; `.audit-terms.example` shows the
format. A list with no terms, comments only, is valid: the path and email
checks run regardless. The pre-commit hook runs `rake audit:staged`, which
checks only the content staged for the next commit.

## License

MIT
