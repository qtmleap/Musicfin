# frozen_string_literal: true
require "json"
require "open3"

# 配信ビルドの dSYM を Crashlytics へ同期アップロードする。TestFlight へ出す前に
# 「このアーカイブのシンボルである」ことを確認し、1 つでも食い違えば止める。
module CrashlyticsSymbols
  APP_ID = "1:909394898262:ios:35edd6f995150146af7af7"
  BUNDLE_ID = "jp.qleap.musicfin"
  DEFAULT_TOOLS = { plutil: "plutil", dwarfdump: "dwarfdump" }.freeze

  class Error < StandardError; end

  module_function

  # fastlane の sh/アクションは失敗を握りつぶしうるので、argv を直接実行して終了コードを見る。
  def run(*argv)
    out, status = Open3.capture2e(*argv)
    [out, status]
  rescue SystemCallError => e
    raise Error, "#{File.basename(argv.first)} を起動できない: #{e.class}"
  end

  def upload!(archive:, uploader:, scheme:, tools: {})
    tools = DEFAULT_TOOLS.merge(tools)
    raise Error, "XCODEBUILD_ARCHIVE が未設定" if archive.to_s.empty?
    raise Error, "アーカイブが無い: #{archive}" unless File.directory?(archive)
    unless File.file?(uploader) && File.executable?(uploader)
      raise Error, "upload-symbols が実行できない（SPM チェックアウト未取得？）: #{uploader}"
    end

    app = File.join(archive, "Products/Applications/#{scheme}.app")
    plist = File.join(app, "GoogleService-Info.plist")
    app_info = File.join(app, "Info.plist")
    dsyms = File.join(archive, "dSYMs")
    dsym_binary = File.join(dsyms, "#{scheme}.app.dSYM/Contents/Resources/DWARF/#{scheme}")
    binary = File.join(app, scheme)
    [plist, app_info, dsym_binary, binary].each do |path|
      raise Error, "アーカイブに必要なファイルが無い: #{path}" unless File.file?(path)
    end

    config = read_plist(plist, tools[:plutil])
    verify_config!(config)
    info = read_plist(app_info, tools[:plutil])
    raise Error, "アーカイブの Bundle ID が一致しない" unless info["CFBundleIdentifier"] == BUNDLE_ID
    raise Error, "配信の計測が無効なアーカイブ" unless info["MusicfinTelemetryEnabled"] == "YES"
    verify_uuids!(binary, dsym_binary, tools[:dwarfdump])

    # 資格情報はアップローダに渡さない。API キーは plist 経由で渡り、ログには出さない。
    out, status = run(uploader, "-gsp", plist, "-p", "ios", dsyms)
    unless status.success?
      raise Error, "upload-symbols が失敗した (status #{status.exitstatus.inspect}):\n#{redact(out, config).lines.last(20).join}"
    end
    "Crashlytics へ dSYM をアップロードした (#{BUNDLE_ID})"
  end

  def read_plist(path, plutil)
    out, status = run(plutil, "-convert", "json", "-o", "-", "--", path)
    raise Error, "GoogleService-Info.plist を読めない" unless status.success?
    JSON.parse(out)
  rescue JSON::ParserError
    raise Error, "GoogleService-Info.plist を解析できない"
  end

  def verify_config!(config)
    { "GOOGLE_APP_ID" => APP_ID, "BUNDLE_ID" => BUNDLE_ID }.each do |key, expected|
      actual = config[key]
      raise Error, "#{key} が期待値と違う（期待: #{expected} / 実際: #{actual.inspect}）" unless actual == expected
    end
  end

  def uuids(path, dwarfdump)
    out, status = run(dwarfdump, "--uuid", path)
    raise Error, "dwarfdump --uuid に失敗: #{path}" unless status.success?
    out.scan(/^UUID: (\S+) \((\S+)\)/).map { |uuid, arch| "#{uuid.upcase} #{arch}" }.sort
  end

  def verify_uuids!(binary, dsym_binary, dwarfdump)
    expected = uuids(binary, dwarfdump)
    actual = uuids(dsym_binary, dwarfdump)
    raise Error, "バイナリの UUID を取得できない" if expected.empty?
    return if expected == actual
    raise Error, "UUID が dSYM と一致しない（binary: #{expected.join(', ')} / dSYM: #{actual.join(', ')}）"
  end

  def redact(text, config)
    secret = config["API_KEY"].to_s
    secret.empty? ? text : text.gsub(secret, "[REDACTED]")
  end
end
