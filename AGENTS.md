# AGENTS.md

Rules for agents working in this repository.

## What this repository is

Reusable configuration for AI coding agents, published under a personal
GitHub account. The repository is public. Nothing employer-specific may
appear in file contents: no company or product names, internal hostnames,
ticket prefixes, Slack workspace IDs, identifiers copied from a private
codebase, absolute `/Users/...` paths, or email addresses. If a value is
needed only on one machine, it does not belong here.

Commit metadata is out of scope. The author's name and email, the signing
key, and Co-Authored-By trailers are public attribution the owner has chosen.
Do not flag them.

## Moving files in

Files enter this repository by moving out of a tool's live config directory
such as `~/.claude`. For each file:

1. Move it into the matching folder here (see Layout).
2. Run `rake link` so the old path becomes a symlink to the new location.
3. Delete any leftover copy elsewhere so exactly one copy exists.
4. Scrub comments, example paths, test fixtures, and URLs before staging.
   Example identifiers in messages, comments and fixtures are invented, never
   lifted from a real codebase; the fictional names are Pied Piper for the
   organisation and middle-out for the application.
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

Arrays are replaced, not combined, except under `hooks`: there a group is
matched by its `matcher` and an entry by its `command`, with a leading
`/Users/<name>` read as `~` and the file extension ignored, and a match is
replaced in place while anything unmatched is appended. Other list-valued keys stay out of the overrides file.

## Code

Ruby. Behaviour lives in `lib/dotagents.rb` and the hooks under `claude/`,
with tests in `test/`, run by `rake test`. New behaviour arrives with a test.
No comments unless the code cannot say it.

## Git

Commits are signed. `.githooks/pre-commit` runs `rake audit`; never bypass it
with `--no-verify`. Do not push. The owner reviews every commit before it
leaves the machine.

## Reviewing

These are deliberate and are not findings:

- The Pied Piper and middle-out names, and paths built from them.
- The four banned words appearing in `claude/hooks/ban-words.py`, its tests,
  and the README section about it. They are the rule's own subject.
- Hook logs and state files under `~/.claude`.

## Documentation

When a rake task, path, or install step changes, update the README that
documents it in the same commit: the root `README.md` for install, layout
and development, the tool folder's README (`claude/README.md`) for that
tool's components.
