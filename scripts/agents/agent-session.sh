#!/usr/bin/env bash
#
# Single source of the tmux session name used by start-agents.sh and any shell
# that needs to locate the shared agent session.
#
# The default is the workspace directory name, so no project name is baked into
# the scripts and this directory can be copied to another repository as is. A git
# worktree has its own directory name, so it gets its own session rather than
# colliding with the one the main checkout is using.
#
#   AGENT_SESSION       tmux session name
#   AGENTS_SESSION      overrides it
#   AGENT_TMUX_SESSION  the older spelling, folded in by start-agents.sh

# tmux treats '.' and ':' as target separators, so collapse everything that is
# not alphanumeric, '_' or '-' into '-'.
AGENT_SESSION="$(
  printf '%s' "${AGENTS_SESSION:-$(basename "$PWD")}" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9_-' '-'
)"
AGENT_SESSION="${AGENT_SESSION:-agents}"
