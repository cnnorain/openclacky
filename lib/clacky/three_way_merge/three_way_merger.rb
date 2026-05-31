# frozen_string_literal: true

require "set"
require "fileutils"

module Clacky
  module ThreeWayMerge
    # Merge result
    MergeResult = Struct.new(:status, :content, :strategy_used, :conflicts, keyword_init: true) do
      def success?
        status == :auto_merged || status == :auto_resolved
      end

      def has_conflicts?
        status == :has_conflicts
      end

      def skipped?
        status == :skipped
      end

      def error?
        status == :error
      end

      def conflict_count
        conflicts&.size || 0
      end
    end

    # Three-way merger core
    # Integrates difference calculation, file classification, and conflict resolution
    # to execute complete three-way merge workflow
    class ThreeWayMerger
      # File merge result
      FileMergeResult = Struct.new(
        :file_path, :status, :content, :classification,
        :strategy_used, :conflicts, keyword_init: true
      ) do
        def success?
          status == :auto_merged || status == :auto_resolved
        end

        def has_conflicts?
          status == :has_conflicts
        end

        def skipped?
          status == :skipped
        end

        def error?
          status == :error
        end

        def conflict_count
          conflicts&.size || 0
        end
      end

      # Initialize three-way merger
      # @param options [Hash] Configuration options
      # @option options [Symbol] :default_strategy Default conflict resolution strategy (:ours, :theirs, :mark)
      # @option options [Boolean] :auto_resolve_same_change Whether to auto-merge same changes
      # @option options [Array<String>] :ignore_patterns Ignored file patterns
      def initialize(options = {})
        @diff_engine = DiffEngine.new
        @file_classifier = FileClassifier.new(@diff_engine)
        @config_merger = ConfigMerger.new
        @conflict_resolver = ConflictResolver.new(
          strategy: options[:default_strategy] || :mark
        )

        @auto_resolve_same_change = options.fetch(:auto_resolve_same_change, true)
        @ignore_patterns = options.fetch(:ignore_patterns, [])
      end

      # Merge single file
      # @param file_path [String] File path
      # @param base_content [String, nil] Base version content
      # @param ours_content [String, nil] Local version content
      # @param theirs_content [String, nil] New version content
      # @param strategy [Symbol, nil] Specified resolution strategy
      # @return [FileMergeResult] Merge result
      def merge_file(file_path, base_content, ours_content, theirs_content, strategy: nil)
        # Check if should be ignored
        return skip_result(file_path, "File matches ignore pattern") if should_ignore?(file_path)

        # Classify file
        classification = @file_classifier.classify(file_path, base_content, ours_content, theirs_content)

        # Process by classification
        case classification.status
        when FileClassifier::UNCHANGED
          handle_unchanged(file_path, classification, base_content)

        when FileClassifier::OURS_ONLY
          handle_ours_only(file_path, classification, ours_content)

        when FileClassifier::THEIRS_ONLY
          handle_theirs_only(file_path, classification, theirs_content)

        when FileClassifier::SAME_CHANGE
          handle_same_change(file_path, classification, ours_content)

        when FileClassifier::ADDED_BY_OURS
          handle_added_by_ours(file_path, classification, ours_content)

        when FileClassifier::ADDED_BY_THEIRS
          handle_added_by_theirs(file_path, classification, theirs_content)

        when FileClassifier::DELETED_BY_BOTH
          handle_deleted_by_both(file_path, classification)

        when FileClassifier::DELETED_BY_OURS
          handle_deleted_by_ours(file_path, classification, theirs_content, strategy)

        when FileClassifier::DELETED_BY_THEIRS
          handle_deleted_by_theirs(file_path, classification, ours_content, strategy)

        when FileClassifier::CONFLICT
          handle_conflict(file_path, classification, base_content, ours_content, theirs_content, strategy)

        else
          skip_result(file_path, "Unknown classification status: #{classification.status}")
        end
      end

      # Batch merge files
      # @param files [Hash] { file_path => { base: ..., ours: ..., theirs: ... } }
      # @return [Hash] { file_path => FileMergeResult }
      def merge_files(files)
        results = {}

        files.each do |file_path, contents|
          results[file_path] = merge_file(
            file_path,
            contents[:base],
            contents[:ours],
            contents[:theirs],
            strategy: contents[:strategy]
          )
        end

        results
      end

      # Merge directories
      # @param base_dir [String] Base version directory
      # @param ours_dir [String] Local version directory
      # @param theirs_dir [String] New version directory
      # @param output_dir [String] Output directory
      # @return [Hash] Merge statistics
      def merge_directories(base_dir, ours_dir, theirs_dir, output_dir)
        # Collect all files
        all_files = collect_all_files(base_dir, ours_dir, theirs_dir)

        results = {}
        stats = { total: 0, auto_merged: 0, conflicts: 0, skipped: 0 }

        all_files.each do |relative_path|
          base_path = File.join(base_dir, relative_path)
          ours_path = File.join(ours_dir, relative_path)
          theirs_path = File.join(theirs_dir, relative_path)
          output_path = File.join(output_dir, relative_path)

          base_content = File.exist?(base_path) ? File.read(base_path) : nil
          ours_content = File.exist?(ours_path) ? File.read(ours_path) : nil
          theirs_content = File.exist?(theirs_path) ? File.read(theirs_path) : nil

          result = merge_file(relative_path, base_content, ours_content, theirs_content)
          results[relative_path] = result

          stats[:total] += 1
          if result.success?
            stats[:auto_merged] += 1
            write_output(output_path, result.content)
          elsif result.has_conflicts?
            stats[:conflicts] += 1
            write_output(output_path, result.content)
          else
            stats[:skipped] += 1
          end
        end

        { results:, stats: }
      end

      # Generate merge report
      # @param results [Hash] Result of merge_files
      # @return [String] Readable report text
      def generate_report(results)
        report = []
        report << "=" * 60
        report << "  Three-way Merge Report"
        report << "=" * 60
        report << ""

        # Statistics
        total = results.size
        success = results.count { |_, r| r.success? }
        conflicts = results.count { |_, r| r.has_conflicts? }
        skipped = results.count { |_, r| r.skipped? }

        report << "【Statistics】"
        report << "  Total files: #{total}"
        report << "  Auto-merged: #{success}"
        report << "  Conflicts: #{conflicts}"
        report << "  Skipped: #{skipped}"
        report << ""

        # Conflict details
        if conflicts.positive?
          report << "【Conflict Files】"
          results.each do |path, result|
            next unless result.has_conflicts?

            report << "  ✗ #{path}"
            next unless result.conflicts

            result.conflicts.each do |conflict|
              report << "    - #{conflict}"
            end
          end
          report << ""
        end

        # Successfully merged files
        if success.positive?
          report << "【Auto-merged Files】"
          results.each do |path, result|
            next unless result.success?

            report << "  ✓ #{path} (#{result.strategy_used})"
          end
        end

        report << ""
        report << "=" * 60
        report.join("\n")
      end

      private

      def should_ignore?(file_path)
        @ignore_patterns.any? { |pattern| File.fnmatch(pattern, file_path) }
      end

      def skip_result(file_path, reason)
        FileMergeResult.new(
          file_path:,
          status: :skipped,
          content: nil,
          classification: nil,
          strategy_used: nil,
          conflicts: [reason]
        )
      end

      def handle_unchanged(file_path, classification, content)
        FileMergeResult.new(
          file_path:,
          status: :auto_merged,
          content:,
          classification:,
          strategy_used: :unchanged,
          conflicts: []
        )
      end

      def handle_ours_only(file_path, classification, content)
        FileMergeResult.new(
          file_path:,
          status: :auto_merged,
          content:,
          classification:,
          strategy_used: :ours_only,
          conflicts: []
        )
      end

      def handle_theirs_only(file_path, classification, content)
        FileMergeResult.new(
          file_path:,
          status: :auto_merged,
          content:,
          classification:,
          strategy_used: :theirs_only,
          conflicts: []
        )
      end

      def handle_same_change(file_path, classification, content)
        FileMergeResult.new(
          file_path:,
          status: :auto_merged,
          content:,
          classification:,
          strategy_used: :same_change,
          conflicts: []
        )
      end

      def handle_added_by_ours(file_path, classification, content)
        FileMergeResult.new(
          file_path:,
          status: :auto_merged,
          content:,
          classification:,
          strategy_used: :added_by_ours,
          conflicts: []
        )
      end

      def handle_added_by_theirs(file_path, classification, content)
        FileMergeResult.new(
          file_path:,
          status: :auto_merged,
          content:,
          classification:,
          strategy_used: :added_by_theirs,
          conflicts: []
        )
      end

      def handle_deleted_by_both(file_path, classification)
        FileMergeResult.new(
          file_path:,
          status: :auto_merged,
          content: nil,
          classification:,
          strategy_used: :deleted_by_both,
          conflicts: []
        )
      end

      def handle_deleted_by_ours(file_path, classification, theirs_content, strategy)
        case strategy
        when :ours
          # Keep deletion
          FileMergeResult.new(
            file_path:,
            status: :auto_merged,
            content: nil,
            classification:,
            strategy_used: :deleted_by_ours,
            conflicts: []
          )
        when :theirs
          # Restore file
          FileMergeResult.new(
            file_path:,
            status: :auto_merged,
            content: theirs_content,
            classification:,
            strategy_used: :theirs,
            conflicts: []
          )
        else
          # Need user decision
          FileMergeResult.new(
            file_path:,
            status: :has_conflicts,
            content: nil,
            classification:,
            strategy_used: :mark,
            conflicts: ["Local deleted this file, but new version modified it"]
          )
        end
      end

      def handle_deleted_by_theirs(file_path, classification, ours_content, strategy)
        case strategy
        when :theirs
          # Keep deletion
          FileMergeResult.new(
            file_path:,
            status: :auto_merged,
            content: nil,
            classification:,
            strategy_used: :deleted_by_theirs,
            conflicts: []
          )
        when :ours
          # Keep local file
          FileMergeResult.new(
            file_path:,
            status: :auto_merged,
            content: ours_content,
            classification:,
            strategy_used: :ours,
            conflicts: []
          )
        else
          # Need user decision
          FileMergeResult.new(
            file_path:,
            status: :has_conflicts,
            content: ours_content,
            classification:,
            strategy_used: :mark,
            conflicts: ["New version deleted this file, but local modified it"]
          )
        end
      end

      def handle_conflict(file_path, classification, base_content, ours_content, theirs_content, strategy)
        # Check if it's a configuration file
        if ConfigMerger.config_file?(file_path)
          handle_config_conflict(file_path, classification, base_content, ours_content, theirs_content)
        else
          handle_text_conflict(file_path, classification, base_content, ours_content, theirs_content, strategy)
        end
      end

      def handle_config_conflict(file_path, classification, base_content, ours_content, theirs_content)
        format = ConfigMerger.detect_format(file_path)
        merger = ConfigMerger.new(format:)
        result = merger.merge(base_content, ours_content, theirs_content)

        FileMergeResult.new(
          file_path:,
          status: result.status,
          content: result.content,
          classification:,
          strategy_used: :config_merge,
          conflicts: result.conflicts.map { |c| c[:message] }
        )
      end

      def handle_text_conflict(file_path, classification, base_content, ours_content, theirs_content, strategy)
        result = @conflict_resolver.resolve(base_content, ours_content, theirs_content, strategy:)

        FileMergeResult.new(
          file_path:,
          status: result.status,
          content: result.content,
          classification:,
          strategy_used: result.strategy_used,
          conflicts: result.conflicts.map(&:to_s)
        )
      end

      def collect_all_files(base_dir, ours_dir, theirs_dir)
        files = Set.new

        [base_dir, ours_dir, theirs_dir].each do |dir|
          next unless Dir.exist?(dir)

          Dir.glob("**/*", base: dir).each do |relative_path|
            full_path = File.join(dir, relative_path)
            files.add(relative_path) if File.file?(full_path)
          end
        end

        files.to_a.sort
      end

      def write_output(path, content)
        return if content.nil?

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
    end
  end
end
