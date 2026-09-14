---
name: session
description: Start Musicfin's orchestrator, implementer and reviewer as three Claude Code tmux panes.
user-invocable: true
allowed-tools: Bash
---

# Musicfin agent session

Start the tmux session and attach to it:

1. Confirm `scripts/agents/start-agents.sh` exists in the current directory. If
   it does not, tell the user to run `/session` from the Musicfin repository
   root and stop.
2. Run `./scripts/agents/start-agents.sh --open` with Bash.
   - The session name comes from the repository directory name (override with
     `AGENTS_SESSION`, or the older `AGENT_TMUX_SESSION`).
   - Inside tmux, this switches the current client to that session.
   - Outside tmux, it opens Terminal.app on macOS and attaches there.
   - An existing session is attached to rather than rebuilt.
3. If the command fails, report the cause briefly and stop. Do not reimplement
   the launch or the attach with other commands.

What it starts — three Claude Code seats, each reaching Codex through the
`codex` MCP server rather than through a pane of its own:

- left: `orchestrator` — runs the show, and owns the commits and the release
- top right: `implementer` — implements what the orchestrator delegates
- bottom right: `reviewer` — read-only design and change review

A model or role-prompt change only takes effect when a seat restarts:
`./scripts/agents/start-agents.sh --restart`.
