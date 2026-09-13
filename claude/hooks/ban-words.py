#!/usr/bin/env python3
"""PreToolUse hook: stop Claude from GENERATING new text with vague filler nouns.

Goal: block NEW uses of "surface"/"affordance" (as nouns), "load-bearing"
(as a descriptor), and "clamp" (ANY form -- the word hides which direction a
limit works) in code, comments, docs, commit messages and PR descriptions --
WITHOUT blocking references to existing things or legitimate verb usage.

Three mechanisms keep legitimate usage from being blocked:

  1. Word boundaries. The patterns are \\b-anchored, matching the STANDALONE word
     only. Compound identifiers an existing codebase uses (surfaceTint,
     RoadSurfaces, paint_surface) are never matched, so referencing them
     is always fine, even in brand-new code.

  2. Baseline diff. For Write/Edit the hook reads the file's CURRENT on-disk
     content and only blocks a banned word whose type is not already present.
     Editing a file that already uses "surface" lets you keep using it.

  3. Confirm-on-resubmit override. A regex can't tell the NOUN "surface" (a
     thing) from the VERB "surfaces" ("react-router surfaces the request"). So
     the first hit blocks with guidance; if the model judges it a legitimate
     verb / real domain term and RE-RUNS THE IDENTICAL CALL, the hook lets it
     through (one-shot, per session, within CONFIRM_WINDOW). No user prompt --
     the model decides. Every block AND override is logged for auditing.

The VERBS "surfacing"/"surfaced" are always allowed (unambiguous verb spellings).
"clamp" in call syntax -- `clamp(`, `std::clamp`, `Math.clamp`, `_.clamp` -- is an
API name, not prose, and is never matched; only the bare word in running text is.

Scanned:
  - Write            -> `content`, diffed against the file's current on-disk text
  - Edit / MultiEdit -> `new_string`(s), diffed against the file's on-disk text
  - Bash             -> only `git commit ...` and `gh pr create|edit ...`

Exempt paths: anything beside the hook's real location, ~/.claude/hooks and
settings.json, and agent-instruction files (CLAUDE.md / AGENTS.md / GEMINI.md)
where the rule is spelled out.

Logs: one JSON line per event to ~/.claude/ban-words.log, with
action="block" or action="override". Override with $BAN_WORDS_LOG /
$BAN_WORDS_PENDING (used for testing). Logging never affects the decision.
"""
import datetime
import hashlib
import json
import os
import re
import sys
import time

BANNED_TERMS = [
    r"surfaces?",          # surface / surfaces -- NOUN. Verbs "surfacing" /
                           # "surfaced" are NOT banned; a VERB "surface(s)" is
                           # caught but can be kept via confirm-on-resubmit.
    r"affordances?",       # affordance, affordances
    r"load[-\s]?bearing",  # load-bearing, load bearing, loadbearing
    # clamp in ALL forms (verb and noun): direction-ambiguous jargon.
    # Call syntax (clamp(, std::clamp, _.clamp) is an API name, never matched.
    r"(?<![.:])clamp(?:s|ed|ing)?(?!\()",
]

BANNED = re.compile(r"\b(?:" + "|".join(BANNED_TERMS) + r")\b", re.IGNORECASE)

EXEMPT_PATH = re.compile(
    r"/\.claude/(?:hooks|settings)"                  # the hook's own script + settings.json
    r"|/(?:CLAUDE|AGENTS|GEMINI)(?:\.[^/]*)?\.md$",  # agent-instruction files, incl. symlink targets like CLAUDE.home.md
    re.IGNORECASE,
)
HOOK_DIR = os.path.dirname(os.path.realpath(__file__))


def exempt(path):
    if not path:
        return False
    if EXEMPT_PATH.search(path):
        return True
    real = os.path.realpath(os.path.expanduser(path))
    return os.path.commonpath([real, HOOK_DIR]) == HOOK_DIR

GIT_COMMIT = re.compile(r"\bgit\b[^|;&]*\bcommit\b")
GH_PR_WRITE = re.compile(r"\bgh\s+pr\s+(?:create|edit|comment|review)\b")

