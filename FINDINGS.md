# POC 1 findings: Claude Code hooks as an attention signal

Claude Code 2.1.295, macOS, iTerm2. Sources: ~2 hours of real use (27 sessions, ~1,800
events) plus scripted interactive sessions driven through a pty.

## What the hooks tell us

| Situation | Hooks that fire | Nudge state |
|---|---|---|
| Session starts | `SessionStart` (`source`: startup / clear / resume) | idle |
| User sends a prompt | `UserPromptSubmit` | working |
| Tool runs | `PreToolUse` → `PostToolUse` (or `PostToolUseFailure`) | working |
| Permission prompt shown | `PermissionRequest` immediately, `Notification(permission_prompt)` ~6s later if unanswered | permission requested |
| Permission approved | `PostToolUse` | working |
| Turn finishes | `Stop` (then a `SubagentStop` from an internal agent, even with no subagents) | ready for review |
| Turn fails (API error etc.) | `StopFailure` | stopped on error |
| Left idle | `Notification(idle_prompt)` ~60s after `Stop` | (no change) |
| `/clear` | `SessionEnd(clear)` then `SessionStart(clear)` with a **new** session id, same process | |
| `/exit` | `SessionEnd(prompt_input_exit)` | ended |
| Tab closed (SIGHUP) | `SessionEnd(other)` | ended |
| Process killed (SIGKILL) | nothing | gone (detected via `kill -0 $CLAUDE_PID`) |
| `--resume` | `SessionStart(resume)` with the **same** session id | |

## Gaps found, and how nudge covers them

1. **Esc interrupt fires no hook**, not even `idle_prompt` later. **Esc on a permission
   prompt fires no hook** either (and `PermissionDenied` doesn't fire for it). Both leave a
   `[Request interrupted by user…]` entry in the transcript (`transcript_path` is in every
   payload), so the reducer checks the transcript tail for sessions that look working or
   blocked.
2. **`claude -p` sessions** (e.g. a scripted task loop) produce `Stop` per run and
   `PermissionRequest`s that are auto-denied within ~1s. They're detected via the agent's
   argv (`-p`/`--print`), matching `CLAUDE_CODE_ENTRYPOINT=sdk-cli`, and never count as
   attention.
3. **Payload `cwd` follows `cd` inside Bash**, so a session can appear to move between
   projects. Use `CLAUDE_PROJECT_DIR` instead.
4. **Payloads include prompts, tool input/output and assistant messages.** The hook keeps an
   allowed list of fields so the log holds no conversation content.
5. In **auto permission mode** (the default here), `PermissionRequest` is rare: the
   classifier approves most tools, and sandboxed Bash runs without prompting.
6. Sessions can be first seen mid-life (hooks installed while running): no `SessionStart`.

## Terminal identity (for POC 3)

Hooks inherit the terminal environment: `ITERM_SESSION_ID` (`w4t1p0:<UUID>`),
`TERM_PROGRAM`, plus `CLAUDE_PID` and `CLAUDE_PROJECT_DIR`. The UUID should map to an
iTerm2 session via AppleScript; cross-Space activation is still untested.

## Cost

Command hooks run locally and use no tokens. `nudge hook` takes ~6ms per event and prints
nothing (stdout from `UserPromptSubmit`/`SessionStart` hooks would be added to context).
