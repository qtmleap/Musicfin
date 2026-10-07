# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/ci_cleanup"

class CiCleanupTest < Minitest::Test
  def test_failed_restoration_retains_journal_for_independent_retry
    original = ENV.to_h
    implementation = CiCleanup.method(:command)
    Dir.mktmpdir do |home|
      ENV["HOME"] = home
      ENV["GITHUB_RUN_ID"] = "123"
      fail_restore = false
      calls = []
      CiCleanup.define_singleton_method(:command) do |*argv|
        calls << argv
        raise "fixture restoration failed" if fail_restore && argv.include?("-s")
        argv[1] == "default-keychain" ? '"/fixture/login.keychain-db"' : '"/fixture/login.keychain-db" "two words.keychain-db"'
      end
      CiCleanup.prepare!
      state = JSON.parse(File.read(CiCleanup.journal))
      assert_equal ["/fixture/login.keychain-db", "two words.keychain-db"], state["list"]
      assert_equal 0o600, File.stat(CiCleanup.journal).mode & 0o777
      fail_restore = true
      assert_raises(RuntimeError) { CiCleanup.recover! }
      assert File.exist?(CiCleanup.journal), "failed recovery must not discard state"
      fail_restore = false
      CiCleanup.recover!
      refute File.exist?(CiCleanup.journal)
      assert calls.any? { |args| args == ["security", "list-keychains", "-d", "user", "-s", "/fixture/login.keychain-db", "two words.keychain-db"] }
    end
  ensure
    CiCleanup.define_singleton_method(:command, implementation)
    ENV.replace(original)
  end
  def test_empty_search_list_is_restored_before_deletion
    original = ENV.to_h
    Dir.mktmpdir do |home|
      ENV["HOME"] = home
      ENV["GITHUB_RUN_ID"] = "456"
      calls = []
      CiCleanup.stub(:command, ->(*argv) { calls << argv; "" }) do
        CiCleanup.prepare!
        keychain = File.join(home, "Library/Keychains/musicfin-ci-456.keychain-db")
        FileUtils.mkdir_p(File.dirname(keychain))
        File.write(keychain, "fixture")
        CiCleanup.recover!
        restore = calls.index(["security", "list-keychains", "-d", "user", "-s"])
        deletion = calls.index(["security", "delete-keychain", keychain])
        refute_nil restore
        refute_nil deletion
        assert_operator restore, :<, deletion
      end
    end
  ensure
    ENV.replace(original)
  end

  def test_symlink_journal_is_rejected_without_commands
    original = ENV.to_h
    Dir.mktmpdir do |home|
      ENV["HOME"] = home
      CiCleanup.journal_directory!
      target = File.join(home, "target")
      File.write(target, "untouched")
      File.symlink(target, CiCleanup.journal)
      CiCleanup.stub(:command, ->(*_) { flunk "unsafe journal ran recovery" }) do
        assert_raises(RuntimeError) { CiCleanup.recover! }
      end
      assert_equal "untouched", File.read(target)
    end
  ensure
    ENV.replace(original)
  end

end
