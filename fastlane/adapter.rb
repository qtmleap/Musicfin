# frozen_string_literal: true
root = File.expand_path("..", __dir__)
require_relative "lib/shared_actions_loader"
SharedActionsLoader.load!(app_root: root)
operation = ARGV.shift
abort "Unexpected arguments" unless ARGV.empty?
case operation
when "authorize"
  abort "Authorization failed" unless system("bundle", "exec", "ruby", "fastlane/lib/deployment_policy.rb", chdir: root)
when "release-ios"
  require_relative "lib/deployment_policy"
  require_relative "lib/ci_cleanup"
  CiCleanup.prepare!
  path = File.join(root, DeploymentPolicy::SHIPPED_RECORD)
  previous_record = File.file?(path) ? File.binread(path) : nil
  success = system("bundle", "exec", "fastlane", "beta", chdir: root)
  if File.file?(path) && !File.symlink?(path) && File.binread(path) != previous_record
    record = JSON.parse(File.read(path))
    if record["sha"] == ENV.fetch("MUSICFIN_VERIFIED_SHA")
      directory = File.join(ENV.fetch("RUNNER_TEMP"), "musicfin-shipped-#{ENV.fetch('GITHUB_RUN_ID')}")
      FileUtils.mkdir_p(directory, mode: 0o700)
      File.write(File.join(directory, "last_shipped.json"), JSON.generate(record) + "\n", mode: "w", perm: 0o600)
    end
  end
  abort "Fastlane failed" unless success
when "cleanup"
  require_relative "lib/ci_cleanup"
  CiCleanup.recover!
else
  abort "Unsupported adapter operation"
end
