#!/usr/bin/env bash
#
# Bring up orchestrator / agent / codex side by side in one tmux session.
#
#   ┌──────────────┬──────────────┐
#   │              │ agent        │  Claude Code (implementer, .claude/agents/implementer.md)
#   │ orchestrator ├──────────────┤
#   │              │ codex        │  Codex gpt-6-astra (reads AGENTS.md)
#   └──────────────┴──────────────┘
#     Claude Code (runs the show, .claude/agents/orchestrator.md)
#
# An existing session with the same name is attached to rather than rebuilt.
#
# Environment:
#   AGENT_TMUX_SESSION      session name                      (default: repository directory name)
#   ORCHESTRATOR_MODEL      claude model for orchestrator     (default: whatever the agent definition says)
#   AGENT_MODEL             claude model for agent            (default: whatever the agent definition says)
#   CODEX_MODEL             model passed to codex             (default: gpt-6-astra)
#   CODEX_ARGS              arguments passed to codex         (default: --dangerously-bypass-approvals-and-sandbox)
#   CLAUDE_ARGS             arguments passed to both claudes  (default: --dangerously-skip-permissions)
#
# Options:
#   --detached              build the session but do not attach
#   --open                  switch the client if inside tmux, otherwise open a terminal and attach
#   -h, --help              print usage
#
# Approval checks are off by default for both claude and codex so nothing stops
# to ask. To keep them, pass an empty value (CLAUDE_ARGS= / CODEX_ARGS=): these
# are read as ${VAR-default}, so only an unset variable gets the default.

set -euo pipefail

MODE="attach"

usage() {
  cat <<'USAGE'
Usage: ./scripts/start-agents.sh [--detached | --open]

  --detached    build the session but do not attach
  --open        switch the client if inside tmux, otherwise open a terminal and attach
  -h, --help    print usage
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --detached) MODE="detached"; shift ;;
    --open)     MODE="open"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          printf '\033[31merror:\033[0m unknown option: %s\n' "$1" >&2
                usage >&2
                exit 1 ;;
  esac
done

. "$(dirname "${BASH_SOURCE[0]}")/lib/agent-session.sh"
SESSION="$AGENT_SESSION"
ROOT="$AGENT_ROOT"
CODEX_MODEL="${CODEX_MODEL:-gpt-6-astra}"
CODEX_ARGS="${CODEX_ARGS---dangerously-bypass-approvals-and-sandbox}"
CLAUDE_ARGS="${CLAUDE_ARGS---dangerously-skip-permissions}"

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

open_session() {
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "=$SESSION"
    return
  fi

  command -v osascript >/dev/null 2>&1 \
    || die "attaching from outside tmux needs macOS osascript."

  # There is no interactive TTY here, so hand the attach to Terminal.app.
  local command escaped
  printf -v command 'tmux attach-session -t %q' "=$SESSION"
  escaped="${command//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  osascript \
    -e 'tell application "Terminal"' \
    -e 'activate' \
    -e "do script \"$escaped\"" \
    -e 'end tell' >/dev/null
}

command -v tmux   >/dev/null 2>&1 || die "tmux not found. Install it with 'brew install tmux'."
command -v claude >/dev/null 2>&1 || die "claude not found."
command -v codex  >/dev/null 2>&1 || die "codex not found."
[[ -f "$ROOT/.claude/agents/orchestrator.md" && -f "$ROOT/.claude/agents/implementer.md" ]] \
  || die "no agent definitions under .claude/agents/."

if tmux has-session -t "=$SESSION" 2>/dev/null; then
  echo "tmux session '$SESSION' is already running."
  case "$MODE" in
    detached) exit 0 ;;
    open)     open_session; exit 0 ;;
    attach)   exec tmux attach-session -t "=$SESSION" ;;
  esac
fi

# ─── Commands for each pane ───────────────────────────────────────────
model_flag() { [[ -n "${1:-}" ]] && printf -- '--model %q ' "$1"; return 0; }
ORCH_CMD="claude --agent orchestrator --name orchestrator $(model_flag "${ORCHESTRATOR_MODEL:-}")${CLAUDE_ARGS}"
AGENT_CMD="claude --agent implementer --name agent $(model_flag "${AGENT_MODEL:-}")${CLAUDE_ARGS}"
CODEX_CMD="codex --model ${CODEX_MODEL} ${CODEX_ARGS}"

# ─── Build the session ────────────────────────────────────────────────
tmux new-session -d -s "$SESSION" -c "$ROOT" -n dev
tmux split-window -h -t "$SESSION:dev" -c "$ROOT"      # right column
tmux split-window -v -t "$SESSION:dev.1" -c "$ROOT"    # split the right column

# Keep the role in a pane option: the TUIs rewrite pane_title, so the title is
# not a reliable way to find a pane. ask-agent.sh routes on this @role.
i=0
for role in orchestrator agent codex; do
  tmux set-option -p -t "$SESSION:dev.$i" @role "$role"
  tmux select-pane -t "$SESSION:dev.$i" -T "$role"
  i=$((i + 1))
done

tmux set-option -t "$SESSION" -g pane-border-status top
tmux set-option -t "$SESSION" -g pane-border-format ' #{@role} '
# Deep scrollback so ask-agent.sh can read back a long answer.
tmux set-option -t "$SESSION" -g history-limit 50000
tmux set-option -t "$SESSION" -g mouse on

tmux send-keys -t "$SESSION:dev.0" "$ORCH_CMD" C-m
tmux send-keys -t "$SESSION:dev.1" "$AGENT_CMD" C-m
tmux send-keys -t "$SESSION:dev.2" "$CODEX_CMD" C-m

tmux select-pane -t "$SESSION:dev.0"

cat <<MSG
Started tmux session '$SESSION'.

  left        : orchestrator  $ORCH_CMD
  top right   : agent         $AGENT_CMD
  bottom right: codex         $CODEX_CMD

  move pane   Ctrl-b then an arrow key
  detach      Ctrl-b then d
  re-attach   tmux attach -t $SESSION
  kill        tmux kill-session -t $SESSION

  Send a prompt to a pane:
    ./scripts/ask-agent.sh agent "implement this"
    ./scripts/ask-agent.sh codex -f docs/ui-consult-prompt.md -w 120
    ./scripts/ask-agent.sh agent --read
MSG

case "$MODE" in
  detached) exit 0 ;;
  open)     open_session; exit 0 ;;
  attach)   exec tmux attach-session -t "=$SESSION" ;;
esac
