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

## Terminal identity

Hooks inherit the terminal environment: `ITERM_SESSION_ID` (`w4t1p0:<UUID>`),
`TERM_PROGRAM`, plus `CLAUDE_PID` and `CLAUDE_PROJECT_DIR`. See POC 3 for how the UUID is used.

## Cost

Command hooks run locally and use no tokens. `nudge hook` takes ~6ms per event and prints
nothing (stdout from `UserPromptSubmit`/`SessionStart` hooks would be added to context).

# POC 2 findings: menu bar app

`build/Nudge.app` (`scripts/build-app.sh --install` puts it in `~/Applications`). It tails
the event log incrementally (`LogTailer` + `SessionStore`) instead of replaying it, refreshes
once a second, and shows sessions grouped by state with a count on the menu bar icon.

- **Notifications need a real bundle.** `UNUserNotificationCenter` crashes without a bundle
  identifier, so a bare `swift run` can't post them. An ad-hoc signed .app is enough.
- **Not every attention state deserves a banner** (`AttentionPolicy`). Permission prompts wait
  5s (most get answered while the user is looking); "ready for review" only fires after turns
  of 30s+; errors fire immediately; sessions already waiting at launch never fire.
- **"Ready for review" goes stale.** A finished session stays in that state until the next
  prompt, which can be hours, so the badge never clears. Clicking a session (or "Mark all
  seen") marks that episode seen; a new state is a new episode. Seen markers persist.
- **Banners outlive the event.** Banners are removed once their session changes state or is
  marked seen, so Notification Center doesn't fill with things already handled.
- **Hooks must not call the build output.** They now run a copied binary at
  `~/.nudge/bin/nudge`, so rebuilding can't break logging for every running session.
- The log is ~14 MB after a day, mostly pre-allowlist lines. Startup replay takes ~150ms.

# POC 3 findings: jump to the session's tab

Clicking a session in the menu, or its banner, focuses its iTerm2 tab (`TerminalFocus`,
also `nudge focus <id|project>`).

- **Only the UUID in `ITERM_SESSION_ID` is stable.** The `wNtNpN` prefix is the position at
  creation and goes stale as tabs move (a `w0t1` session was found in a different window from
  a `w0t0` one). Matching iTerm2's `unique id of session` against the UUID works.
- **AppleScript `select` on window, tab and session, then `activate`, works across Spaces**:
  macOS switches to the Space holding the window. Split panes are covered by selecting the
  session.
- **Automation permission** is asked once ("Nudge wants to control iTerm2"). The bundle needs
  `NSAppleEventsUsageDescription`. Running from iTerm2 itself (the CLI) needs no prompt.
- **Tab titles are a better label than the project.** Claude Code titles the tab with the
  conversation topic (`◐ QR code phone handoff (claude)`); stripped of the spinner and job
  name it becomes the row title.
- **AppleScript is slow-ish:** ~170ms to list sessions, so titles are fetched when the menu
  opens or a banner is posted, not every tick.
- Non-iTerm2 terminals just get the app activated (Terminal, Ghostty, WezTerm, VS Code).
  tmux panes aren't targeted.
- Untested: clicking a banner; whether the ad-hoc signature makes macOS re-ask for
  Automation permission after each rebuild.
