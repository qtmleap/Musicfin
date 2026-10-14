# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
require_relative "../lib/crashlytics_symbols"

class CrashlyticsSymbolsTest < Minitest::Test
  APP_ID = "1:909394898262:ios:35edd6f995150146af7af7"
  API_KEY = "AIzaSyFixtureSecretKeyValue0000000000000"
  UUID_A = "11111111-AAAA-BBBB-CCCC-000000000001"
  UUID_B = "22222222-AAAA-BBBB-CCCC-000000000002"

  # Linux 上では Mac 専用ツールが無いので、実ファイルとして置いた偽の実行ファイルを
  # 本物と同じ argv 経路で起動する。ネットワークには一切出ない。
  Fixture = Struct.new(:root, :archive, :tools, :uploader, :log)

  def with_fixture(binary_uuid: UUID_A, dsym_uuid: UUID_A, app_id: APP_ID, bundle_id: "jp.qleap.musicfin",
                   plist: true, dsym: true, uploader_status: 0, uploader_output: "uploaded",
                   archive_bundle_id: "jp.qleap.musicfin", telemetry: "YES")
    Dir.mktmpdir do |root|
      archive = File.join(root, "Musicfin.xcarchive")
      app = File.join(archive, "Products/Applications/Musicfin.app")
      FileUtils.mkdir_p(app)
      File.write(File.join(app, "Musicfin"), "binary")
      File.write(File.join(app, "Info.plist"), JSON.generate(
        "CFBundleIdentifier" => archive_bundle_id, "MusicfinTelemetryEnabled" => telemetry))
      if plist
        File.write(File.join(app, "GoogleService-Info.plist"),
                   JSON.generate("GOOGLE_APP_ID" => app_id, "BUNDLE_ID" => bundle_id, "API_KEY" => API_KEY))
      end
      if dsym
        dwarf = File.join(archive, "dSYMs/Musicfin.app.dSYM/Contents/Resources/DWARF")
        FileUtils.mkdir_p(dwarf)
        File.write(File.join(dwarf, "Musicfin"), "dsym")
      end

      bin = File.join(root, "bin")
      FileUtils.mkdir_p(bin)
      log = File.join(root, "uploader.log")
      plutil = script(bin, "plutil", %(for last; do :; done\ncat "$last"\n))
      dwarfdump = script(bin, "dwarfdump", <<~SH)
        case "$2" in
          *.dSYM/*) echo "UUID: #{dsym_uuid} (arm64) $2" ;;
          *) echo "UUID: #{binary_uuid} (arm64) $2" ;;
        esac
      SH
      uploader = script(bin, "upload-symbols", <<~SH)
        printf '%s\\n' "$@" > "#{log}"
        echo "#{uploader_output}"
        echo "key=#{API_KEY}" >&2
        exit #{uploader_status}
      SH
      yield Fixture.new(root, archive, { plutil: plutil, dwarfdump: dwarfdump }, uploader, log)
    end
  end

  def script(dir, name, body)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\n#{body}")
    File.chmod(0o755, path)
    path
  end

  def upload(fx)
    CrashlyticsSymbols.upload!(archive: fx.archive, uploader: fx.uploader, scheme: "Musicfin", tools: fx.tools)
  end

  def test_matching_archive_runs_uploader_with_plist_and_dsym_directory
    with_fixture do |fx|
      upload(fx)
      assert File.exist?(fx.log), "matching archives must invoke the uploader"
      app_plist = File.join(fx.archive, "Products/Applications/Musicfin.app/GoogleService-Info.plist")
      assert_equal ["-gsp", app_plist, "-p", "ios", File.join(fx.archive, "dSYMs")],
                   File.read(fx.log).lines.map(&:chomp)
    end
  end

  def test_uploader_is_not_run_when_dsym_uuid_differs_from_binary
    with_fixture(dsym_uuid: UUID_B) do |fx|
      error = assert_raises(CrashlyticsSymbols::Error) { upload(fx) }
      assert_match(/UUID/, error.message)
      refute File.exist?(fx.log), "uploader must not run on mismatched symbols"
    end
  end

  def test_missing_dsym_fails_before_upload
    with_fixture(dsym: false) do |fx|
      assert_raises(CrashlyticsSymbols::Error) { upload(fx) }
      refute File.exist?(fx.log)
    end
  end

  def test_missing_google_service_plist_fails_before_upload
    with_fixture(plist: false) do |fx|
      assert_raises(CrashlyticsSymbols::Error) { upload(fx) }
      refute File.exist?(fx.log)
    end
  end

  def test_wrong_firebase_app_id_fails_before_upload
    with_fixture(app_id: "1:1:ios:other") do |fx|
      error = assert_raises(CrashlyticsSymbols::Error) { upload(fx) }
      assert_match(/GOOGLE_APP_ID/, error.message)
      refute File.exist?(fx.log)
    end
  end

  def test_wrong_bundle_id_fails_before_upload
    with_fixture(bundle_id: "com.example.other") do |fx|
      error = assert_raises(CrashlyticsSymbols::Error) { upload(fx) }
      assert_match(/BUNDLE_ID/, error.message)
      refute File.exist?(fx.log)
    end
  end

  def test_missing_archive_path_fails
    with_fixture do |fx|
      assert_raises(CrashlyticsSymbols::Error) do
        CrashlyticsSymbols.upload!(archive: nil, uploader: fx.uploader, scheme: "Musicfin", tools: fx.tools)
      end
      assert_raises(CrashlyticsSymbols::Error) do
        CrashlyticsSymbols.upload!(archive: File.join(fx.root, "absent.xcarchive"), uploader: fx.uploader,
                                   scheme: "Musicfin", tools: fx.tools)
      end
    end
  end

  def test_wrong_archived_app_bundle_id_fails_before_upload
    with_fixture(archive_bundle_id: "com.example.other") do |fx|
      assert_raises(CrashlyticsSymbols::Error) { upload(fx) }
      refute File.exist?(fx.log)
    end
  end

  def test_non_distribution_archive_fails_before_upload
    with_fixture(telemetry: "NO") do |fx|
      assert_raises(CrashlyticsSymbols::Error) { upload(fx) }
      refute File.exist?(fx.log)
    end
  end

  def test_missing_uploader_fails
    with_fixture do |fx|
      assert_raises(CrashlyticsSymbols::Error) do
        CrashlyticsSymbols.upload!(archive: fx.archive, uploader: File.join(fx.root, "nope"),
                                   scheme: "Musicfin", tools: fx.tools)
      end
    end
  end

  def test_uploader_failure_propagates_without_leaking_api_key
    with_fixture(uploader_status: 3, uploader_output: "network down") do |fx|
      error = assert_raises(CrashlyticsSymbols::Error) { upload(fx) }
      assert_match(/status 3/, error.message)
      assert_match(/network down/, error.message)
      refute_includes error.message, API_KEY
    end
  end
end
