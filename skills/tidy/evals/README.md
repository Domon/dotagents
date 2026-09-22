# Regression evals for /tidy

`evals.json` holds one eval per past miss; `files/` holds fixtures written in the imagined middle-out codebase (see AGENTS.md) that share only their shape with the code that exposed the miss. Never copy real project code here.

Re-run with the skill-creator workflow (`/skill-creator`, "Running and evaluating test cases"): snapshot the skill before editing, then dispatch one subagent per eval against the edited skill and one against the snapshot, and grade the `expectations` with `agents/grader.md`. Invoke the skill exactly as a user would: `/tidy <absolute fixture path> <diff command>` from `prompt`, with the fixture path resolved against this skill's root.

| id | Miss it guards against | Added |
|---|---|---|
| 1 | Six `module_function` helpers left public and a `call` entry point on a non-callable; a sibling module using the same idiom was taken as precedent | 2026-09-16 |
