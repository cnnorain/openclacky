# frozen_string_literal: true

# Three-way Merge Module
# Provides complete three-way merge functionality for software version updates,
# configuration merging, and other scenarios.

require_relative "three_way_merge/security"
require_relative "three_way_merge/diff_engine"
require_relative "three_way_merge/enhanced_diff_engine"
require_relative "three_way_merge/file_classifier"
require_relative "three_way_merge/conflict_resolver"
require_relative "three_way_merge/config_merger"
require_relative "three_way_merge/enhanced_config_merger"
require_relative "three_way_merge/three_way_merger"
require_relative "three_way_merge/version_manager"
require_relative "three_way_merge/rollback_manager"
require_relative "three_way_merge/enhanced_rollback_manager"

module Clacky
  # Three-way Merge Module
  # Provides complete three-way merge functionality for software version updates,
  # configuration merging, and other scenarios.
  #
  # @example Basic usage
  #   merger = Clacky::ThreeWayMerge.create_merger
  #   result = merger.merge_file("config.json", base, ours, theirs)
  #
  # @example Using version manager
  #   vm = Clacky::ThreeWayMerge.version_manager
  #   vm.save_snapshot("1.0.0", "/path/to/v1")
  #   vm.save_snapshot("1.1.0", "/path/to/v2")
  #
  # @example Batch merge files
  #   merger = Clacky::ThreeWayMerge.create_merger
  #   results = merger.merge_files({
  #     "config.json" => { base: ..., ours: ..., theirs: ... },
  #     "settings.yaml" => { base: ..., ours: ..., theirs: ... }
  #   })
  #   report = merger.generate_report(results)
  #
  # @example Merge with rollback protection
  #   result = Clacky::ThreeWayMerge.merge_with_rollback(files)
  #   unless result[:success]
  #     puts "Merge failed: #{result[:error]}"
  #   end
  #
  module ThreeWayMerge
    # Module version
    VERSION = "2.0.0"

    # Create a merger instance
    # @param enhanced [Boolean] Whether to use enhanced version (default true)
    # @param options [Hash] Options
    # @return [ThreeWayMerger]
    def self.create_merger(enhanced: true, **options)
      if enhanced
        create_enhanced_merger(options)
      else
        ThreeWayMerger.new(options)
      end
    end

    # Create enhanced merger
    def self.create_enhanced_merger(options = {})
      merger = ThreeWayMerger.new(options)
      merger.instance_variable_set(:@diff_engine, EnhancedDiffEngine.new)
      merger.instance_variable_set(:@config_merger, EnhancedConfigMerger.new)
      merger
    end

    # Quick merge single file (with security checks)
    # @param file_path [String] File path
    # @param base [String, nil] Base version content
    # @param ours [String, nil] Local version content
    # @param theirs [String, nil] New version content
    # @param options [Hash] Options
    # @return [ThreeWayMerger::FileMergeResult]
    def self.merge_file(file_path, base, ours, theirs, _options = {})
      # Security check
      Security.validate_path!(file_path)

      # Binary file detection
      return create_binary_result(file_path, base, ours, theirs) if Security.binary_file?(file_path)

      # Content security check
      [base, ours, theirs].each do |content|
        raise ArgumentError, "File content exceeds size limit" if content && !Security.safe_content_size?(content)
      end

      merger = create_merger(enhanced: true)
      merger.merge_file(file_path, base, ours, theirs)
    end

    # Quick merge multiple files
    # @param files [Hash] { path => { base:, ours:, theirs: } }
    # @param options [Hash] Options
    # @return [Hash] { path => FileMergeResult }
    def self.merge_files(files, _options = {})
      merger = create_merger(enhanced: true)
      merger.merge_files(files)
    end

    # Merge directories
    # @param base_dir [String] Base version directory
    # @param ours_dir [String] Local version directory
    # @param theirs_dir [String] New version directory
    # @param output_dir [String] Output directory
    # @param options [Hash] Options
    # @return [Hash] Merge statistics
    def self.merge_directories(base_dir, ours_dir, theirs_dir, output_dir, _options = {})
      merger = create_merger(enhanced: true)
      merger.merge_directories(base_dir, ours_dir, theirs_dir, output_dir)
    end

    # Create version manager
    # @param versions_dir [String] Version storage directory, default ~/.clacky/versions/
    # @return [VersionManager]
    def self.version_manager(versions_dir = nil)
      VersionManager.new(versions_dir || VersionManager::DEFAULT_VERSIONS_DIR)
    end

    # Check if file has conflict markers
    # @param content [String] File content
    # @return [Boolean]
    def self.has_conflicts?(content)
      resolver = ConflictResolver.new
      resolver.has_conflict_markers?(content)
    end

    # Resolve all conflicts (keep local version)
    # @param content [String] Content with conflict markers
    # @return [String] Resolved content
    def self.resolve_to_ours(content)
      resolver = ConflictResolver.new
      resolver.resolve_all_to_ours(content)
    end

    # Resolve all conflicts (keep new version)
    # @param content [String] Content with conflict markers
    # @return [String] Resolved content
    def self.resolve_to_theirs(content)
      resolver = ConflictResolver.new
      resolver.resolve_all_to_theirs(content)
    end

    # Create rollback manager
    # @param backup_dir [String] Backup directory, default ~/.clacky/merge_backups/
    # @return [EnhancedRollbackManager]
    def self.rollback_manager(backup_dir = nil)
      EnhancedRollbackManager.new(backup_dir || EnhancedRollbackManager::BACKUP_DIR)
    end

    # Merge with rollback protection
    # @param files [Hash] { file_path => { base:, ours:, theirs: } }
    # @param options [Hash] Merge options
    # @return [Hash] Merge result (includes backup_id)
    def self.merge_with_rollback(files, _options = {})
      merger = create_merger(enhanced: true)
      rollback_mgr = EnhancedRollbackManager.new
      rollback_mgr.transaction(files, merger)
    end

    # Detect file renames
    # @param old_files [Hash] { path => content }
    # @param new_files [Hash] { path => content }
    # @param threshold [Float] Similarity threshold
    # @return [Array<Hash>] Rename list
    def self.detect_renames(old_files, new_files, threshold: 0.8)
      engine = EnhancedDiffEngine.new
      engine.detect_renames(old_files, new_files, threshold:)
    end

    # Handle binary file merge
    private_class_method def self.create_binary_result(file_path, base, ours, theirs)
      if ours == theirs
        ThreeWayMerger::FileMergeResult.new(
          file_path:,
          status: :auto_merged,
          content: ours,
          classification: nil,
          strategy_used: :binary_same,
          conflicts: []
        )
      elsif base == ours
        ThreeWayMerger::FileMergeResult.new(
          file_path:,
          status: :auto_merged,
          content: theirs,
          classification: nil,
          strategy_used: :binary_theirs,
          conflicts: []
        )
      elsif base == theirs
        ThreeWayMerger::FileMergeResult.new(
          file_path:,
          status: :auto_merged,
          content: ours,
          classification: nil,
          strategy_used: :binary_ours,
          conflicts: []
        )
      else
        ThreeWayMerger::FileMergeResult.new(
          file_path:,
          status: :has_conflicts,
          content: nil,
          classification: nil,
          strategy_used: :binary_conflict,
          conflicts: ["Binary file conflict, please manually select which version to keep"]
        )
      end
    end
  end
end

# Convenience alias
TWM = Clacky::ThreeWayMerge unless defined?(TWM)
