# frozen_string_literal: true

# 配信しない (TestFlight へ上げない) ドキュメントだけの完全一覧。ここが唯一のネイティブな一覧で、
# merge_verifier の record_only_paths と deployment.yaml の push paths-ignore は同じ内容にする
# (fastlane/test/non_release_documents_test.rb が突き合わせる)。
# glob・ディレクトリ・拡張子単位の除外は置かない。ここに無いパスはすべて配信対象として扱う。
module NonReleaseDocuments
  PATHS = %w[
    .agents/skills/ios-development/SKILL.md
    .agents/skills/ios-development/references/app-review-followup.md
    .agents/skills/ios-development/references/release-policy.md
    .agents/skills/ios-development/references/testing-policy.md
    AGENTS.md
    CLAUDE.md
    docs/development/ci-change-scope.md
    docs/development/ios-development-routine.md
    docs/impl-brief.md
    docs/superpowers/plans/2026-09-10-remaining-ui.md
    docs/superpowers/plans/2026-10-06-recovery-and-develop-ci.md
    docs/superpowers/plans/2026-10-11-album-overlay-continuity.md
    docs/ui-consult-prompt.md
    docs/ui-spec.md
  ].freeze

  # CI の Git は diff.renames が既定で有効になりうる。ソースからドキュメントへ同一内容で移した
  # 差分が「ドキュメントの追加」1 件に見えると、削除されたソースが消えて配信を誤って止める。
  # 変更パスを調べる `git diff --name-only` だけに --no-renames を足し、他の呼び出しと
  # 元の例外はそのまま通す。注入された偽の Git (prepend されない) には影響しない。
  module RenameSafeDiff
    def call(*args)
      if args.first == "diff" && args.include?("--name-only") && !args.include?("--no-renames")
        args = [args.first, "--no-renames", *args.drop(1)]
      end
      super(*args)
    end
  end
end
