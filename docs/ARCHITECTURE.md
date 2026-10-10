# How nudge works

Nudge tells you which Claude Code sessions need you. It has three parts that only talk
through a log file:

```
Claude Code session ──hook──▶ nudge hook ──append──▶ ~/.nudge/events.jsonl
                                                          │
                       nudge status / nudge focus ◀───────┤ (replay the whole log)
                       Nudge.app (menu bar)       ◀───────┘ (follow the log as it grows)
```

Claude Code runs a command hook on every lifecycle event. The hook is the `nudge` binary,
copied to `~/.nudge/bin/nudge` so a rebuild can't break logging in running sessions. It adds
one JSON line per event to the log, and readers rebuild session state from it. No server, no
tokens used. The hook entries live in your Claude Code `settings.json`, not in this repo.

See `FINDINGS.md` for the hook behaviour these rules are based on.

## 1. Writing: `nudge hook`

`Sources/nudge/main.swift` reads the hook payload from stdin and calls `EventLog.append`
(`Sources/NudgeCore/EventLog.swift`). It always prints nothing and exits 0, because output
from some hooks gets added to Claude's context and a failing hook must never disrupt a
session.

Each line is the payload plus:

- **A timestamp.**
- **Terminal identity:** `ITERM_SESSION_ID`, `TERM_PROGRAM`, `CLAUDE_PID`,
  `CLAUDE_PROJECT_DIR`, tmux vars.
- **Process ancestry:** walked with `sysctl` in `ProcessTree`.
- **A `headless` flag:** set when the agent's argv contains `-p`/`--print`, read via
  `KERN_PROCARGS2`.

**Privacy:** payload fields go through an allowlist (`keptPayloadKeys`), so prompts, tool
input and output, and assistant text never reach the log.

**Concurrency:** the file is opened with `O_APPEND`, so lines from hooks that fire at the
same time don't get mixed together.

## 2. Reducing: events → session state

`Sources/NudgeCore/Session.swift`. `SessionReducer.transition` is the state machine:

| Event | → State |
|---|---|
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure` | working |
| `PermissionRequest`, `Notification(permission_prompt)` | needsPermission |
| `Stop`, `Notification(idle_prompt)` | readyForReview |
| `StopFailure` | failed |
| `SessionEnd` | ended |

The attention states are needsPermission, readyForReview and failed. Headless (`claude -p`)
sessions never count as attention.

`SessionStore.apply` handles one entry at a time, so the app can process new lines without
replaying everything. It records the project dir, preferring `CLAUDE_PROJECT_DIR` because the
payload's `cwd` changes when Bash runs `cd`.

`SessionStore.resolved()` adds two checks the hooks can't provide:

- **Dead process:** if `kill -0` on the agent PID fails, the session becomes `gone`. This
  covers SIGKILL, which fires no hook.
- **Esc interrupts:** these fire no hook at all. `Transcript.lastTurnWasInterrupted` reads the
  end of the session's transcript for the `[Request interrupted by user` marker and sets the
  session back to idle.

## 3. Reading

### CLI (`Sources/nudge/main.swift`)

- `nudge status [--all]`: replays the whole log and prints sessions grouped by state.
- `nudge focus <id-prefix|project>`: jumps to that session's terminal tab.
- `nudge path`: prints where the log is.

### Menu bar app (`Sources/NudgeBar/`)

**`SessionMonitor`** runs once a second:

1. `LogTailer` reads only the bytes added since its last read, keeping any half-written
   line for next time.
2. The new entries go into the `SessionStore`.
3. It decides whether to post notifications.
4. It clears banners that no longer apply.

**`AttentionPolicy`** (`Sources/NudgeCore/Attention.swift`) decides whether a session is
worth a banner:

| State | Rule |
|---|---|
| Permission prompt | waits a 5s grace period first |
| Ready for review | only notifies after turns of 30s or more |
| Error | notifies right away |
| Already waiting at app launch | never notifies |

**Episodes:** the key `id|state|since` names one stretch of a session in one state. "Seen"
markers and "already notified" both use this key. Re-entering a state later starts a new
episode, so it can notify again. Seen markers are kept in `UserDefaults`.

**`Notifier`** sends one banner per session, keyed by session id, so a newer state replaces
the older banner. Clicking a banner calls `onOpen`, which focuses the session. Notifications
only work from a real `.app` bundle; without a bundle identifier `UNUserNotificationCenter`
crashes.

**`MenuView` / `NudgeBarApp`:**

- The menu bar shows a `MenuBarExtra` bell with the attention count.
- The menu lists sessions under Needs attention / Working / Idle / Headless.
- Clicking a row focuses the session's tab and marks it seen.

**Switcher (⌘⇧J)** (`Switcher.swift`, `HotKey.swift`): a Spotlight-style panel over the same
`SessionMonitor`, so it shares state with the menu and notifications.

- **Shortcut:** Carbon `RegisterEventHotKey`. It needs no Accessibility permission and works
  over full-screen apps. If another app already holds ⌘⇧J, the menu says so.
- **Panel:** a non-activating `NSPanel` that joins every Space. It takes keyboard focus
  without activating Nudge. A local key monitor handles ↑↓ (or ⇧J/⇧K), Enter and Esc so the search
  field keeps focus. It closes when it loses key status.
- **Ranking:** `SessionSearch` (`Sources/NudgeCore/SessionSearch.swift`).
  - Search: every query word must appear in the tab title, project, path or id.
  - Order: unseen attention comes first, oldest first. Other sessions follow by latest use
    (last jump from Nudge, last prompt or last hook event). Headless sessions go last.
- **Choosing a row** goes through `SessionMonitor.focus`, the same path as menu clicks.

## 4. Jumping to the tab

`Sources/NudgeCore/TerminalFocus.swift`, AppleScript against iTerm2:

- **Matching:** only the UUID part of `ITERM_SESSION_ID` is used. The `w0t1p0` prefix is the
  tab's position when it was created and goes out of date when tabs move.
- **Focusing:** it finds the iTerm2 session with that `unique id`, selects its window, tab
  and pane, activates iTerm2 through LaunchServices (`NSWorkspace.openApplication`), then
  selects the window again.
  - AppleScript `activate` alone isn't enough when Nudge isn't frontmost (for example, after
    a banner click): macOS 14 doesn't let a background app hand activation to another app.
  - The second select is what switches Spaces. If iTerm2 has a window on the current Space,
    activating it alone stays there.
- **Other terminals:** Terminal, Ghostty, WezTerm and VS Code only get their app brought to
  the front. tmux panes aren't targeted.
- **Tab titles:** `itermTitles()` reads tab titles, which Claude Code sets to the
  conversation topic, and uses them as row labels. Fetching them takes about 170ms, so it
  happens when the menu opens or a banner is posted, not every tick.

## Build & test

- `scripts/build-app.sh [--install]`:
  - Builds the release binary and wraps it in `build/Nudge.app` with an Info.plist.
  - The Info.plist sets `LSUIElement` (no Dock icon) and the Automation usage string
    macOS needs before the app can control iTerm2.
  - Ad-hoc signs the bundle.
  - With `--install`, copies it to `~/Applications` and relaunches it.
- `swift test` runs `Tests/NudgeCoreTests`. Set `$NUDGE_HOME` to point the log somewhere
  else.
