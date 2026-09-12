---
name: session
description: Start Musicfin's orchestrator, implementer (Claude Code) and Codex as three tmux panes.
user-invocable: true
allowed-tools: Bash
---

# Musicfin agent session

Start the tmux session and attach to it:

1. Confirm `scripts/start-agents.sh` exists in the current directory. If it does
   not, tell the user to run `/session` from the Musicfin repository root and
   stop.
2. Run `./scripts/start-agents.sh --open` with Bash.
   - The session name comes from the repository directory name (override with
     `AGENT_TMUX_SESSION`).
   - Inside tmux, this switches the current client to that session.
   - Outside tmux, it opens Terminal.app on macOS and attaches there.
   - An existing session is attached to rather than rebuilt.
3. If the command fails, report the cause briefly and stop. Do not reimplement
   the launch or the attach with other commands.

What it starts:

- left: `orchestrator` — the Claude Code session that runs the show
- top right: `agent` — the Claude Code session that implements
- bottom right: `codex` — Codex, for design questions and review
