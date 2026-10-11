# Album Overlay Continuity Implementation Plan

> For agentic workers: implement the reviewed plan task by task, leave all changes uncommitted, and let Codex integrate, verify, commit and update PR #25.

**Goal:** Keep one pinned artwork image and shrink continuously from the finger-off pose to the tapped source artwork on regular-width iPad.

**Architecture:** Replace only Home's three iPad album entry paths with a detail-scoped overlay. An owned UIKit canvas hosts the existing AlbumDetail in its own SwiftUI NavigationStack, plus one persistent UIImageView hero. The canvas is split-level and offset to the stable sidebar edge, below the MiniPlayer; placing the nested stack inside the split detail caused its Back toolbar to disappear in native verification. Its full destination layout stays fixed; translation and uniform scale affect presentation only. Source capture, observable session selection, the canvas phase machine, and gesture arbitration are separate.

**Tech Stack:** iOS 26, Swift 6.2/MainActor, SwiftUI, UIKit, UIViewPropertyAnimator and UIPanGestureRecognizer.

**Spec:** docs/ui-spec.md section 6, superseded by the user's explicit requirement for two phases and no enlarged image handoff at finger-off.

## Global Constraints

- Do not modify Musicfin/Core or Musicfin/Player. Read the existing player touch-start/scroll arbitration pattern only.
- Keep iPhone/compact NavigationLinks and non-album Home links unchanged.
- Keep the split-level MiniPlayer above the detail overlay and preserve sidebar interaction.
- Japanese why-comments; no #available; strict swift-format.
- Source rectangles use window/global coordinates only at the boundary, converted to one fixed untransformed canvas space. Destination artwork uses a layout marker converted into the fixed content container.
- Retain one UIImage per session; source storage is weak, invalidatable and entry-specific. Never replace the active image at release.

## Review Focus and Resolved Findings

- AlbumDetail currently has no onward NavigationLink/destination routes. Its own NavigationStack preserves toolbar/sheets and explicit Back closes the overlay. No shared-route rewrite is necessary.
- ArtworkLoader is an actor with no synchronous cache accessor. Add an opt-in UIImage? callback to ArtworkView, report invalidation on changed/nil requests and success after stale-request guards. Unrelated callers default nil.
- Owned UIKit canvas avoids injecting a transition into SwiftUI's UINavigationController (the rejected probe installed after push). It owns its pan, animator and hero, not navigation-controller delegates.
- Latch touched List/top eligibility at touch-down. Downward vertical intent gets a one-way failure priority over that List pan only; up/horizontal and contacts starting below top stay scrolls. Do not swap List delegates.
- Phase machine: preparing/opening/presented/dragging/restoring/closing/removed. Session plus operation generations guard callbacks; completion removes selection only after the visual animation finishes.
- Retapping Home, sidebar selection, compact-shell change and destruction clear the session. Full-player/background interruption restores an active drag. Resize cancels or fades from the actual rendered pose rather than resetting a close.
- Source and destination missing/offscreen, and Reduce Motion, use explicit fade-from-current-pose fallback. Never silently count fallback as an artwork return.

## Task 1: Source, Session and Overlay

Files: HomeView.swift, RootView.swift, ArtworkView.swift, BrowseComponents.swift, AlbumDetailView.swift; small Home feature helpers for source/session/pose, canvas and gesture.

- [x] Preserve the failing native release recording as the baseline (giant crossfaded source snapshot after finger-off).
- [x] Add stable entry-specific source boxes with live frame/viewport, attachment and weak UIImage. Observed session state controls only selected artwork hiding.
- [x] Capture UIImage once on open. Add optional destination marker/hide hooks without removing its layout slot. Source/destination default behavior elsewhere is unchanged.
- [x] Root owns presentation selection, retains Home, disables its input/accessibility only when the overlay can render, and mounts the split-level detail-width overlay below MiniPlayer. Native Back/menu ownership verified.
- [x] Owned canvas retains one hero image for the entire session. Keep the content at its final bounds; stage invisible until measured destination art is ready. Hero follows/clips to List viewport when stationary.
- [x] Uniform pose maps destination art to source art: s = source.width / destination.width; t = source.center - s * destination.center. Apply the transform once. Bound drag scale so successful release never needs image enlargement.
- [x] Opening and successful closing use non-overshooting timing. Closing starts from current rendered pose, freezes a valid source endpoint, fades surrounding content, and shrinks the SAME hero. No timer-based unmount.
- [x] Explicit Back/accessibility escape use the same close. Cancel restores pose and input. Pan ownership is touch-sequence-latched, public and canvas-local.
- [x] Use exact session identity in completion/teardown. Destroying a controller stops its animator, removes only its recognizer/observers and invalidates diagnostic display links.

## Task 2: Proof and Integration

- [x] Validate actual native presentation frames with Tests/check-album-overlay-trace.py: pinned image, release-size ceiling, monotonic shrink, straight center path, exact source endpoint and cancelled drag. This directly tests the rendered animation instead of adding an unconnected interpolation helper.
- [x] Extend native UI tests for long held drag/release, substantial cancelled drag, scrolling from below top, playback/menu, repeated reopen, Back and sidebar interruption. Prefer clear overlay-close accessibility id.
- [x] Test-only CADisplayLink trace samples the actual hero presentation frame and image identity across finger-off. Assert no identity handoff, no width above released width, monotonic shrink and straight center path. Record fallback separately.
- [x] Record native iPad video; inspect held and release frames and final source landing. Compare MiniPlayer/sidebar positions.
- [x] Run required Debug build, strict formatting and appropriate tests; request independent actual-diff reviews. Resolve material findings before publication.
- [x] Clean only owned simulators/devices/windows and retain evidence. Verification is complete for the orchestrator to commit through guarded Git and update existing PR #25. Do not merge or deploy locally.

## Verification Evidence

- Final native run: ipad-album-overlay-final-pad, two UI tests passed with zero failures.
- Native trace validator: five artwork returns, one cancellation, 2,491 actual presentation-frame samples passed.
- Normal-size primary UI test covers fixed MiniPlayer/sidebar, Back, held drag, cancellation, release, reopen, pause/resume and full-player presentation.
- Large-text scroll test measures real Play-button movement, verifies same-contact return to top without dismissal, sidebar Home retap and all three album entry types.
- Independent Claude Sonnet and LocalGPT Pro implementation reviews found issues; all material findings were corrected and independently rechecked (Sonnet and Thinking: no outstanding P1/P2 in correction scope).
- Final disposable device 5F6F50B3-7E97-490C-9D70-70F14AA75862 shut down/deleted; no Simulator application was launched.
- Final Debug iPhone 17 Pro simulator build passed; strict formatting, diff whitespace check and complete unit suite passed.
