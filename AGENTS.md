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

## Release only through develop or master merge CI

When a request is finished — built, linted, verified — commit the work and open
a PR targeting `develop`, or `master` when requested. **Only the Deployment
GitHub Actions workflow after that PR is merged may upload a build to TestFlight.**
Never deploy from a local checkout, a tag, a direct push, or a manual workflow dispatch. The App Store
`release` lane is disabled. Keep the repository default branch unchanged.

Store all ASC and MATCH deployment credentials only in the protected GitHub
Environment `testflight`, with deployment branches restricted to the branches
`develop` and `master`. Do not keep repository-level copies: historical tagged
workflows must not inherit deployment credentials.

Use a merge commit or squash merge for release PRs. CI checks out the exact
merge SHA and checks the live PR base branch tip before building and uploading;
obsolete merges and dirty checkouts fail. Rebase merges with a record-only
final commit are conservatively rejected. CI reruns cannot upload again.
Do not merge another PR, including a record-only PR, while Deployment CI is
building or uploading. Wait for the entire deployment run to finish.

CI preserves `fastlane/testflight/last_shipped.json` as a
`testflight-shipped-<merge SHA>` artifact after a successful upload. The
orchestrator verifies that artifact and commits the record through a separate
record-only PR as `chore(fastlane): record build N as shipped to TestFlight`.
Record-only PRs do not trigger deployment, and CI never creates Git commits.
If an upload or artifact outcome is uncertain, inspect the run and App Store
Connect before creating a fresh recovery PR; never retry a local deployment.
If the upload succeeded but artifact preservation failed, reconstruct the
record from the verified run merge SHA and the actual App Store Connect build
and upload time, then submit a record-only PR without rerunning deployment.

**The orchestrator owns commits and PRs, not `implementer` or `reviewer`** —
workers leave changes uncommitted so that one seat owns the history.

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
