# 認証キーを Xcode の子プロセスから読める一時ファイルへ書かないことを確かめる。
require "base64"
require "minitest/autorun"
require "tmpdir"

class AscCredentialsTest < Minitest::Test
  def with_env(values)
    saved = values.to_h { |name, _| [name, ENV[name]] }
    values.each { |name, value| ENV[name] = value }
    yield
  ensure
    saved.each { |name, value| ENV[name] = value }
  end

  def lane
    sandbox = Class.new do
      def self.opt_out_usage; end
      def self.desc(*); end
      def self.lane(*); end
    end
    ui = Module.new
    ui.define_singleton_method(:user_error!) { |message| raise ArgumentError, message }
    sandbox.const_set(:UI, ui)
    path = File.expand_path("../Fastfile", __dir__)
    sandbox.class_eval(File.read(path), path)
    instance = sandbox.new
    instance.define_singleton_method(:app_store_connect_api_key) { |**options| options }
    instance
  end

  def test_ci_passes_base64_content_in_memory_without_a_key_file
    encoded = Base64.strict_encode64("test-only-key")
    with_env("GITHUB_ACTIONS" => "true", "ASC_KEY_ID" => "fixture", "ASC_ISSUER_ID" => "issuer",
             "ASC_KEY_CONTENT" => encoded, "ASC_KEY_FILEPATH" => nil) do
      instance = lane
      instance.define_singleton_method(:asc_key_filepath) { raise "key file path was used" }
      options = instance.asc_api_key
      assert_equal encoded, options[:key_content]
      assert_equal true, options[:is_key_content_base64]
      refute options.key?(:key_filepath)
    end
  end

  def test_missing_ci_content_never_falls_back_to_a_local_key_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "local.p8")
      File.write(path, "test-only-key")
      with_env("GITHUB_ACTIONS" => "true", "ASC_KEY_ID" => "fixture", "ASC_ISSUER_ID" => "issuer",
               "ASC_KEY_CONTENT" => nil, "ASC_KEY_FILEPATH" => path) do
        error = assert_raises(ArgumentError) { lane.asc_api_key }
        assert_includes error.message, "ASC_KEY_CONTENT"
      end
    end
  end

  def test_local_read_only_metadata_tools_keep_the_existing_file_input
    Dir.mktmpdir do |dir|
      path = File.join(dir, "local.p8")
      File.write(path, "test-only-key")
      with_env("GITHUB_ACTIONS" => nil, "ASC_KEY_ID" => "fixture", "ASC_ISSUER_ID" => "issuer",
               "ASC_KEY_CONTENT" => nil, "ASC_KEY_FILEPATH" => path) do
        options = lane.asc_api_key
        assert_equal path, options[:key_filepath]
        refute options.key?(:key_content)
      end
    end
  end
end
