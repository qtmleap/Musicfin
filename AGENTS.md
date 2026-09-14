# Musicfin — shared agent rules

An iPhone / iPad-only app that plays the music on a Jellyfin server, aiming to
feel like Apple Music. SwiftUI, iOS 26 only (Liquid Glass, used without version
branches), Swift 6.2, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

## Rules

- `docs/ui-spec.md` is the authority on UI. Build what it says; do not revisit
  the design.
- Do not change `Musicfin/Core/` or `Musicfin/Player/` unless told to.
- Never branch on `#available` (iOS 26 only).
- **Comments are written in Japanese.** Say **why**, not **what**, and match the
  density of the surrounding file.
- Add `nonisolated` to file-scope `extension`s where it is needed.
- Commit messages follow Conventional Commits (`.commitlintrc.yaml`) and are
  **written entirely in English**, subject and body alike. This is the one place
  where the language rule differs from code comments, which stay Japanese.
- Formatting is `.swift-format` — `swift-format lint --strict` must pass.

## Build and verify

```
xcodebuild -project Musicfin.xcodeproj -scheme Musicfin -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build build
```

- Screenshots: `./scripts/capture-screens.sh` (UI tests capture the main screens)
- Viewer to compare what was captured: `./scripts/launch.py`
  (http://127.0.0.1:18755/, stays in the foreground; Ctrl+C to stop)
- Unit tests: `./scripts/run-unit-tests.sh` (details in `Tests/README.md`)
- CI locally: `./scripts/act.sh` (`--host <job>` for the macOS jobs)

## Ship every finished piece of work

When a request is finished — built, linted, verified — **commit it and ship it to
TestFlight**. Do not leave finished work sitting in the working tree waiting to
be asked about.

1. Commit the work itself, one Conventional Commit per coherent change.
2. `bundle exec fastlane beta` — this is what "release" means here. Tagging `v*`
   fires the **App Store** lane instead, so never push a tag as part of this.
3. Commit the build record fastlane writes to
   `fastlane/testflight/last_shipped.json`, as
   `chore(fastlane): record build N as shipped to TestFlight`.

**The orchestrator does this, not `implementer` or `reviewer`** — they are told
to leave the tree uncommitted so that one seat owns the history. It waits until
every piece of the request is in and verified, so a request is shipped once, not
once per sub-task.

## The three agents (`./scripts/agents/start-agents.sh`)

| Pane | Who | Role |
|---|---|---|
| `orchestrator` | Claude Code | Splits the work, assigns it, verifies it, commits and ships it, reports to the user |
| `implementer` | Claude Code | Carries the implementation tasks it gets from the orchestrator through to done |
| `reviewer` | Claude Code | Read-only design and change review, second opinions |

The seats talk to each other with Claude Code cross-session messaging
(`ListAgents`, then `SendMessage` to `orchestrator` / `implementer` /
`reviewer`), and every seat reaches Codex through the `codex` MCP server
(`ask` for a question, `review` for a diff). Role prompts live in
`scripts/agents/*.md`; a model or prompt change needs
`./scripts/agents/start-agents.sh --restart` to take effect.

In VS Code the session is also reachable from the command palette as **Agents:
Start / Restart / Attach**. Those entries come from the small local extension in
`scripts/agents/vscode/`, which exists only because VS Code will not put a task
in the palette by itself (microsoft/vscode#101761); each command runs the
`.vscode/tasks.json` task of the same name. `start-agents.sh` installs it in the
background on every launch, since there is no devcontainer here to do it on
attach. After changing `extension.js`, bump `version` in its `package.json` — the
installer skips a version it already has — and run **Developer: Reload Window**
once, because VS Code only reads the extensions directory when a window opens.

## For Codex (you, reading this file)

You arrive through the `codex` MCP server, with access to this repository but no
context from the conversation that called you, so the prompt has to name what
matters and this file is your standing brief.

- Your job is mostly to **answer design questions and review requests**. Write
  code only when implementation is what was asked for.
- Give design answers as decisions ("do this"), not as options ("you could also
  …"). Ground them in the iOS 26 APIs and `docs/ui-spec.md`.
- After implementing, always run the build command above, then report the
  changed files and your design decisions in five lines or fewer.
