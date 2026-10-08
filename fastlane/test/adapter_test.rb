# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "rbconfig"

class AdapterTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SHA = "a" * 40

  def exercise(mode)
    Dir.mktmpdir do |temp|
      root = File.join(temp, "source")
      FileUtils.mkdir_p(File.join(root, "fastlane/lib"))
      FileUtils.mkdir_p(File.join(root, ".github"))
      FileUtils.cp(File.join(ROOT, "fastlane/adapter.rb"), File.join(root, "fastlane/adapter.rb"))
      %w[ci_cleanup deployment_policy shared_actions_loader testflight_notes].each do |name|
        FileUtils.cp(File.join(ROOT, "fastlane/lib/#{name}.rb"), File.join(root, "fastlane/lib/#{name}.rb"))
      end
      FileUtils.cp(File.join(ROOT, ".github/shared-actions.lock.json"), File.join(root, ".github/shared-actions.lock.json"))
      FileUtils.cp_r(File.join(ROOT, ".github/workflows"), File.join(root, ".github/workflows"))
      tracked = File.join(root, "fastlane/testflight/last_shipped.json")
      FileUtils.mkdir_p(File.dirname(tracked))
      File.write(tracked, JSON.generate({ sha: SHA, build: 1 }))
      home = File.join(temp, "home")
      output = File.join(temp, "output")
      FileUtils.mkdir_p([home, output])
      program = <<~RUBY
        require "open3"
        module Open3
          def self.capture2e(_env, *argv, **options)
            raise "Unexpected native command" unless argv.first == "security" && options[:unsetenv_others]
            value = argv[1] == "default-keychain" ? '"/fixture/login.keychain-db"' : '"/fixture/login.keychain-db"'
            [value, Struct.new(:success?).new(true)]
          end
        end
        def system(*argv, **options)
          raise "Unexpected lane command" unless argv == ["bundle", "exec", "fastlane", "beta"]
          if ENV.fetch("FIXTURE_MODE") != "stale"
            sha = ENV.fetch("FIXTURE_MODE") == "wrong-sha" ? "b" * 40 : ENV.fetch("MUSICFIN_VERIFIED_SHA")
            path = File.join(options.fetch(:chdir), DeploymentPolicy::SHIPPED_RECORD)
            File.write(path, JSON.generate({ sha: sha, build: 2 }))
          end
          ENV.fetch("FIXTURE_MODE") != "upload-then-failure"
        end
        ARGV.replace(["release-ios"])
        load #{File.join(root, "fastlane/adapter.rb").inspect}
      RUBY
      env = { "HOME" => home, "RUNNER_TEMP" => output, "GITHUB_RUN_ID" => "123", "GITHUB_ACTIONS" => nil,
              "MUSICFIN_VERIFIED_SHA" => SHA, "FIXTURE_MODE" => mode }
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-e", program)
      receipt = File.join(output, "musicfin-shipped-123/last_shipped.json")
      yield status, stdout + stderr, File.file?(receipt) ? JSON.parse(File.read(receipt)) : nil
    end
  end

  def test_fresh_process_loads_release_policy_and_preserves_new_receipt
    exercise("fresh") do |status, output, receipt|
      assert status.success?, output
      assert_equal SHA, receipt.fetch("sha")
      assert_equal 2, receipt.fetch("build")
    end
  end

  def test_stale_tracked_receipt_is_not_copied
    exercise("stale") do |status, output, receipt|
      assert status.success?, output
      assert_nil receipt
    end
  end

  def test_new_receipt_must_match_verified_source_sha
    exercise("wrong-sha") do |status, output, receipt|
      assert status.success?, output
      assert_nil receipt
    end
  end

  def test_uploaded_receipt_survives_a_later_lane_failure
    exercise("upload-then-failure") do |status, output, receipt|
      refute status.success?
      assert_includes output, "Fastlane failed"
      assert_equal SHA, receipt.fetch("sha")
      assert_equal 2, receipt.fetch("build")
    end
  end
end
