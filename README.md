# dotagents

Reusable configuration for AI coding agents, kept in one repository and
linked into each tool's own directory. Today it holds Claude Code pieces;
the layout leaves room for Codex and Pi.

```
skills/                    tool-neutral SKILL.md directories, linked into ~/.claude/skills and ~/.agents/skills
.claude/                   settings and skills for working on this repository
.githooks/                 pre-commit audit, pre-push approval check
claude/
  README.md                what each Claude Code piece does
  settings.overrides.json  keys merged into ~/.claude/settings.json
  scripts/                 status line scripts, linked into ~/.claude/scripts
  hooks/                   Claude Code hooks, linked into ~/.claude/hooks
```

## Install

Requires Ruby and `jq`. Development also needs the Codex CLI for the review step.

```sh
git clone git@github.com:Domon/dotagents.git ~/.dotagents
cd ~/.dotagents
cp .audit-terms.example .audit-terms         # replace the example terms with your own
cp .review-sources.example .review-sources   # list private codebases nothing here may resemble
rake install
```

`rake install` does three things, each also available on its own:

- `rake link` symlinks every file and folder in `claude/scripts` and `claude/hooks` into
  the same directory under `~/.claude`, and every directory in `skills/` into
  both `~/.claude/skills` and `~/.agents/skills`, one link per skill so
  Claude Code and Codex read the same files. Existing symlinks are replaced,
  links into this repository whose source is gone are removed, a real file in
  the way stops the task, and files you keep there yourself are untouched.
- `rake settings:overrides` deep-merges `claude/settings.overrides.json` into
  `~/.claude/settings.json`. Keys in the overrides file win; every other key
  in your settings is left alone. Under `hooks`, entries are matched by
  command (a leading `/Users/<name>` counts as `~`, and the file extension is
  ignored so a hook survives a change of language) and replaced in place, so
  your own hooks in the same event keep running. The previous file is copied
  to `~/.claude/backups/` first. `rake settings:diff` shows the change without
  writing.
- `rake githooks` sets `core.hooksPath` so the audit runs before each commit
  and the approval check before each push.

## Components

| Tool        | Piece        | Purpose                                                   | Docs                                    |
| ----------- | ------------ | --------------------------------------------------------- | --------------------------------------- |
| Claude Code | status line  | model, effort, cwd, session, cost and context on one line | [claude/README.md](claude/README.md#status-line)  |
| Claude Code | turn cost    | Stop hook that prices each turn from the transcript       | [claude/README.md](claude/README.md#turn-cost)    |
| Claude Code | banned words | PreToolUse hook that blocks vague filler nouns in new text | [claude/README.md](claude/README.md#banned-words) |
| Claude Code | comment lint | PreToolUse hook that blocks comment walls and review-register comments | [claude/README.md](claude/README.md#comment-lint) |
| Claude Code | tidy gates   | Hooks that require a /tidy pass before Ruby is committed or a branch pushed | [claude/README.md](claude/README.md#tidy-gates) |

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

## Review before push

Every commit is reviewed by Codex before it leaves the machine. The
`/codex-review` project skill sends each unpushed commit, message and patch,
to Codex against the Reviewing section of `AGENTS.md`, fixes what it finds,
and records the approval under `~/.local/state/dotagents/codex-review/`
(`$XDG_STATE_HOME` when set), one folder per repository shared by all its
worktrees. The pre-push hook
refuses a push that contains a commit without a record, and the Stop hook in
`.claude/settings.json` asks for the review when a turn ends with unapproved
commits. Records are per sha: amending or rebasing a commit means reviewing
it again. To force a re-review, delete its record.

A term list cannot catch private code whose names were changed. When
`.review-sources` lists private codebases, the bundle opens by asking the
reviewer to search them, history included, for the shape behind every
example, fixture and snippet in the commits, and to treat a match as a P0.
Codex's read-only sandbox can read those paths; the file is gitignored and
`.review-sources.example` shows the format.

```sh
rake review:status                # unpushed commits, approved or pending
rake review:bundle                # what the reviewer receives
rake review:record SESSION=<id>   # record approval for every unpushed commit
```

## License

MIT
