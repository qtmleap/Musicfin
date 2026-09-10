# 実装タスク: Musicfin の残り UI

`docs/ui-spec.md` を読み、**そこに書かれた仕様の通りに**実装してください。
設計の再検討・仕様の変更はしないこと。判断が必要なのは実装の質だけです。

## 実装する画面
1. `Musicfin/Features/Root/RootView.swift` — 3 タブ + `tabViewBottomAccessory`
2. `Musicfin/Features/Library/HomeView.swift` — 仕様 2 の 4 セクション
3. `Musicfin/Features/Library/LibraryView.swift` — 5 分類の入れ子一覧（ジャンル集約を含む）
4. `Musicfin/Features/NowPlaying/MiniPlayerView.swift` — `.inline` / `.expanded` の出し分け
5. `Musicfin/Features/NowPlaying/NowPlayingView.swift` — 仕様 4・5（高さ配分と 3 状態切替）
6. `Musicfin/MusicfinApp.swift` — `RootView` を使うよう差し替え

## 使える既存の部品（**変更禁止**）
- `PlaybackEngine`: queue, currentIndex, currentItem, isPlaying, isBuffering, currentTime,
  duration, progress, isShuffled, repeatMode(.off/.all/.one → systemImage), upcoming, hasNext,
  play(items:startingAt:), play(at:), toggle(), playNext(), playPrevious(), seek(to:),
  toggleShuffle(), cycleRepeatMode(), appendToQueue(_:), playNext(_:)
- `LibraryStore`: homeState/albumsState(.idle/.loading/.loaded/.failed(String)),
  recentlyAdded, frequentlyPlayed, favoriteTracks, albums, artists, playlists,
  loadHome(force:), loadAlbums(force:), loadMoreAlbumsIfNeeded(currentItem:),
  loadArtists(), loadPlaylists(), tracks(for:), albums(byArtist:), toggleFavorite(_:)
- `AuthStore`: isSignedIn, client, signOut()
- 部品: `ArtworkView(item:size:cornerRadius:)`, `TrackRow(track:showsArtwork:isPlaying:)`,
  `AlbumCard(item:size:showsSubtitle:)`, `ArtistRow(artist:)`, `CarouselSection(title:destination:content:)`
- 既存画面: `AlbumDetailView(album:)`, `ArtistDetailView(artist:)`, `SearchView()`,
  `LyricsView(track:)`, `QueueView()` — これらを組み込むこと
- `TimeInterval.timeLabel` / `.remainingLabel`, `MediaItem.albumSubtitle`

環境オブジェクトは `@Environment(AuthStore.self)` 等で取得する（すべて `@Observable`）。

## 制約
- `Musicfin/Core/` と `Musicfin/Player/` は**一切変更しない**
- iOS 26 専用。`#available` による分岐は書かない
- Swift 6.2、`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。
  ファイルスコープの `extension` は必要なら `nonisolated` を付ける
- コメントは日本語。既存ファイルと同じ密度・文体（**何をしているか**ではなく**なぜそうしたか**を書く）
- 既存のコメントスタイルに合わせること。過剰なコメントは書かない

## 完了条件
以下が成功すること。エラーが出たら自分で直しきること。

```
xcodebuild -project Musicfin.xcodeproj -scheme Musicfin -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build build
```

警告も可能な限り消すこと。ビルドが通ったら、実装した各画面の設計判断を 5 行以内で述べて終了。
