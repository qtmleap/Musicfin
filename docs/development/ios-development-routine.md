# Shared iOS development routine in Musicfin

Adopted from [qtmleap/devcontainers](https://github.com/qtmleap/devcontainers/tree/0ffa75dec05570817c499452ac6faf1c3413006c)
at `0ffa75dec05570817c499452ac6faf1c3413006c`. The four files under `.agents/skills/ios-development/` are copied
without modification. Future refreshes compare that directory and merge the
marked `development-orchestration` block in root `AGENTS.md`, preserving local
rules. Adoption does not install tools or grant additional release authority.

## Repository scope

Native iPhone/iPad SwiftUI app. Keep `docs/ui-spec.md` authoritative and preserve the existing Core/Player ownership and iOS-version rules in `AGENTS.md`.

Read `.github/workflows/integration.yaml` and `Tests/README.md`; reuse the repository unit-test, capture and mock-diff workflows when affected. Required native build/UI evidence remains separate from documentation checks.

Only the existing `.github/workflows/deployment.yaml` merge route may upload TestFlight builds. Preserve its deployment serialization, exact-merge checks and separate shipped-record PR procedure.

## Applying the routine

- Root `AGENTS.md` holds the common parallel-work, review/session, Tailscale,
  UI and ASC policy. `CLAUDE.md` imports it for Claude Code.
- Use [the native skill](../../.agents/skills/ios-development/SKILL.md) for its
  applicable native app scope; read its testing and release references when
  relevant. The repository scope above takes precedence over generic app
  examples. Apply checks to supported targets rather than inventing platforms.
- Keep the repository's existing mandatory gates and release route. The common
  internal-feature/external-RC timing defaults apply only where no stricter
  project policy exists.
- For documentation-only PRs, verify content, links, copied-file hashes and
  mandatory Git hooks. Native app binaries and simulator state are unchanged;
  this is no claim of native test success or release readiness. Let required CI
  run on the PR source rather than duplicating its unchanged full suites locally.
- Check release workflow triggers before merging: existing merge automation may
  distribute a build even for a documentation PR. This rollout opens a PR;
  merge timing remains with the repository's release process.
- An App Review monitor is established by a future authorized submission flow
  according to the copied follow-up reference. No monitor is installed merely
  by adopting these instructions.

## UI screenshots and OS coverage

Apply the [visual testing policy](../../.agents/skills/ios-development/references/testing-policy.md)
for retained captures, matching references and baseline review on every selected
UI-test run.

This app is iOS 26 only: use compatible 26.x native baselines and mark 18 not applicable. Existing design-mock comparison remains distinct from OS-matched regression comparison.

## Remote screenshot sharing

When UI screenshots are captured remotely, follow the
[sharing workflow](../../.agents/skills/ios-development/references/testing-policy.md#sharing-remote-screenshots).
Return actual tailnet image/viewer links, including baseline/current/diff when
comparing, and report client reachability and viewer expiry separately from
visual-test outcomes. Existing platform, release and access-control rules remain
in force. This adoption starts no viewer and claims no live URL.
