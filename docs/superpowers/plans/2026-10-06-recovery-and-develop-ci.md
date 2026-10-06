# 配信済み機能の復元と develop / master CI 配信 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Codex が復元・統合・検証・Git 操作を担当し、CI 担当は割り当てたファイルだけを編集する。

**Goal:** ビルド47の機能とアイコンを復元し、配信を develop または master への PR マージ時の CI に限定する。

**Architecture:** ビルド47の記録コミット `2e5d4c660c17b1000d7b27332a8da851aad11063` の確定した内容だけを復元する。iPad の標準 Section の 44 pt タップ領域を再適用する。GitHub の closed/merged PR イベントと Fastlane の実行条件を両方検証する。配信認証は develop と master ブランチだけに許可した testflight Environment に置き、古いタグのワークフローから利用できないようにする。

**Tech Stack:** SwiftUI / iOS 26 / Swift 6.2、GitHub Actions、Fastlane / Ruby。

**Spec:** `docs/ui-spec.md`、利用者の develop / master CI 配信指示。

## Global Constraints

- 別チェックアウトの未コミット変更を含めない。
- Core / Player は配信済み47と完全一致させ、新しい動作変更を行わない。
- ローカル beta、タグ、手動実行、未マージの close、develop / master 以外へのマージで配信しない。
- Codex だけが guarded Git と portable identity checker を使用してコミット・push する。
- アイコンは提供済みの47の画像をそのまま復元する。

## Review Focus

- ソースの取りこぼし: アプリと47の差分が RootView の44 pt変更だけになることを確認する。
- 古いマージの後発配信: 実行開始時とアップロード直前に live マージ先ブランチと SHA を照合する。
- 重複配信: CI再実行を拒否し、配信記録だけのマージを除外する。
- GitHubの署名認証: match に専用の読み取り専用 token または deploy key を使い、既存の証明書を変更しない。
- CIで使うコード: checkout をイベントのマージ SHA に固定し、全履歴を取得する。

### Task 1: 復元と iPad 操作

**Files:** `Musicfin/`、`MusicfinUITests/`、`Tests/`、`scripts/`、`docs/ui-spec.md`、`fastlane/screenshots/`。

- [x] 47の確定ソースを復元し、44 pt の変更と UI テストを再適用する。
- [x] ビルド、strict Swift lint、単体テストを実行する。
- [x] iPad の文字・余白・矢印で各区分を開閉し、画面を撮影する。
- [x] 配信済みソースとの差分とコンパイル済みアイコンを確認する。

### Task 2: CI と Fastlane の配信条件

**Files:** `.github/workflows/{deployment,integration}.yaml`、`fastlane/Fastfile`、`fastlane/Matchfile`、`fastlane/lib/deployment_policy.rb`、`fastlane/test/`、`fastlane/SETUP.md`、`AGENTS.md`。

- [x] 実際の lane がローカルから認証前に拒否されることをテストする。
- [x] develop / master の同一リポジトリの merged PR 初回だけを許可し、SHA・汚れ・記録のみ変更を検証する。
- [x] CI は固定 beta を実行し、成功記録を artifact として保存する。
- [x] Ruby テスト、workflow 検証、独立レビューを実行する。

### Task 3: 統合

- [ ] 必要な CI Secrets と match の読み取り専用キーを設定し、秘密値を出力しない。
- [x] 配信設定だけを master 宛ての PR で先に導入し、そこから develop を作る。
- [x] guarded Git で復元コードの develop 宛て PR を作成する。
- [ ] PR の CI とレビューを確認し、配信はマージイベントだけで行う。
- [ ] 実行結果と配信記録を確認する。

### 追加指示

- develop と master の両方で、実行元・PR マージ先・最新 SHA を照合する。昇格 PR も配信対象とする。
- GitHub Environment の許可は branch 型の develop / master のみにする。
- 利用者の指示で GitHub Actions の AI レビューワークフローを削除する。
