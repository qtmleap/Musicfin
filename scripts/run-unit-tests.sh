#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
# 並行実行で生成物が衝突しないよう、実行ごとに専用の一時ディレクトリを使う。
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/musicfin-unit-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 \
  Musicfin/Core/Jellyfin/JellyfinModels.swift \
  Musicfin/Features/Library/AlbumCatalog.swift \
  Tests/AlbumCatalogTests.swift -o "$test_dir/album-catalog-tests"
"$test_dir/album-catalog-tests"

xcrun swiftc -parse-as-library -swift-version 6 \
  Musicfin/Core/Jellyfin/JellyfinModels.swift \
  Musicfin/Features/Library/MediaPageCollection.swift \
  Musicfin/Features/Library/LibraryFeed.swift \
  Tests/MediaPageCollectionTests.swift -o "$test_dir/media-page-tests"
"$test_dir/media-page-tests"

xcrun swiftc -parse-as-library -swift-version 6 \
  Musicfin/Core/Jellyfin/JellyfinModels.swift \
  Musicfin/Features/Library/MediaPageCollection.swift \
  Musicfin/Features/Home/RadioMixCatalog.swift \
  Tests/RadioMixCatalogTests.swift -o "$test_dir/radio-mix-tests"
"$test_dir/radio-mix-tests"

cp Tests/PlaybackQueueOrderTests.swift "$test_dir/main.swift"
xcrun swiftc -swift-version 6 \
  Musicfin/Player/PlaybackQueueOrder.swift \
  "$test_dir/main.swift" -o "$test_dir/playback-queue-order-tests"
"$test_dir/playback-queue-order-tests"

# キャッシュの永続化と要求制御は UIKit から切り離し、アプリと同じ既定の隔離でも検証する。
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
  Musicfin/DesignSystem/ArtworkRequest.swift \
  Musicfin/DesignSystem/ArtworkDataStore.swift \
  Musicfin/DesignSystem/ArtworkImageDecoder.swift \
  Tests/ArtworkImageDecoderTests.swift \
  Tests/ArtworkRequestLifecycleTests.swift \
  Tests/ArtworkDataStoreTests.swift -o "$test_dir/artwork-data-store-tests"
"$test_dir/artwork-data-store-tests"

xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
  Musicfin/Features/NowPlaying/LyricsPreludeMotion.swift \
  Tests/LyricsPreludeMotionTests.swift -o "$test_dir/lyrics-prelude-motion-tests"
"$test_dir/lyrics-prelude-motion-tests"

xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
  Musicfin/Features/NowPlaying/LyricsRollMotion.swift \
  Tests/LyricsRollMotionTests.swift -o "$test_dir/lyrics-roll-motion-tests"
"$test_dir/lyrics-roll-motion-tests"

xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
  Musicfin/Features/NowPlaying/LyricsControlsScroll.swift \
  Tests/LyricsControlsScrollTests.swift -o "$test_dir/lyrics-controls-scroll-tests"
"$test_dir/lyrics-controls-scroll-tests"

xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
  Musicfin/Features/NowPlaying/LyricsFollowPolicy.swift \
  Tests/LyricsFollowPolicyTests.swift -o "$test_dir/lyrics-follow-policy-tests"
"$test_dir/lyrics-follow-policy-tests"

bash scripts/run-localization-tests.sh
