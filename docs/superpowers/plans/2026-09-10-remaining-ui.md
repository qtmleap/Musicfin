# Musicfin remaining UI implementation plan

**Goal:** `docs/ui-spec.md` に従って残りの UI を実装する。
**Architecture:** 各タブに独立した NavigationStack を持たせ、RootView がプレイヤーの sheet を管理する。既存 Store・Core・Player・共通部品は変更しない。全件取得の終端を判定する AlbumCatalog を Features/Library に置く。
**Tech Stack:** Swift 6.2、SwiftUI、iOS 26、MainActor、MediaPlayer、AVKit。
**Spec:** `docs/ui-spec.md`

- [x] AlbumCatalog のページ取得・失敗・ジャンル公開タイミングを先に検証し、実装する。
- [x] LibraryView に5分類と一覧の遷移を実装する。全件取得後にジャンルを公開する。
- [x] HomeView に指定寸法の4セクションと幅に応じたグリッドを実装する。
- [x] MiniPlayerView と NowPlayingView に表示状態・操作・高さ配分・システム音量を実装する。
- [x] RootView と MusicfinApp に3タブ、共通アクセサリ、sheetを接続する。
- [x] LyricsView の追従処理だけ、ユーザーの例外許可に従って変更する。
- [x] 指定の xcodebuild を実行し、エラー修正後に差分と変更禁止範囲を確認する。

## 検証

AlbumCatalog は一部取得中のジャンル非公開、複数ページ完了、失敗後の再試行を独立した Swift の検証で確認する。画面を写し取るだけのテストは追加せず、指定シミュレーター向けのビルドと仕様照合で接続を確認する。

## 結果

- 指定の iPhone 17 Pro 向け Debug ビルド成功（終了コード0）。
- `Tests/AlbumCatalogTests.swift` 成功。実行方法は `Tests/README.md`。
- 追加した Swift ファイルの swift-format strict lint 成功。
- 読み取りレビューで見つかったスクロール、ページ取得、VoiceOverシーク、更新失敗後の復旧を修正した。
- MPVolumeView のルートボタン非表示APIの非推奨警告と、未使用の AppIntents メタデータ抽出警告は残る。
- 実機の音量・出力先変更、サーバー接続を伴う操作の実行検証はしていない。
- 作業中に別途追加された Core・Player などの整形差分は保持し、このUI実装では変更していない。
