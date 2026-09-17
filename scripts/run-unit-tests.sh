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

cp Tests/PlaybackQueueOrderTests.swift "$test_dir/main.swift"
xcrun swiftc -swift-version 6 \
  Musicfin/Player/PlaybackQueueOrder.swift \
  "$test_dir/main.swift" -o "$test_dir/playback-queue-order-tests"
"$test_dir/playback-queue-order-tests"