# Comment and description bodies published through the API: review replies,
# inline review comments, issue comments, and PATCHes of a PR body.
GH_API_WRITE = re.compile(
    r"\bgh\s+api\b[^|;&]*?"
    r"(?:/(?:comments|reviews)\b|-X\s*(?:POST|PATCH|PUT)\b)",
    re.IGNORECASE,
)

# `-f body=...` / `-F body=@path`; gh reads the file when the value starts with @.
GH_BODY_FILE = re.compile(r"-{1,2}[fF]\s+\w+=@(\S+)")

MAX_BASELINE_BYTES = 2_000_000
LOG_PATH = os.environ.get("BAN_WORDS_LOG") or os.path.expanduser("~/.claude/ban-words.log")
PENDING_PATH = os.environ.get("BAN_WORDS_PENDING") or os.path.expanduser("~/.claude/.ban-words-pending.json")
CONFIRM_WINDOW = 900  # seconds a pending confirm-on-resubmit stays valid


def banned_words(text):
    """Distinct banned words in `text`, in first-seen order."""
    out, seen = [], set()
    for m in BANNED.finditer(text or ""):
        key = m.group(0).lower()
        if key not in seen:
            seen.add(key)
            out.append(m.group(0))
    return out


def read_baseline(path):
    """Current on-disk text of `path` (the pre-write baseline), or '' if the
    file is new, too big, or unreadable."""
    try:
        if not path or os.path.getsize(path) > MAX_BASELINE_BYTES:
            return ""
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read()
    except OSError:
        return ""


def newly_introduced(new_text, baseline):
    """Banned words in `new_text` whose type is not already in `baseline`."""
    existing = {w.lower() for w in banned_words(baseline)}
    return [w for w in banned_words(new_text) if w.lower() not in existing]


def scanned_new_text(tool, tool_input):
    """The text this tool call newly authors (used for the confirm hash)."""
    if tool == "Write":
        return tool_input.get("content", "")
    if tool in ("Edit", "MultiEdit"):
        parts = []
        if tool_input.get("new_string"):
            parts.append(tool_input["new_string"])
        for edit in tool_input.get("edits") or []:
            if edit.get("new_string"):
                parts.append(edit["new_string"])
        return "\n".join(parts)
    if tool == "Bash":
        return tool_input.get("command", "")
    return ""


def resolved_body_files(cmd):
    """Text of any `body=@path` files the command posts, so a body kept in a
    file is scanned like an inline one. Unreadable paths contribute nothing."""
    texts = []
    for path in GH_BODY_FILE.findall(cmd):
        try:
            with open(os.path.expanduser(path), "r", errors="replace") as fh:
                texts.append(fh.read(MAX_BASELINE_BYTES))
        except OSError:
            continue
    return "\n" + "\n".join(texts) if texts else ""


def blocked_words(tool, tool_input):
    if tool == "Write":
        path = tool_input.get("file_path", "")
        if exempt(path):
            return []
        return newly_introduced(tool_input.get("content", ""), read_baseline(path))

    if tool in ("Edit", "MultiEdit"):
        path = tool_input.get("file_path", "")
        if exempt(path):
            return []
        return newly_introduced(scanned_new_text(tool, tool_input), read_baseline(path))

    if tool == "Bash":
        cmd = tool_input.get("command", "")
        if not (GIT_COMMIT.search(cmd) or GH_PR_WRITE.search(cmd)
                or GH_API_WRITE.search(cmd)):
            return []
        return banned_words(cmd + resolved_body_files(cmd))  # fresh text, no baseline

    return []


def confirm_key(data, tool, tool_input):
    """Stable hash of (session, tool, file, exact new text). An identical
    re-submit in the same session produces the same key."""
    sig = "\0".join([
        data.get("session_id") or "",
        tool,
        tool_input.get("file_path") or "",
        scanned_new_text(tool, tool_input),
    ])
    return hashlib.sha256(sig.encode("utf-8", "replace")).hexdigest()


def private_open(path, mode):
    flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | (os.O_APPEND if "a" in mode else os.O_TRUNC)
    fd = os.open(path, flags, 0o600)
    os.fchmod(fd, 0o600)
    return os.fdopen(fd, mode, encoding="utf-8")


