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
- Workspace the viewer reads: `docs/mock-diff/`, rebuilt from `docs/app/` by
  `scripts/build-mock-diff-workspace.py` at the end of every capture
- Viewer: the `mock-diff` service in `.devcontainer/compose.yaml` inside the
  container, `bun run dev` in the viewer checkout on the Mac
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

## Agents

One seat, `claude --agent devflow:orchestrator`, started from the command
palette entry the `devflow` plugin installs. It does no editing itself: it
splits the work and runs `devflow:implementer`, `devflow:reviewer`,
`devflow:tester` and `devflow:advisor` through the `Agent` tool, picking the
model per call rather than from the environment.

Codex is reachable from every seat as `mcp__plugin_devflow_codex__ask` for a
question and `mcp__plugin_devflow_codex__review` for a diff.

The plugins themselves are enabled in `.claude/settings.json`, which is
committed, so the Mac and the container get the same set.

## For Codex (you, reading this file)

You arrive through the `codex` MCP server the `devflow` plugin provides, with
access to this repository but no context from the conversation that called you,
so the prompt has to name what matters and this file is your standing brief.

- Your job is mostly to **answer design questions and review requests**. Write
  code only when implementation is what was asked for.
- Give design answers as decisions ("do this"), not as options ("you could also
  …"). Ground them in the iOS 26 APIs and `docs/ui-spec.md`.
- After implementing, always run the build command above, then report the
  changed files and your design decisions in five lines or fewer.
