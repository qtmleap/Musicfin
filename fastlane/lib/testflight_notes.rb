# TestFlight の「What to Test」を Git のコミット件名から組み立てる。
# fastlane に依存しない純 Ruby にしてあるのは、`ruby fastlane/lib/testflight_notes.rb` で
# 配信せずにプレビューでき、`fastlane/test/` から単体で検証できるようにするため。

require "open3"
require "json"
require "fileutils"
require "tempfile"
require "time"

module TestflightNotes
  # App Store Connect の whatsNew は 4,000 文字が上限だが、マルチバイトを考慮して
  # バイト数で見ておけば確実に収まる。
  MAX_BYTES = 4000
  MAX_ITEMS = 10

  HEADING = "今回の確認項目"
  FOOTER = "あわせて、ログイン・検索・再生・キュー（次に再生）の通常操作に問題がないかご確認ください。"
  FALLBACK = "#{HEADING}\n\n#{FOOTER}"

  # テスターに影響がある変更を優先する。これらが 1 件も無いときだけ他の type を使う。
  PRIMARY_TYPES = %w[feat fix perf ui].freeze
  LABELS = {
    "feat" => "新機能",
    "fix" => "修正",
    "perf" => "性能改善",
    "ui" => "UI",
    "refactor" => "内部改善",
    "build" => "ビルド",
    "ci" => "CI",
    "docs" => "ドキュメント",
    "test" => "テスト",
    "chore" => "その他",
    "format" => "整形",
    "revert" => "取り消し"
  }.freeze

  # Conventional Commits: `type(scope)!: 件名 (#123)`
  SUBJECT_PATTERN = /\A(?<type>[a-z]+)(?:\([^)]*\))?!?:\s*(?<desc>.+)\z/
  PR_SUFFIX = /\s*\(#\d+\)\s*\z/

  module_function

  # 既存の CLI は件名だけ使い、fastlane は git_history の説明も表示する。
  def git_subjects(repo_root)
    git_history(repo_root).first
  end

  # 配信済みの記録を優先し、初回だけ直近20件に限定して古い変更の再掲を避ける。
  # git が失敗した場合も選んだ基準を返し、本文は従来のフォールバックに任せる。
  def git_history(repo_root)
    sha = last_shipped_sha(repo_root)
    if sha
      revisions = ["#{sha}..HEAD"]
      basis = "last_shipped.json: #{sha}..HEAD"
    else
      tag, status = Open3.capture2e(
        "git", "-C", repo_root, "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*"
      )
      if status.success?
        revisions = ["#{tag.strip}..HEAD"]
        basis = "タグ: #{tag.strip}..HEAD"
      else
        revisions = ["--max-count=20", "HEAD"]
        basis = "記録・タグなし: HEADから直近20件まで"
      end
    end

    log, status = Open3.capture2e(
      "git", "-C", repo_root, "log", "--no-merges", "--format=%s", *revisions, "--"
    )
    return [nil, "#{basis}（Git履歴の取得に失敗）"] unless status.success?

    [log.lines.map(&:strip).reject(&:empty?), basis]
  rescue SystemCallError
    [nil, "#{basis || '基準の選択に失敗'}（Gitを実行できない）"]
  end

  def record_path(repo_root)
    File.join(repo_root, "fastlane", "testflight", "last_shipped.json")
  end

  def last_shipped_sha(repo_root)
    record = JSON.parse(File.read(record_path(repo_root)))
    return nil unless record.is_a?(Hash)

    sha = record["sha"]
    # 任意の revision 式を記録と見なさず、別の checkout に移された記録も実在確認する。
    return nil unless sha.is_a?(String) && sha.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/i)

    _, status = Open3.capture2e("git", "-C", repo_root, "cat-file", "-e", "#{sha}^{commit}")
    status.success? ? sha : nil
  rescue JSON::ParserError, SystemCallError
    nil
  end

  def head_sha(repo_root)
    sha, status = Open3.capture2e("git", "-C", repo_root, "rev-parse", "--verify", "HEAD^{commit}")
    raise "配信するコミットのSHAを取得できません" unless status.success?

    sha.strip
  end

  # アップロード中に HEAD が進んでも、呼び出し元で取得した配信対象の SHA を記録する。
  # 同じディレクトリ内で置換し、中断で既存の記録が途中までの JSON になるのを避ける。
  def record_shipped(repo_root, sha:, build:, version:)
    path = record_path(repo_root)
    FileUtils.mkdir_p(File.dirname(path))
    record = { sha: sha, build: build, version: version, uploaded_at: Time.now.utc.iso8601 }
    Tempfile.create([".last_shipped-", ".json"], File.dirname(path)) do |file|
      file.write(JSON.pretty_generate(record) + "\n")
      file.close
      File.rename(file.path, path)
    end
  end

  # -z ならファイル名の改行は件数に混ざらない。改名・コピーの追加パスは1件にまとめる。
  def dirty_count(repo_root)
    output, status = Open3.capture2e(
      "git", "-C", repo_root, "status", "--porcelain", "-z", "--untracked-files=all"
    )
    return nil unless status.success?

    entries = output.split("\0")
    count = 0
    index = 0
    while index < entries.length
      index += entries[index][0, 2].match?(/[RC]/) ? 2 : 1
      count += 1
    end
    count
  rescue SystemCallError
    nil
  end

  # 件名の配列から本文を組み立てる。件名が無ければ通常操作の確認依頼だけを返す。
  def build(subjects)
    items = select_items(Array(subjects))
    return FALLBACK if items.empty?

    fit(items)
  end

  def select_items(subjects)
    parsed = subjects.filter_map { |s| parse(s) }
    primary = parsed.select { |p| PRIMARY_TYPES.include?(p[:type]) }
    chosen = primary.empty? ? parsed : primary

    seen = {}
    chosen.each_with_object([]) do |p, acc|
      key = p[:desc]
      next if seen[key]
      seen[key] = true
      acc << "- #{LABELS.fetch(p[:type], p[:type])}: #{p[:desc]}"
      break acc if acc.size >= MAX_ITEMS
    end
  end

  def parse(subject)
    match = SUBJECT_PATTERN.match(subject.to_s.strip)
    return nil unless match

    desc = match[:desc].sub(PR_SUFFIX, "").strip
    return nil if desc.empty?

    { type: match[:type], desc: desc }
  end

  # 4,000 バイトを超えるなら古い項目から落とし、それでも入らない 1 項目は文字単位で切る。
  # bytesize で判定し、切るときは each_char で進めるのでマルチバイト文字の途中で壊れない。
  def fit(items)
    items = items.dup
    until items.empty?
      text = compose(items)
      return text if text.bytesize <= MAX_BYTES

      if items.size == 1
        budget = MAX_BYTES - compose([""]).bytesize - "…".bytesize
        return compose([truncate(items[0], budget) + "…"])
      end
      items.pop
    end
    FALLBACK
  end

  def compose(items)
    "#{HEADING}\n\n#{items.join("\n")}\n\n#{FOOTER}"
  end

  def truncate(text, budget)
    out = +""
    text.each_char do |ch|
      break if out.bytesize + ch.bytesize > budget
      out << ch
    end
    out
  end
end

if __FILE__ == $PROGRAM_NAME
  root = File.expand_path("../..", __dir__)
  puts TestflightNotes.build(TestflightNotes.git_subjects(root))
end
