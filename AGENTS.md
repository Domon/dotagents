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
   Example identifiers in messages, comments and fixtures come from the
   imagined codebase below, never from a real one.
5. Write examples and fixtures from the move or rule they teach, not from
   code you have open. A renamed copy of private code is still private
   code: its structure, comments and reasoning identify it.
6. Run `rake audit` and read every finding.

Never add a real term to `.audit-terms.example`. Real terms go in the
gitignored `.audit-terms`. The same split holds for `.review-sources`, the
gitignored list of private codebases the Codex reviewer checks every commit
against for resemblance, and its committed example.

## Layout

- Tool-neutral content sits at the top level: `skills/` holds `SKILL.md`
  directories that more than one tool can read.
- Tool-specific content sits under a folder named for the tool: `claude/`
  today, `codex/` and `pi/` when needed. Each mirrors that tool's own config
  directory, so `claude/scripts/` corresponds to `~/.claude/scripts/`.
- Entries are linked one at a time, never a whole target directory, so this
  repository and private sources can both feed the same target directory. A
  file is one entry; a skill directory is one entry.

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

Ruby. Behaviour lives in `lib/dotagents.rb` and the hooks under
`claude/hooks/`, `.claude/hooks/` and `.githooks/`, with tests in `test/`,
run by `rake test`. New behaviour arrives with a test. No comments unless
the code cannot say it.

## Git

Commits are signed. `.githooks/pre-commit` runs `rake audit:staged` and
`.githooks/pre-push` checks that Codex approved every commit; never bypass
either with `--no-verify`. Do not push. The owner reviews every commit
before it leaves the machine, after Codex has.

## Reviewing

Every commit is reviewed by Codex before it is pushed, through the
`/codex-review` skill; `.githooks/pre-push` refuses a commit without a
recorded approval. The unit of review is one commit: its patch and its
message together. Uncommitted work is not reviewed.

The patch is held to the rules in this file.

The message describes this repository's change to a reader of this
repository: an imperative subject, then a few short lines on what changed
and why it matters here. Anything that reader could not follow from this
repository and public sources is out, and how the commit was produced is
not part of the change. Trailers are attribution, not content.

Severity, in the order the owner cares about:

- P0: anything private or employer-specific in the patch or the message.
  This is the reason the review exists.
- P1: a message about the process rather than the change; behaviour in
  `lib/` or a hook without a test; a non-executable hook.
- P2: everything else. Readable code wins over complete edge-case coverage.

A commit is REVISE on a P0 or P1 and is amended in place rather than
followed by a fix-up commit. P2 findings are reported to the owner, not
acted on, unless the owner asks.

These are deliberate and are not findings:

- The Pied Piper and middle-out names, and paths built from them.
- The four banned words appearing in `claude/hooks/ban-words.rb`, its tests,
  and the README section about it. They are the rule's own subject.
- Commit metadata: author name and email, the signature, trailers.
- Hook logs and state files under `~/.claude`, and approval records and
  tidy passes under `~/.local/state/dotagents`.

## The imagined codebase

Fixtures, examples and sample paths come from one fictional company so they
never resemble a real one. Invent within it; never lift a name from a real
codebase.

| Role | Names |
| --- | --- |
| Organisation, GitHub org | Pied Piper, `pied-piper` |
| Application, repository | middle-out, `pied-piper/middle-out`: a compression benchmark service. Codecs and corpora are submitted, benchmark runs are scored, a leaderboard ranks them. Rails API plus React front end. |
| Ruby models and services | `Codec`, `Corpus`, `BenchmarkRun`, `Weissman::Score`, `Leaderboard`; `app/services/score_benchmark_run.rb` |
| React components and stories | `CodecPicker`, `CorpusSelect`, `BenchmarkRunCard`, `WeissmanScoreBadge`, `LeaderboardTable`; `BenchmarkRunCard.stories.tsx` |
| Hosts | `middle-out.test`, `api.middle-out.test` |
| Tickets and pull requests | `PP-4242`, PR 4242 |
| People | Roles only: "a reviewer", "the submitter". Never names. |
| Terms that must never be committed, used only in `.audit-terms.example` and the audit tests | Hooli: `Hooli`, `hooli.internal`, `HOOLI-` |

## Documentation

When a rake task, path, or install step changes, update the README that
documents it in the same commit: the root `README.md` for install, layout
and development, the tool folder's README (`claude/README.md`) for that
tool's components.
