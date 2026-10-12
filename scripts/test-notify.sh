#!/bin/sh
# Fakes hook events in ~/.nudge/events.jsonl so the running Nudge.app posts a banner.
# Usage: test-notify.sh [error|permission|review|end] [project-dir]
# Each kind uses its own fake session id, so all three banners can be up at once.
# `end` sends SessionEnd for all three and stops the stand-in process.
set -eu
kind=${1:-error}
dir=${2:-$PWD}
log="${NUDGE_HOME:-$HOME/.nudge}/events.jsonl"
pidfile="${TMPDIR:-/tmp}/nudge-test-agent.pid"

# The app marks a session "gone" when its agent PID is dead, so a long sleep stands in
# for the Claude process.
if [ ! -f "$pidfile" ] || ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    nohup sleep 1800 >/dev/null 2>&1 &
    echo $! > "$pidfile"
fi
pid=$(cat "$pidfile")

emit() { # session event ts [extra-json]
    printf '{"env":{"CLAUDE_PID":"%s","CLAUDE_PROJECT_DIR":"%s","ITERM_SESSION_ID":"%s","TERM_PROGRAM":"%s"},"headless":false,"procs":[],"payload":{"session_id":"%s","hook_event_name":"%s","cwd":"%s"%s},"ts":%s}\n' \
        "$pid" "$dir" "${ITERM_SESSION_ID:-}" "${TERM_PROGRAM:-}" "$1" "$2" "$dir" "${4:-}" "$3" >> "$log"
}

now=$(date +%s)
case $kind in
error)
    emit nudge-test-error UserPromptSubmit $((now - 5))
    emit nudge-test-error StopFailure "$now" ;;
permission)
    # Banner arrives after the 5s grace period.
    emit nudge-test-permission UserPromptSubmit $((now - 5))
    emit nudge-test-permission PermissionRequest "$now" ',"tool_name":"Bash"' ;;
review)
    # Only turns of 30s+ notify, so the prompt is backdated.
    emit nudge-test-review UserPromptSubmit $((now - 45))
    emit nudge-test-review Stop "$now" ;;
end)
    for k in error permission review; do emit "nudge-test-$k" SessionEnd "$now"; done
    kill "$pid" 2>/dev/null || true
    rm -f "$pidfile" ;;
*)
    echo "usage: $0 [error|permission|review|end] [project-dir]" >&2; exit 2 ;;
esac
echo "sent $kind for $dir"
