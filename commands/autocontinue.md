---
description: Auto-resume this session with "continue where you left off" when the usage limit resets
argument-hint: [off | status | test <seconds>]
allowed-tools: Bash(bash ~/.claude/autocontinue/arm.sh:*)
---

# Autocontinue

NOTE: normally the UserPromptSubmit hook intercepts /autocontinue on-device
before it ever reaches you — if you are reading this, the hook is not active
(not installed, or Claude Code was not restarted after install). Handle it as
a fallback:

Run exactly this command with the Bash tool (pass the arguments through as given):

```
bash ~/.claude/autocontinue/arm.sh $ARGUMENTS
```

Then relay its output to the user in ONE short line — no elaboration, no extra
steps, no todo list.

Notes for you (Claude):
- Do NOT start any other work after arming — the user may be about to hit the limit.
- Never modify anything under ~/.claude/autocontinue/ unless the user explicitly asks.
