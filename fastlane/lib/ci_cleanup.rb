# frozen_string_literal: true
require "json"
require "fileutils"
require "open3"
require "shellwords"
require_relative "shared_actions_loader"
SharedActionsLoader.load!(app_root: File.expand_path("../..", __dir__))
require File.join(ENV.fetch("QTMLEAP_ACTIONS_ROOT"), "runtime/environment")

# キャンセル後も復元できるよう、署名より前に秘密を含まない状態だけ保存する。
module CiCleanup
  module_function

  def journal
    File.join(ENV.fetch("HOME"), ".local/state/musicfin-ci-keychain.json")
  end

  def command(*argv)
    out, status = Open3.capture2e(SharedCI::Environment.child, *argv, unsetenv_others: true)
    raise "Keychain recovery command failed" unless status.success?
    out
  end

  # 復元ファイルを別の所有者やリンクにすり替えさせない。
  def journal_directory!
    home = File.realpath(ENV.fetch("HOME"))
    cursor = home
    %w[.local state].each do |part|
      cursor = File.join(cursor, part)
      Dir.mkdir(cursor, 0o700) unless File.exist?(cursor) || File.symlink?(cursor)
      stat = File.lstat(cursor)
      raise "Unsafe recovery directory" unless stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o022).zero?
    end
  end

  def sync_directory!
    File.open(File.dirname(journal), File::RDONLY) { |directory| directory.fsync }
  end

  def prepare!
    recover!
    name = "musicfin-ci-#{ENV.fetch('GITHUB_RUN_ID')}.keychain"
    state = { "name" => name, "default" => command("security", "default-keychain", "-d", "user").strip.delete('"'),
              "list" => Shellwords.split(command("security", "list-keychains", "-d", "user")) }
    journal_directory!
    File.open(journal, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.generate(state))
      file.flush
      file.fsync
    end
    sync_directory!
    ENV["CI_KEYCHAIN_NAME"] = name
  end

  def recover!
    journal_directory!
    return unless File.exist?(journal) || File.symlink?(journal)
    stat = File.lstat(journal)
    raise "Unsafe recovery journal" unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o600 && stat.size <= 32_768
    state = JSON.parse(File.read(journal))
    raise "Invalid recovery journal" unless state.fetch("name").match?(/\Amusicfin-ci-[0-9]+\.keychain\z/) &&
      state.fetch("default").is_a?(String) && state.fetch("list").is_a?(Array) && state["list"].all? { |path| path.is_a?(String) }
    command("security", "list-keychains", "-d", "user", "-s", *state["list"])
    command("security", "default-keychain", "-d", "user", "-s", state["default"]) unless state["default"].empty?
    path = File.join(ENV.fetch("HOME"), "Library/Keychains", state["name"] + "-db")
    raise "Recovery keychain symlink rejected" if File.symlink?(path)
    command("security", "delete-keychain", path) if File.exist?(path)
    File.delete(journal) # 復元の失敗時には残し、次回も再試行する。
    sync_directory!
  end
end
