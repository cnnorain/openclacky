# frozen_string_literal: true

module Clacky
  module ThreeWayMerge
    # File classifier
    # Classifies files based on the status of three versions (base, ours, theirs)
    class FileClassifier
      # File status
      UNCHANGED = :unchanged           # No changes in any version
      OURS_ONLY = :ours_only           # Only local version modified
      THEIRS_ONLY = :theirs_only       # Only new version modified
      SAME_CHANGE = :same_change       # Both sides made same changes
      CONFLICT = :conflict             # Both sides made different changes
      ADDED_BY_OURS = :added_by_ours   # Added by local version
      ADDED_BY_THEIRS = :added_by_theirs # Added by new version
      DELETED_BY_OURS = :deleted_by_ours # Deleted by local version
      DELETED_BY_THEIRS = :deleted_by_theirs # Deleted by new version
      DELETED_BY_BOTH = :deleted_by_both # Deleted by both sides

      # Classification result structure
      Classification = Struct.new(:file_path, :status, :base_exists, :ours_exists, :theirs_exists) do
        def conflict?
          status == CONFLICT
        end

        def needs_merge?
          status == CONFLICT || status == SAME_CHANGE
        end

        def can_auto_resolve?
          [UNCHANGED, OURS_ONLY, THEIRS_ONLY, SAME_CHANGE,
           ADDED_BY_OURS, ADDED_BY_THEIRS, DELETED_BY_BOTH].include?(status)
        end
      end

      # Initialize classifier
      # @param diff_engine [DiffEngine] Difference calculation engine
      def initialize(diff_engine = nil)
        @diff_engine = diff_engine || DiffEngine.new
      end

      # Classify a single file
      # @param file_path [String] File path
      # @param base_content [String, nil] Base version content
      # @param ours_content [String, nil] Local version content
      # @param theirs_content [String, nil] New version content
      # @return [Classification] Classification result
      def classify(file_path, base_content, ours_content, theirs_content)
        base_exists = !base_content.nil?
        ours_exists = !ours_content.nil?
        theirs_exists = !theirs_content.nil?

        status = determine_status(base_content, ours_content, theirs_content, base_exists, ours_exists, theirs_exists)

        Classification.new(file_path, status, base_exists, ours_exists, theirs_exists)
      end

      # Batch classify files
      # @param files_hash [Hash] { file_path => { base: ..., ours: ..., theirs: ... } }
      # @return [Hash] { file_path => Classification }
      def classify_all(files_hash)
        files_hash.transform_values do |contents|
          classify(
            contents[:path] || "",
            contents[:base],
            contents[:ours],
            contents[:theirs]
          )
        end
      end

      # Group by status
      # @param classifications [Hash] Result of classify_all
      # @return [Hash] { status => [file_paths] }
      def group_by_status(classifications)
        classifications.group_by { |_, cls| cls.status }
                       .transform_values { |pairs| pairs.map(&:first) }
      end

      private

      def determine_status(base_content, ours_content, theirs_content, base_exists, ours_exists, theirs_exists)
        # Case 1: All three versions don't exist
        return UNCHANGED if !base_exists && !ours_exists && !theirs_exists

        # Case 2: Base doesn't exist - new file scenario
        unless base_exists
          return ADDED_BY_OURS if ours_exists && !theirs_exists
          return ADDED_BY_THEIRS if !ours_exists && theirs_exists

          # Both sides added
          return ours_content == theirs_content ? SAME_CHANGE : CONFLICT
        end

        # Case 3: Base exists, check deletion scenarios
        return DELETED_BY_OURS if !ours_exists && theirs_exists
        return DELETED_BY_THEIRS if ours_exists && !theirs_exists
        return DELETED_BY_BOTH if !ours_exists && !theirs_exists

        # Case 4: All three exist, check modifications
        ours_changed = !@diff_engine.no_change?(base_content, ours_content)
        theirs_changed = !@diff_engine.no_change?(base_content, theirs_content)

        # Neither changed
        return UNCHANGED if !ours_changed && !theirs_changed

        # Only one side changed
        return OURS_ONLY if ours_changed && !theirs_changed
        return THEIRS_ONLY if !ours_changed && theirs_changed

        # Both sides changed
        if @diff_engine.no_change?(ours_content, theirs_content)
          SAME_CHANGE
        else
          CONFLICT
        end
      end
    end
  end
end
