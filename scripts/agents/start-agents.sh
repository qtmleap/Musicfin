#!/usr/bin/env bash
#
# Bring up orchestrator / implementer / reviewer side by side in one tmux session.
#
#   ┌──────────────┬──────────────┐
#   │              │ implementer  │  Claude Code, writes and verifies the code
#   │ orchestrator ├──────────────┤
#   │              │ reviewer     │  Claude Code, design and change review
#   └──────────────┴──────────────┘
#     Claude Code, receives every user request and runs the work
#
# The role names are also Claude Code cross-session addresses. All three seats
# reach Codex through their own project MCP process (.mcp.json); there is no
# interactive Codex pane and no tmux-based messaging.
#
# Musicfin is not a container: Xcode and the Simulator run on the macOS host.
# The seats still start with every approval check off (CLAUDE_ARGS, and
# CODEX_MCP_ARGS inside codex-mcp.mjs), but that is a deliberate default for
# this repository rather than something a sandbox makes safe. Set CLAUDE_ARGS
# explicitly to keep the checks.
#
# .vscode/tasks.json runs this on folderOpen, so a broken agent setup must still
# leave a usable terminal behind: every failure path falls back to a login shell.
#
# Environment:
#   AGENTS_TMUX         set to 0 to skip tmux and get a plain shell
#   AGENTS_SESSION      tmux session name                          (default: workspace directory name)
#   AGENT_TMUX_SESSION  accepted as a spelling of AGENTS_SESSION
#   CLAUDE_ARGS         claude args for all three panes             (default: --dangerously-skip-permissions)
#   ORCHESTRATOR_ARGS   extra args for orchestrator only            (default: none)
#   ORCHESTRATOR_MODEL  --model for orchestrator                    (default: claude-sonnet-5)
#   IMPLEMENTER_ARGS    extra args for implementer only             (default: none)
#   IMPLEMENTER_MODEL   --model for implementer                     (default: claude-opus-5)
#   REVIEWER_ARGS       extra args for reviewer only                (default: none)
#   REVIEWER_MODEL      --model for reviewer                        (default: claude-sonnet-5)
#
# CLAUDE_ARGS is read as ${VAR-default}, so exporting an empty string drops the
# default; only an unset variable gets it.
#
# Arguments:
#   --no-attach   build the session but do not attach (used by postAttachCommand)
#   --detached    the same thing, spelled the way this repository has spelled it
#   --open        switch the client if inside tmux, otherwise attach in Terminal.app
#   --restart     restart the agents in a session that already exists
#   -h, --help    print usage
#
# --restart replaces what runs inside each pane and leaves the session itself
# alone, so a terminal already attached to it keeps its place and simply shows
# the fresh agents. Killing the session instead would take that terminal down
# with it, which matters because the one VS Code opens on folderOpen is usually
# the only one. Needed whenever a model or a role prompt changes: both are read
# when claude starts, so a running seat keeps the old ones.

set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/agents/start-agents.sh [--detached | --open | --restart]

  --no-attach   build the session but do not attach
  --detached    the same thing
  --open        switch the client if inside tmux, otherwise open a terminal and attach
  --restart     restart the agents in a session that already exists
  -h, --help    print usage
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A shell alias here still exports AGENT_TMUX_SESSION, so take it as a spelling
# of AGENTS_SESSION; otherwise an alias would quietly point at a second session.
: "${AGENTS_SESSION:=${AGENT_TMUX_SESSION:-}}"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/agent-session.sh"
# AGENT_SESSION comes from the file sourced above, and is a different name from
# the AGENTS_SESSION that goes into it.
# shellcheck disable=SC2153
SESSION="$AGENT_SESSION"

CLAUDE_ARGS="${CLAUDE_ARGS---dangerously-skip-permissions}"
ORCHESTRATOR_ARGS="${ORCHESTRATOR_ARGS:-}"
ORCHESTRATOR_MODEL="${ORCHESTRATOR_MODEL:-claude-sonnet-5}"
IMPLEMENTER_ARGS="${IMPLEMENTER_ARGS:-}"
IMPLEMENTER_MODEL="${IMPLEMENTER_MODEL:-claude-opus-5}"
REVIEWER_ARGS="${REVIEWER_ARGS:-}"
REVIEWER_MODEL="${REVIEWER_MODEL:-claude-sonnet-5}"
ATTACH=1
OPEN=0
RESTART=0
for arg in "$@"; do
  case "$arg" in
    --no-attach|--detached) ATTACH=0 ;;
    --open) OPEN=1 ;;
    --restart) RESTART=1 ;;
    -h|--help) usage; exit 0 ;;
  esac
