# Regression evals for /visualize

`evals.json` holds one eval per past miss, plus a routing check; `files/` holds the user's message for each, written in the imagined middle-out codebase (see AGENTS.md).

Send the file's contents as the user's message, with no slash command, so the eval also checks that the skill triggers. Run each from a directory that carries no project instructions or memory, with `open` denied so no browser window appears:

```sh
claude -p "$(cat skills/visualize/evals/files/benchmark-run-lifecycle.md)" \
  --output-format json \
  --allowedTools Bash Read Write Edit Glob Grep Skill \
  --disallowedTools "Bash(open:*)"
```

Grade the `expectations` against the final reply and the files the run wrote.

| id | Miss it guards against | Added |
|---|---|---|
| 1 | Asked to visualize how code works, the reply was two or three Mermaid blocks in a terminal that cannot draw them, often opened by a line about what was rendered rather than an answer | 2026-09-28 |
| 2 | Not a miss: checks that numbers go to the charting skill and still meet the deliverable | 2026-09-28 |
