# アルバム一覧の回帰テスト

macOS の Swift コンパイラで、ページ取得とジャンル集約を検証する。アプリのテストターゲットやサーバーは不要。

```sh
xcrun swiftc -parse-as-library -swift-version 6 \
  Musicfin/Core/Jellyfin/JellyfinModels.swift \
  Musicfin/Features/Library/AlbumCatalog.swift \
  Tests/AlbumCatalogTests.swift -o /tmp/musicfin-album-catalog-tests
/tmp/musicfin-album-catalog-tests
```

部分取得中のジャンル非公開、ページ位置、ジャンルごとのアルバム、空ライブラリ、取得完了後の重複要求防止、失敗後の再試行、更新失敗時の一覧保持を確認する。