done

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# Drop to a plain shell. This is launched from a task and from terminal
# profiles, so exiting here would close the VS Code terminal outright.
fallback_shell() {
  { [ "$ATTACH" -eq 0 ] || [ "$OPEN" -eq 1 ]; } && exit 0
  exec "${SHELL:-/bin/zsh}" -l
}

# Attach without having a TTY of our own. Claude Code's Bash tool has none, so
# `tmux attach` from there would fail; hand the attach to Terminal.app instead.
# /session in .claude/skills/ depends on this path.
open_session() {
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "=$SESSION"
    return
  fi

  command -v osascript >/dev/null 2>&1 \
    || die "attaching from outside tmux needs macOS osascript."

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

[ "${AGENTS_TMUX:-1}" = "0" ] && fallback_shell

for cmd in tmux claude; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf '\033[33mwarning:\033[0m %s not found, starting a plain shell instead.\n' "$cmd" >&2
    fallback_shell
  fi
done

# Never nest tmux. The guard is about the attach, not about the work: only a
# bare invocation — the folderOpen task and the terminal profiles, which want a
# usable shell — is turned away from inside a session. --detached, --open and
# --restart all have to keep working there, because that is where a seat calls
# them from; without this they would exec a login shell and silently do nothing.
if [ -n "${TMUX:-}" ] && [ "$ATTACH" -eq 1 ] && [ "$OPEN" -eq 0 ] && [ "$RESTART" -eq 0 ]; then
  fallback_shell
fi

# ─── Commands for each pane ────────────────────────────────────────────
model_flag() { [ -n "${1:-}" ] && printf -- '--model %q ' "$1"; return 0; }
# Append <role>.md to the system prompt when it exists; warn and fall back to
# a bare claude when it does not.
prompt_flag() {
  local f="$SCRIPT_DIR/$1.md"
  if [ -r "$f" ]; then
    printf -- '--append-system-prompt "$(cat %q)" ' "$f"
  else
    printf '\033[33mwarning:\033[0m %s missing, starting %s as a bare claude.\n' "$f" "$1" >&2
  fi
  return 0
}

ORCH_CMD="claude --name orchestrator $(model_flag "${ORCHESTRATOR_MODEL:-}")$(prompt_flag orchestrator)${CLAUDE_ARGS} ${ORCHESTRATOR_ARGS}"
IMPL_CMD="claude --name implementer $(model_flag "${IMPLEMENTER_MODEL:-}")$(prompt_flag implementer)${CLAUDE_ARGS} ${IMPLEMENTER_ARGS}"
REVIEW_CMD="claude --name reviewer $(model_flag "${REVIEWER_MODEL:-}")$(prompt_flag reviewer)${CLAUDE_ARGS} ${REVIEWER_ARGS}"

pane_cmd() {
  case "$1" in
    orchestrator) printf '%s' "$ORCH_CMD" ;;
    implementer) printf '%s' "$IMPL_CMD" ;;
    reviewer) printf '%s' "$REVIEW_CMD" ;;
  esac
  return 0
}

# Keep the role in a pane option: Claude Code rewrites pane_title, so the title
# is not a reliable way to identify a seat. --restart pairs each pane with its
# command through this option, and cross-session messages use the same name.
pane_label() {
  printf '%s' "$1"
}