def confirm_pending(key):
    """True if `key` was recorded recently (a deliberate re-submit -> allow),
    else record it and return False (first hit -> block). Any error returns
    False, so a broken state file simply degrades to a plain hard block."""
    try:
        now = time.time()
        try:
            with open(PENDING_PATH) as f:
                pending = json.load(f)
            if not isinstance(pending, dict):
                pending = {}
        except (OSError, ValueError):
            pending = {}
        pending = {k: t for k, t in pending.items()
                   if isinstance(t, (int, float)) and now - t < CONFIRM_WINDOW}
        already = key in pending
        if already:
            del pending[key]
        else:
            pending[key] = now
        with private_open(PENDING_PATH, "w") as f:
            json.dump(pending, f)
        return already
    except Exception:
        return False


def logged_text(tool, tool_input):
    """Text the context snippets are cut from: the authored text plus, for Bash,
    any body files the command posts."""
    text = scanned_new_text(tool, tool_input)
    if tool == "Bash":
        text += resolved_body_files(text)
    return text


def hit_contexts(text, hits, radius=40):
    """First occurrence of each hit with `radius` chars either side, one line."""
    out = []
    for w in hits:
        m = re.search(r"\b%s\b" % re.escape(w), text or "", re.IGNORECASE)
        if m:
            snippet = text[max(0, m.start() - radius):m.end() + radius]
            out.append(" ".join(snippet.split()))
    return out


def log_event(data, hits, action):
    """Append one JSONL record (action = 'block' or 'override'). Never raises."""
    try:
        tool = data.get("tool_name", "")
        tool_input = data.get("tool_input") or {}
        where = tool_input.get("file_path")
        if where is None and tool == "Bash":
            where = tool_input.get("command", "")[:120]
        entry = {
            "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "action": action,
            "tool": tool,
            "words": hits,
            "context": hit_contexts(logged_text(tool, tool_input), hits),
            "where": where,
            "cwd": data.get("cwd"),
            "session": (data.get("session_id") or "")[:8],
        }
        with private_open(LOG_PATH, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return  # Malformed input: not this hook's job to block.

    tool = data.get("tool_name", "")
    tool_input = data.get("tool_input") or {}

    hits = blocked_words(tool, tool_input)
    if not hits:
        return

    if confirm_pending(confirm_key(data, tool, tool_input)):
        # Deliberate identical re-submit -> the model has confirmed this is a
        # legitimate verb / domain use. Allow, but record it for auditing.
        log_event(data, hits, "override")
        return

    log_event(data, hits, "block")

    words = ", ".join('"%s"' % w for w in hits)
    reason = (
        "ban-words hook: your new text introduces %s. Per-word rules:\n"
        "- surface/affordance/load-bearing: banned as NOUNS naming a thing; rename precisely: "
        "surface -> area / region / page / view / route / panel / section / API; "
        "affordance -> button / link / control / toggle / menu / option; "
        "load-bearing -> critical / required / relied-on / unsafe-to-remove. "
        "A VERB use (e.g. \"react-router surfaces the request\" = exposes / reveals) or a real "
        "existing domain term is fine -- do NOT downgrade to a weaker word; RE-RUN this exact "
        "tool call unchanged and it passes.\n"
        "- clamp (any form): banned as verb AND noun -- the word hides which direction the limit "
        "works. Say the direction and outcome instead: floor -> \"raised to the minimum\" / "
        "\"won't go below X\" / \"at least X\"; ceiling -> \"capped at X\" / \"lowered to the "
        "maximum\" / \"at most X\"; both -> \"kept within X..Y\" / \"pinned into the range\". "
        "A real API name in call syntax (CSS clamp(), std::clamp, _.clamp, Math.clamp) never "
        "triggers; if the word is genuinely unavoidable, RE-RUN this exact tool call unchanged "
        "and it passes.\n"
        "(Sanctioned confirm; never split or obfuscate a word to dodge the check. Never triggers "
        "anyway: the verbs 'surfacing'/'surfaced', call syntax like clamp( or std::clamp, compound "
        "identifiers like surfaceTint or scrollClampGuard, and words already present in the "
        "file being edited.)"
        % words
    )

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))


if __name__ == "__main__":
    main()
