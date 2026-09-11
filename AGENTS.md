# Musicfin — エージェント共通ルール

Jellyfin サーバー上の音楽を再生する iPhone / iPad 専用アプリ。「Apple Music 風」を目指す。
SwiftUI、iOS 26 専用（Liquid Glass を分岐なしで使う）、Swift 6.2、
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。

## 決まりごと

- UI の仕様は `docs/ui-spec.md` が正。設計の再検討はせず、仕様通りに作る。
- `Musicfin/Core/` と `Musicfin/Player/` は指示がない限り変更しない。
- `#available` による分岐は書かない（iOS 26 のみ）。
- コメントは日本語。**何をしているか**ではなく**なぜそうしたか**を書く。既存ファイルと同じ密度で。
- ファイルスコープの `extension` は必要なら `nonisolated` を付ける。
- コミットメッセージは Conventional Commits（`.commitlintrc.yaml`）。本文は日本語。
- 整形は `.swift-format`（`swift-format lint --strict` が通ること）。

## ビルド・検証

```
xcodebuild -project Musicfin.xcodeproj -scheme Musicfin -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build build
```

- スクリーンショット: `./scripts/capture-screens.sh`（UI テストが主要画面を撮る）
- 単体検証: `Tests/README.md`

## 3 エージェント体制（`./scripts/start-agents.sh`）

| ペイン | 担当 | 役割 |
|---|---|---|
| `orchestrator` | Claude Code | 作業の分解・割り当て・レビュー・ユーザーへの報告 |
| `agent` | Claude Code | orchestrator から受けた実装タスクを完遂する |
| `codex` | Codex (gpt-6-astra) | 設計相談・レビュー・第二の実装者 |

ペイン間のやり取りは `./scripts/ask-agent.sh <orchestrator|agent|codex> "..."`。
応答は `--wait SEC` か `--read` で読み取る。

## Codex（このファイルを読んでいるあなた）へ

- 基本は **orchestrator からの相談・レビュー依頼に答える**。実装を頼まれたときだけコードを書く。
- 設計判断は「〜もあり得る」ではなく「こうする」と断定して返す。根拠は iOS 26 の API と `docs/ui-spec.md`。
- 実装したら必ず上のビルドコマンドを通し、変更ファイルと設計判断を 5 行以内で報告する。