if tmux has-session -t "=$SESSION" 2>/dev/null; then
  if [ "$RESTART" -eq 1 ]; then
    # ─── Restart in place ────────────────────────────────────────────────
    # respawn-pane -k replaces the process and keeps the pane, so the layout,
    # the pane options and any attached client all survive. A pane carrying no
    # @role is someone's own shell — leave it running.
    while read -r pane role; do
      # Sessions created before the Codex MCP migration have an interactive
      # `codex` seat in the third pane. Convert that pane in place so the VS Code
      # Restart command applies the new topology without killing the tmux client.
      if [ "$role" = "codex" ]; then
        role=reviewer
        tmux set-option -p -t "$pane" @role "$role"
      fi
      # Normalize labels from older sessions too: the implementer used to be
      # displayed as `agent`, before all three panes became Claude seats.
      if [ "$role" = "agent" ]; then
        role=implementer
        tmux set-option -p -t "$pane" @role "$role"
      fi
      label="$(pane_label "$role")"
      tmux set-option -p -t "$pane" @label "$label"
      tmux select-pane -t "$pane" -T "$label"
      cmd="$(pane_cmd "$role")"
      [ -z "$cmd" ] && continue
      tmux respawn-pane -k -t "$pane" -c "$PWD"
      tmux send-keys -t "$pane" "$cmd" C-m
    done < <(tmux list-panes -t "=$SESSION" -F '#{pane_id} #{@role}')
  else
    echo "tmux session '$SESSION' is already running."
  fi
else
  # ─── Build the session ─────────────────────────────────────────────────
  tmux new-session -d -s "$SESSION" -c "$PWD" -n dev
  tmux split-window -h -t "$SESSION:dev" -c "$PWD"        # right column
  tmux split-window -v -t "$SESSION:dev.1" -c "$PWD"      # split the right column
  ROLES=(orchestrator implementer reviewer)

  i=0
  for role in "${ROLES[@]}"; do
    label="$(pane_label "$role")"
    tmux set-option -p -t "$SESSION:dev.$i" @role "$role"
    tmux set-option -p -t "$SESSION:dev.$i" @label "$label"
    tmux select-pane -t "$SESSION:dev.$i" -T "$label"
    i=$((i + 1))
  done

  tmux set-option -t "$SESSION" -g pane-border-status top
  tmux set-option -t "$SESSION" -g pane-border-format ' #{@label} '
  tmux set-option -t "$SESSION" -g history-limit 50000
  tmux set-option -t "$SESSION" -g mouse on

  tmux send-keys -t "$SESSION:dev.0" "$ORCH_CMD" C-m
  tmux send-keys -t "$SESSION:dev.1" "$IMPL_CMD" C-m
  tmux send-keys -t "$SESSION:dev.2" "$REVIEW_CMD" C-m

  tmux select-pane -t "$SESSION:dev.0"

  cat <<MSG
Started tmux session '$SESSION'.

  left        : orchestrator  $ORCH_CMD
  top right   : implementer   $IMPL_CMD
  bottom right: reviewer      $REVIEW_CMD

  move pane   Ctrl-b then an arrow key
  detach      Ctrl-b then d
  re-attach   tmux attach -t $SESSION
  restart     ./scripts/agents/start-agents.sh --restart
  kill        tmux kill-session -t $SESSION

  The seats message each other with Claude Code cross-session messaging, and
  each reaches Codex through the 'codex' MCP server (ask / review).
MSG
fi

# Install the VS Code extension that puts Agents: Start / Restart / Attach in
# the command palette. A devcontainer would do this from postAttachCommand; this
# repository has none — Xcode and the Simulator run on the host — so the
# folderOpen task that runs this script is the only startup hook there is.
#
# Best-effort on purpose: install.sh exits 0 when code or zip is missing and
# early when the installed version already matches. Nothing about the palette is
# allowed to take down the panes or the fallback shell, so it is detached from
# this shell entirely — backgrounded, output dropped, status ignored.
#
# Detached rather than merely guarded because the early exit is the fast path,
# not the only one: `code --install-extension` goes over the remote-CLI bridge
# and takes well over a minute on this host, which is what a version bump costs.
# Waiting for that would hold the attach below, and the terminal would sit empty
# while the seats were already running. It lands in time for the reload that a
# bumped extension needs anyway.
#
# The common failure is a stale VSCODE_IPC_HOOK_CLI — `code` is the remote CLI,
# so it only reaches a window when the environment came from one. A seat running
# this from its own pane simply installs nothing.
if [ -x "$SCRIPT_DIR/vscode/install.sh" ]; then
  "$SCRIPT_DIR/vscode/install.sh" >/dev/null 2>&1 &
fi

[ "$OPEN" -eq 1 ] && { open_session; exit 0; }
[ "$ATTACH" -eq 0 ] && exit 0
# Reached from inside tmux only by --restart, which has done its work already;
# attaching a session to itself is what the guard above exists to prevent.
[ -n "${TMUX:-}" ] && exit 0

exec tmux attach-session -t "=$SESSION"
