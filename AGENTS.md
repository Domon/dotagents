# AGENTS.md

Rules for agents working in this repository.

## What this repository is

Reusable configuration for AI coding agents, published under a personal
GitHub account. The repository is public. Nothing employer-specific may
appear in it: no company or product names, internal hostnames, ticket
prefixes, Slack workspace IDs, absolute `/Users/...` paths, or email
addresses. If a value is needed only on one machine, it does not belong here.

## Moving files in

Files enter this repository by moving out of a tool's live config directory
such as `~/.claude`. For each file:

1. Move it into the matching folder here (see Layout).
2. Run `rake link` so the old path becomes a symlink to the new location.
3. Delete any leftover copy elsewhere so exactly one copy exists.
4. Scrub comments, example paths, test fixtures, and URLs before staging.
5. Run `rake audit` and read every finding.

Never add a real term to `.audit-terms.example`. Real terms go in the
gitignored `.audit-terms`.

## Layout

- Tool-neutral content sits at the top level: `skills/` holds `SKILL.md`
  directories that more than one tool can read.
- Tool-specific content sits under a folder named for the tool: `claude/`
  today, `codex/` and `pi/` when needed. Each mirrors that tool's own config
  directory, so `claude/scripts/` corresponds to `~/.claude/scripts/`.
- Files are linked one at a time, never as whole directories, so this
  repository and private sources can both feed the same target directory.

## Settings

Shared Claude Code settings live in `claude/settings.overrides.json` and reach
the machine through `rake settings:overrides`, which deep-merges them into
`~/.claude/settings.json`. Edit shared keys here, never in the live file, or
the next run overwrites the hand edit. Run `rake settings:diff` first.

The merge replaces arrays instead of combining them. Keep `hooks` and other
list-valued keys out of the overrides file until the merge unions them.

## Code

Ruby. Behaviour lives in `lib/dotagents.rb` with tests in `test/`, run by
`rake test`. New behaviour arrives with a test. No comments unless the code
cannot say it.

## Git

Commits are signed. `.githooks/pre-commit` runs `rake audit`; never bypass it
with `--no-verify`. Do not push. The owner reviews every commit before it
leaves the machine.

## Documentation

When a rake task, path, or install step changes, update `README.md` in the
same commit.
