あなたは iOS の UI/UX 設計レビュアーです。実装は不要で、設計判断だけを返してください。

# プロジェクト
`Musicfin` — Jellyfin サーバー上の音楽を再生する iPhone / iPad 専用アプリ。「Apple Music 風」を目指す。
SwiftUI、デプロイメントターゲット **iOS 26 のみ**（Liquid Glass を分岐なしでそのまま使う）。
リポジトリはこのディレクトリ（/Users/devonly/Developer/Musicfin）。自由に読んで構いません。
Core / Player / 一部の画面は実装済みでビルドが通っています（Swift 約 2,600 行）。

## 実装済み（変更しない前提）
- `Player/PlaybackEngine.swift`（@MainActor @Observable）
  公開: queue, currentIndex, isPlaying, isBuffering, currentTime, duration, progress,
  isShuffled, repeatMode(off/all/one), upcoming, hasNext
  操作: play(items:startingAt:), play(at:), toggle(), playNext(), playPrevious(), seek(to:),
        toggleShuffle(), cycleRepeatMode(), appendToQueue(_:), playNext(_:)
  AVQueuePlayer で 1 曲先読みのギャップレス再生。ロック画面連携・割り込み復帰も実装済み。
- `Core/Auth/AuthStore.swift`: state, client, signIn, Quick Connect
- `Features/Library/LibraryStore.swift`: recentlyAdded, frequentlyPlayed, favoriteTracks,
  albums(ページング対応), artists, playlists, tracks(for:), albums(byArtist:), toggleFavorite(_:)
- `MediaItem`: id, name, type(.audio/.musicAlbum/.musicArtist/.playlist), album, albumId,
  albumArtist, artistItems, indexNumber, parentIndexNumber, productionYear, runTimeTicks,
  childCount, genres, isFavorite, displayName, displayArtist, duration, albumSubtitle
- 時間同期歌詞を取得可能（`LyricLine`: startSeconds, text）
- 既存の共通部品: `ArtworkView(item:size:cornerRadius:)`, `TrackRow`, `AlbumCard`,
  `ArtistRow`, `CarouselSection`
- 実装済みの画面: `LoginView`, `AlbumDetailView`, `ArtistDetailView`, `SearchView`

## これから書く画面（あなたの決定を反映する対象）
`RootView`（タブ構成）, `HomeView`, `LibraryView`, `MiniPlayerView`, `NowPlayingView`,
`LyricsView`, `QueueView`

## 使える iOS 26 API（SDK の .swiftinterface で存在確認済み）
`TabView` + `Tab(role: .search)` / `.tabViewBottomAccessory {}` /
`@Environment(\.tabViewBottomAccessoryPlacement)` → `.inline` or `.expanded` /
`.tabBarMinimizeBehavior(.onScrollDown)` / `.glassEffect(_:in:)` / `.glassEffectID(_:in:)` /
`.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)` /
`.matchedTransitionSource(id:in:)` + `.navigationTransition(.zoom(sourceID:in:))` /
`.scrollEdgeEffectStyle(_:for:)` / `.backgroundExtensionEffect()`

# 答えてほしいこと
以下の 6 点を **具体的かつ断定的に** 決めてください。「〜もあり得る」ではなく「こうする」と書く。
各項目 200〜400 字程度。日本語で。コードは断片的な擬似コードに留める。

1. **タブ構成**: 何タブにして、それぞれ何を置くか。Apple Music は「ホーム/新着/ラジオ/ライブラリ/検索」
   だが、Jellyfin には新着もラジオも無い。Jellyfin の実態（アルバム/アーティスト/プレイリスト/
   お気に入り/ジャンル）に合う最適なタブ構成は？ライブラリ内の切り替えは segmented control か
   サイドバーか、それとも一覧の入れ子か。

2. **ホーム（最初のタブ）の縦構成**: どのセクションを上から順にどう並べるか。使えるデータは
   「最近追加されたアルバム」「よく再生するアルバム」「お気に入りの曲」「全アルバム」のみ。
   各セクションでカルーセルとグリッドのどちらを使うか、カードの pt サイズも指定して。

3. **ミニプレイヤー**: `tabViewBottomAccessory` は `.inline`（タブバー最小化時・横に細い）と
   `.expanded`（通常時）の 2 状態を取る。それぞれで何を表示し、何を出さないか。
   タップ / 横スワイプ / 上スワイプのジェスチャ割り当ても決めて。

4. **フルプレイヤー**: ミニプレイヤーから何で開くか（sheet / fullScreenCover / zoom transition）。
   縦の構成（アートワーク、タイトル行、シークバー、トランスポート、音量、下部ボタン群）の順序と
   画面高に対するおおよその比率。再生 / 一時停止でアートワークを拡縮させるか。

5. **歌詞とキューへの導線**: フルプレイヤーから歌詞・次に再生をどう出すか。Apple Music は下部
   ボタンで画面内を切り替えるが、それを踏襲すべきか、シートにすべきか。同時に 2 つ出せるべきか。

6. **iPad レイアウト**: `NavigationSplitView` にするか iPhone と同じ `TabView` のままにするか。
   ミニプレイヤーの置き場所は iPad ではどこか。

# 制約
- ファイルを書き換えないこと。読み取りのみ。
- 一般論ではなく、この 6 点への決定だけを書く。前置き・要約・締めの挨拶は不要。
