# frozen_string_literal: true
require "minitest/autorun"
require "json"
require "digest"
require_relative "../lib/merge_verifier"

class SharedBindingTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_public_wrapper_rejects_forged_output
    assert_includes File.read(File.join(ROOT, "fastlane/lib/merge_verifier.rb")), "SharedCI.merge_wrapper"
    assert_raises(MergeVerifier::Error) { MergeVerifier.write_output(File::NULL, sha: "bad", pr_number: 7) }
  end

  def test_lock_and_action_refs_bind_verified_runtime
    root = ENV.fetch("QTMLEAP_ACTIONS_ROOT")
    lock = JSON.parse(File.read(File.join(ROOT, ".github/shared-actions.lock.json")))
    files = Dir.glob("runtime/**/*", base: root).select { |path| File.file?(File.join(root, path)) }.sort
    assert_equal files, lock.fetch("runtime_files").keys.sort
    files.each { |path| assert_equal lock["runtime_files"][path], Digest::SHA256.file(File.join(root, path)).hexdigest }
    refs = Dir.glob(File.join(ROOT, ".github/workflows/*")).flat_map { |path| File.read(path).scan(%r{qtmleap/actions/actions/[a-z-]+@([0-9a-f]{40})}).flatten }
    refute_empty refs
    assert_equal [lock.fetch("revision")], refs.uniq
  end

  def test_cleanup_and_record_are_independent
    source = File.read(File.join(ROOT, ".github/workflows/deployment.yaml"))
    assert_match(/if: always\(\)\s+uses: qtmleap\/actions\/actions\/run-adapter@/, source)
    assert_match(/if: always\(\)\s+uses: qtmleap\/actions\/actions\/release-record@/, source)
    refute_includes source, "steps.deploy.outcome == 'success'"
  end
end
