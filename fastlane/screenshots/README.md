# Release screenshots

Run `./scripts/capture-release-screens.sh` to capture six real app screens per
device in Japanese (`ja`) and English (`en-US`) using the
[official Jellyfin demo](https://demo.jellyfin.org/stable).

The script creates and removes its own clean simulators, signs in as the public
`demo` user with an empty password, and resolves the current `Nemesis` album and
`Jellyfin` track by name. It fails if the demo no longer has the expected content.
No private server credentials or synthetic library content are used.

iPad capture initializes the fresh Simulator's full-screen mode and verifies
portrait geometry. If the Songs request is cancelled during navigation, it
invokes the screen's existing Try Again button once and still requires the real
demo track. Search waits for the automatic results without sending Return to
the iPad field after it loses focus.

Images are native opaque PNGs: iPhone 6.9-inch portrait at 1320×2868, and iPad
13-inch portrait at 2048×2732. These sizes follow
[Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).
The status bar shows 09:41 and a full battery. The six screens are Home, Albums,
album detail, Now Playing, queue, and Search. The selected `Jellyfin` track has
no lyrics, so this release set does not include a lyrics viewer.
Thraximundar has no artwork registered on the demo and retains its native
placeholder in the album list and queue.

Set `MUSICFIN_BUILD_DEVELOPER_DIR` and `MUSICFIN_SIMCTL_DEVELOPER_DIR` when the
build tools and Simulator service come from different Xcode installations.
`MUSICFIN_PYTHON` selects Python with Pillow. For this workspace:

```sh
MUSICFIN_BUILD_DEVELOPER_DIR=/Applications/Xcode-26.0.1.app/Contents/Developer \
MUSICFIN_SIMCTL_DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer \
./scripts/capture-release-screens.sh
```

Optional `--locale ja|en-US`, `--device iPhone|iPad`, `--home-only`, and
`--output DIR` select a subset or an alternative destination. Home is captured
after scrolling the real Top Picks carousel to Nemesis, which has artwork;
Search uses `i` to show the demo's matching music. A run validates its selected set
before publishing; logs and staging remain in the temporary directory printed
at the end. `manifest.json` records provenance, dimensions, and checksums without
authentication tokens. Each image records its source commit, whether the app
working tree was dirty, and a hash of the actual app source tree. Subset runs
preserve the untouched images and their manifest entries. Existing comparison
captures remain independent.

PNG files are intentionally ignored by Git. Capturing does not upload images to
App Store Connect.
