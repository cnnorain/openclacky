# frozen_string_literal: true

require "json"
require "fileutils"
require "digest"

module Clacky
  module ThreeWayMerge
    # Version manager
    # Manages version snapshots, tracks current version, and provides update detection
    # Default storage location: ~/.clacky/versions/
    class VersionManager
      MANIFEST_FILE = "manifest.json"
      CURRENT_VERSION_FILE = ".current"
      DEFAULT_VERSIONS_DIR = File.join(Dir.home, ".clacky", "versions")

      # Version manifest structure
      Manifest = Struct.new(:version, :timestamp, :files, keyword_init: true) do
        def to_h
          {
            version:,
            timestamp:,
            files:
          }
        end
      end

      # File info structure
      FileInfo = Struct.new(:file_hash, :file_size, :modified_at, keyword_init: true)

      # Initialize version manager
      # @param versions_dir [String] Version storage directory, default ~/.clacky/versions/
      def initialize(versions_dir = DEFAULT_VERSIONS_DIR)
        @versions_dir = versions_dir
        FileUtils.mkdir_p(@versions_dir)
      end

      # Save version snapshot
      # @param version [String] Version number
      # @param source_dir [String] Source file directory
      # @return [Manifest] Version manifest
      def save_snapshot(version, source_dir)
        version_dir = version_path(version)
        FileUtils.mkdir_p(version_dir)

        files = {}

        # Traverse source directory, compute file hashes
        Dir.glob("**/*", base: source_dir).each do |relative_path|
          full_path = File.join(source_dir, relative_path)
          next unless File.file?(full_path)

          content = File.read(full_path)
          files[relative_path] = {
            hash: Digest::SHA256.hexdigest(content),
            size: content.bytesize,
            modified_at: File.mtime(full_path).iso8601
          }

          # Copy file to version directory
          dest_path = File.join(version_dir, relative_path)
          FileUtils.mkdir_p(File.dirname(dest_path))
          FileUtils.cp(full_path, dest_path)
        end

        manifest = Manifest.new(
          version:,
          timestamp: Time.now.iso8601,
          files:
        )

        # Save manifest
        manifest_path = File.join(version_dir, MANIFEST_FILE)
        File.write(manifest_path, JSON.pretty_generate(manifest.to_h))

        # Update current version
        update_current_version(version)

        manifest
      end

      # Load version manifest
      # @param version [String] Version number
      # @return [Manifest, nil]
      def load_manifest(version)
        manifest_path = File.join(version_path(version), MANIFEST_FILE)
        return nil unless File.exist?(manifest_path)

        data = JSON.parse(File.read(manifest_path))
        Manifest.new(
          version: data["version"],
          timestamp: data["timestamp"],
          files: data["files"]
        )
      end

      # Get current version number
      # @return [String, nil]
      def current_version
        current_file = File.join(@versions_dir, CURRENT_VERSION_FILE)
        return nil unless File.exist?(current_file)

        File.read(current_file).strip
      end

      # Get version list
      # @return [Array<String>] Version list sorted by time
      def versions
        Dir.glob("*", base: @versions_dir)
           .select { |f| File.directory?(File.join(@versions_dir, f)) }
           .sort
      end

      # Check if version exists
      # @param version [String]
      # @return [Boolean]
      def version_exists?(version)
        Dir.exist?(version_path(version))
      end

      # Get file content from version
      # @param version [String] Version number
      # @param file_path [String] File relative path
      # @return [String, nil]
      def get_file_content(version, file_path)
        full_path = File.join(version_path(version), file_path)
        return nil unless File.exist?(full_path)

        File.read(full_path)
      end

      # Get all file contents from version
      # @param version [String]
      # @return [Hash] { file_path => content }
      def get_all_files(version)
        manifest = load_manifest(version)
        return {} unless manifest

        files = {}
        manifest.files.each do |file_path, _|
          content = get_file_content(version, file_path)
          files[file_path] = content if content
        end

        files
      end

      # Compare two versions
      # @param version1 [String]
      # @param version2 [String]
      # @return [Hash] { added: [...], deleted: [...], modified: [...] }
      def diff_versions(version1, version2)
        manifest1 = load_manifest(version1)
        manifest2 = load_manifest(version2)

        return nil unless manifest1 && manifest2

        files1 = manifest1.files.keys.to_set
        files2 = manifest2.files.keys.to_set

        added = (files2 - files1).to_a.sort
        deleted = (files1 - files2).to_a.sort

        modified = []
        (files1 & files2).each do |file_path|
          modified << file_path if manifest1.files[file_path]["hash"] != manifest2.files[file_path]["hash"]
        end

        { added:, deleted:, modified: modified.sort }
      end

      # Delete version
      # @param version [String]
      def delete_version(version)
        version_dir = version_path(version)
        FileUtils.rm_rf(version_dir) if Dir.exist?(version_dir)
      end

      # Get version size
      # @param version [String]
      # @return [Integer] Size in bytes
      def version_size(version)
        version_dir = version_path(version)
        return 0 unless Dir.exist?(version_dir)

        size = 0
        Dir.glob("**/*", base: version_dir).each do |f|
          full_path = File.join(version_dir, f)
          size += File.size(full_path) if File.file?(full_path)
        end
        size
      end

      private

      def version_path(version)
        # Validate version string to prevent path traversal
        if version.nil? || version.strip.empty?
          raise ArgumentError, "Version cannot be empty"
        end

        if version.include?("..") || version.include?("/") || version.include?(92.chr)
          raise ArgumentError, "Invalid version string: #{version}"
        end

        File.join(@versions_dir, version)
      end

      def update_current_version(version)
        current_file = File.join(@versions_dir, CURRENT_VERSION_FILE)
        File.write(current_file, version)
      end
    end
  end
end
