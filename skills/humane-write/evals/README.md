# Regression evals for humane-write

`evals.json` holds one eval per past miss; `files/` holds the user's message for each, written in the imagined middle-out codebase (see AGENTS.md).

Send the file's contents as the user's message, with no slash command, so the eval also checks that the skill triggers. Run each from a directory that carries no project instructions or memory:

```sh
claude -p "$(cat skills/humane-write/evals/files/declining-a-retry.md)" \
  --output-format json \
  --allowedTools Read Skill
```

Grade the `expectations` against the final reply.

| id | Miss it guards against | Added |
|---|---|---|
| 1 | Asked to decline a reviewer's suggestion, the reply opened by conceding the point, spent its body taking the concession back, ran to twice the needed length, and closed with an offer nobody asked for | 2026-10-08 |
