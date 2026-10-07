require "open3"
require "rbconfig"
require "tmpdir"

# 配信前の adapter は Bundler の外で動くため、VM の既定 gem だけでも読み込める必要がある。
Dir.mktmpdir("musicfin-unbundled-policy-") do |directory|
  env = ENV.keys.select { |name| name.start_with?("BUNDLE_", "BUNDLER_") }.to_h { |name| [name, nil] }
  env.merge!("GEM_HOME" => directory, "GEM_PATH" => directory, "RUBYOPT" => nil, "RUBYLIB" => nil)
  policy = File.expand_path("../lib/deployment_policy.rb", __dir__)
  script = <<~RUBY
    require #{policy.inspect}
    env = { "MATCH_GIT_TOKEN" => "fixture-token", "MATCH_GIT_PRIVATE_KEY" => "" }
    DeploymentPolicy.signing_environment!(env: env, ssh: false)
    print env.fetch("MATCH_GIT_BASIC_AUTHORIZATION")
  RUBY
  output, error, status = Open3.capture3(env, RbConfig.ruby, "-e", script)
  abort "Unbundled policy failed: #{error}" unless status.success?
  abort "Authorization bytes changed" unless output == "eC1hY2Nlc3MtdG9rZW46Zml4dHVyZS10b2tlbg=="
end
puts "Unbundled policy loads and preserves token authorization"
