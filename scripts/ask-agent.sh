#!/usr/bin/env bash
#
# Send a prompt to one pane of the tmux session built by start-agents.sh and read
# the answer back.
#
# Usage:
#   ./scripts/ask-agent.sh agent "implement this screen"        send a string
#   ./scripts/ask-agent.sh codex -f docs/ui-consult-prompt.md   send a file
#   cat notes.md | ./scripts/ask-agent.sh orchestrator -        send stdin
#   ./scripts/ask-agent.sh agent --read                         read without sending
#
# Target: orchestrator | agent | codex
#
# Options:
#   -f, --file FILE   send the contents of FILE
#   -r, --read        print the pane contents instead of sending
#   -w, --wait SEC    print the pane contents SEC seconds after sending (default: 0, no wait)
#   -n, --lines N     how many lines to read (default: 200)
#
# Multi-line prompts go through a tmux buffer as a paste. Sending them with
# send-keys line by line would submit the prompt at every newline.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/agent-session.sh"
SESSION="$AGENT_SESSION"
WAIT=0
LINES=200
MODE="send"
PROMPT=""
ROLE=""

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)  [[ -r "${2:-}" ]] || die "cannot read file: ${2:-(missing)}"
                PROMPT="$(cat "$2")"; shift 2 ;;
    -r|--read)  MODE="read"; shift ;;
    -w|--wait)  WAIT="${2:?}"; shift 2 ;;
    -n|--lines) LINES="${2:?}"; shift 2 ;;
    -)          PROMPT="$(cat)"; shift ;;
    -h|--help)  sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    orchestrator|agent|codex)
                [[ -z "$ROLE" ]] || die "give exactly one target."
                ROLE="$1"; shift ;;
    *)          PROMPT="$1"; shift ;;
  esac
done

[[ -n "$ROLE" ]] || die "give a target (orchestrator | agent | codex)."
command -v tmux >/dev/null 2>&1 || die "tmux not found."
tmux has-session -t "=$SESSION" 2>/dev/null \
  || die "no session '$SESSION'. Run ./scripts/start-agents.sh first."

# Route on the @role that start-agents.sh set on each pane. The TUIs rewrite
# pane_title themselves, so the title cannot be trusted.
TARGET="$(tmux list-panes -t "=$SESSION" -F '#{pane_id} #{@role}' \
  | awk -v r="$ROLE" '$2 == r { print $1; exit }')"
[[ -n "$TARGET" ]] || die "no pane for '$ROLE'. Check with: tmux list-panes -a -F '#{pane_id} #{@role}'"

BUFFER="$SESSION-ask-$ROLE"

read_pane() {
  tmux capture-pane -p -J -t "$TARGET" -S "-${LINES}"
}

if [[ "$MODE" == "read" ]]; then
  read_pane
  exit 0
fi

[[ -n "$PROMPT" ]] || die "nothing to send. Give a string or -f FILE."

# Bracketed paste (-p) keeps a multi-line prompt as a single input event.
printf '%s' "$PROMPT" | tmux load-buffer -b "$BUFFER" -
tmux paste-buffer -b "$BUFFER" -t "$TARGET" -p -d
sleep 0.3
tmux send-keys -t "$TARGET" Enter

echo "sent to the $ROLE pane ($TARGET)." >&2

if [[ "$WAIT" != "0" ]]; then
  sleep "$WAIT"
  echo "--- $ROLE pane ---" >&2
  read_pane
fi
