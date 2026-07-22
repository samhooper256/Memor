#!/usr/bin/env python3
"""PreToolUse hook for the Bash tool.

Auto-approves a command when every segment of a compound command
(split on top-level &&, ||, |, ; and newlines) matches a Bash(...)
allow rule from .claude/settings.json / .claude/settings.local.json,
or is an sqlite3 invocation.

Heredocs with a QUOTED delimiter (<<'EOF' / <<"EOF") are handled:
the body expands nothing, so it is pure data for the receiving
command — equivalent to piping a fixed string, which the allow rules
already permit. The body is stripped and the command line is vetted
normally. Unquoted-delimiter heredocs ($(...) in the body would
execute) still produce no decision.

Anything else the splitter can't safely analyze (command
substitution, backticks, subshells, brace groups, backgrounding
with &) produces NO decision, which falls back to Claude Code's
normal permission flow. A segment matching a deny rule also produces
no decision.
"""

import json
import os
import sys
from fnmatch import fnmatchcase

# Always-permitted prefixes, independent of the settings files.
EXTRA_ALLOW = ["sqlite3:*"]


def load_rules():
    """Collect Bash(...) allow/deny rule bodies from the project settings."""
    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    allow, deny = list(EXTRA_ALLOW), []
    for name in ("settings.json", "settings.local.json"):
        try:
            with open(os.path.join(root, ".claude", name)) as f:
                perms = json.load(f).get("permissions", {})
        except (OSError, ValueError):
            continue
        for target, rules in ((allow, perms.get("allow", [])),
                              (deny, perms.get("deny", []))):
            for rule in rules:
                if isinstance(rule, str) and rule.startswith("Bash(") and rule.endswith(")"):
                    # Rules escape literal parens as \( \) inside Bash(...).
                    target.append(rule[5:-1].replace("\\(", "(").replace("\\)", ")"))
    return allow, deny


def matches(command, pattern):
    """Match one command segment against one rule body."""
    if pattern.endswith(":*"):
        prefix = pattern[:-2]
        return command == prefix or command.startswith(prefix + " ")
    if "*" in pattern or "?" in pattern or "[" in pattern:
        return fnmatchcase(command, pattern)
    return command == pattern


def split_compound(command):
    """Split on top-level unquoted && || | ; and newlines.

    Returns None when the command uses constructs whose effect can't be
    determined from the segment text alone, so the caller stays silent
    and the normal permission flow takes over.
    """
    parts, buf = [], []
    i, n = 0, len(command)
    in_single = in_double = False
    while i < n:
        c = command[i]
        if in_single:
            buf.append(c)
            if c == "'":
                in_single = False
            i += 1
            continue
        if c == "\\":
            buf.append(command[i:i + 2])
            i += 2
            continue
        if in_double:
            if c == "`" or (c == "$" and command[i:i + 2] == "$("):
                return None
            buf.append(c)
            if c == '"':
                in_double = False
            i += 1
            continue
        if c == "'":
            in_single = True
            buf.append(c)
            i += 1
            continue
        if c == '"':
            in_double = True
            buf.append(c)
            i += 1
            continue
        if c in "`(){}":
            return None
        if c == "$" and command[i:i + 2] == "$(":
            return None
        if c == "<" and command[i:i + 2] == "<<":
            if command[i:i + 3] == "<<<":
                buf.append("<<<")
                i += 3
                continue  # herestring word is data; quote/$( checks still apply
            # Heredoc: only a quoted delimiter keeps the body inert.
            j = i + 2
            if command[j:j + 1] == "-":
                j += 1
            while command[j:j + 1] in (" ", "\t"):
                j += 1
            quote = command[j:j + 1]
            if quote not in ("'", '"'):
                return None  # unquoted delimiter: body would expand $(...)
            k = command.find(quote, j + 1)
            delim = command[j + 1:k] if k != -1 else ""
            if not delim or command[k + 1:k + 2] not in ("", " ", "\t", "\n"):
                return None
            nl = command.find("\n", k + 1)
            if nl == -1 or "<<" in command[k + 1:nl]:
                return None  # no body line / second heredoc on the line
            strip_tabs = command[i + 2:i + 3] == "-"
            pos, end = nl + 1, None
            while end is None:
                line_end = command.find("\n", pos)
                stop = line_end if line_end != -1 else len(command)
                line = command[pos:stop]
                if (line.lstrip("\t") if strip_tabs else line) == delim:
                    end = stop
                elif line_end == -1:
                    return None  # unterminated heredoc
                else:
                    pos = line_end + 1
            # Drop the body + terminator; keep vetting the command line.
            buf.append(command[i:k + 1])
            command = command[:nl + 1] + command[end:]
            n = len(command)
            i = k + 1
            continue
        if c == "&":
            if command[i:i + 2] == "&&":
                parts.append("".join(buf))
                buf = []
                i += 2
                continue
            if command[i:i + 2] == "&>":  # redirect stdout+stderr
                buf.append("&>")
                i += 2
                continue
            if i > 0 and command[i - 1] == ">":  # e.g. 2>&1
                buf.append(c)
                i += 1
                continue
            return None  # backgrounding
        if c == "|":
            if command[i:i + 2] == "||":
                parts.append("".join(buf))
                buf = []
                i += 2
                continue
            parts.append("".join(buf))  # | or |&
            buf = []
            i += 2 if command[i:i + 2] == "|&" else 1
            continue
        if c in ";\n":
            parts.append("".join(buf))
            buf = []
            i += 1
            continue
        buf.append(c)
        i += 1
    if in_single or in_double:
        return None
    parts.append("".join(buf))
    return [p.strip() for p in parts if p.strip()]


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    if data.get("tool_name") != "Bash":
        return
    command = (data.get("tool_input") or {}).get("command") or ""
    parts = split_compound(command)
    if not parts:
        return
    allow, deny = load_rules()
    if any(matches(p, d) for p in parts for d in deny):
        return
    if all(any(matches(p, a) for a in allow) for p in parts):
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason":
                    "Every command in the compound matches a project allow rule (or sqlite3)",
            }
        }))


if __name__ == "__main__":
    main()