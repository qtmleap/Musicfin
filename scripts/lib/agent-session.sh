#!/usr/bin/env bash
#
# Single source of the tmux session name, so start-agents.sh and ask-agent.sh can
# never disagree about which session they are talking to.
#
# The name comes from the repository directory, so no project name is baked into
# the scripts and this scripts/ directory can be copied to another repository as
# is. A git worktree has its own directory name, so it gets its own session.
#
#   AGENT_ROOT     repository root
#   AGENT_SESSION  tmux session name (override with AGENT_TMUX_SESSION)

# This file is sourced, so both variables are read by the caller, not here.
# shellcheck disable=SC2034
AGENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# tmux treats '.' and ':' as target separators, so collapse everything that is
# not alphanumeric, '_' or '-' into '-'.
# shellcheck disable=SC2034
AGENT_SESSION="${AGENT_TMUX_SESSION:-$(
  printf '%s' "$(basename "$AGENT_ROOT")" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9_-' '-'
)}"
