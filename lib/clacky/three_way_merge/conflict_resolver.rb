# frozen_string_literal: true

module Clacky
  module ThreeWayMerge
    # Conflict resolver
    # Handles conflicts in three-way merges, provides automatic resolution and marking functionality
    class ConflictResolver
      # Conflict marker format
      MARKER_LOCAL = "<<<<<<< LOCAL (Your Changes)"
      MARKER_SEPARATOR = "======="
      MARKER_UPSTREAM = ">>>>>>> UPSTREAM (New Version)"

      # Conflict information structure
      Conflict = Struct.new(:line_number, :ours_content, :theirs_content, :context) do
        def to_s
          "Conflict at line #{line_number}: Local[#{ours_content.strip}] vs New[#{theirs_content.strip}]"
        end
      end

      # Resolution strategies
      STRATEGY_OURS = :ours         # Keep local version
      STRATEGY_THEIRS = :theirs     # Use new version
      STRATEGY_MERGE = :merge       # Try intelligent merge
      STRATEGY_MARK = :mark         # Mark conflict for manual resolution

      # Initialize conflict resolver
      # @param strategy [Symbol] Default resolution strategy
      def initialize(strategy: STRATEGY_MARK)
        @strategy = strategy
      end

      # Resolve conflict content
      # @param base [String] Base version content
      # @param ours [String] Local version content
      # @param theirs [String] New version content
      # @param strategy [Symbol] Resolution strategy (overrides default)
      # @return [MergeResult] Merge result
      def resolve(base, ours, theirs, strategy: nil)
        strategy ||= @strategy

        case strategy
        when STRATEGY_OURS
          resolve_with_ours(ours)
        when STRATEGY_THEIRS
          resolve_with_theirs(theirs)
        when STRATEGY_MERGE
          resolve_with_merge(base, ours, theirs)
        else
          resolve_with_markers(ours, theirs)
        end
      end

      # Parse conflict markers
      # @param content [String] Content with conflict markers
      # @return [Array<Conflict>] Conflict list
      def parse_conflict_markers(content)
        conflicts = []
        in_conflict = false
        in_theirs = false
        ours_lines = []
        theirs_lines = []
        line_num = 0
        conflict_start = 0

        content.each_line do |line|
          line_num += 1

          if line.start_with?("<<<<<<<")
            in_conflict = true
            in_theirs = false
            ours_lines = []
            theirs_lines = []
            conflict_start = line_num
            next
          end

          if line.strip.start_with?("=======") && in_conflict
            # Separator, switch to theirs
            in_theirs = true
            next
          end

          if line.start_with?(">>>>>>>") && in_conflict
            # Conflict end
            conflicts << Conflict.new(
              conflict_start,
              ours_lines.join,
              theirs_lines.join,
              "Lines #{conflict_start}-#{line_num}"
            )
            in_conflict = false
            in_theirs = false
            next
          end

          if in_conflict
            if in_theirs
              theirs_lines << line
            else
              ours_lines << line
            end
          end
        end

        conflicts
      end

      # Check if content contains conflict markers
      # @param content [String]
      # @return [Boolean]
      def has_conflict_markers?(content)
        content.include?("<<<<<<<") && content.include?(">>>>>>>")
      end

      # Count conflicts
      # @param content [String]
      # @return [Integer]
      def count_conflicts(content)
        content.scan(/<<<<<<< /).size
      end

      # Remove all conflict markers (keep ours version)
      # @param content [String]
      # @return [String]
      def resolve_all_to_ours(content)
        resolve_markers(content, keep: :ours)
      end

      # Remove all conflict markers (keep theirs version)
      # @param content [String]
      # @return [String]
      def resolve_all_to_theirs(content)
        resolve_markers(content, keep: :theirs)
      end

      private

      def resolve_with_ours(ours)
        MergeResult.new(
          status: :auto_resolved,
          content: ours,
          strategy_used: STRATEGY_OURS,
          conflicts: []
        )
      end

      def resolve_with_theirs(theirs)
        MergeResult.new(
          status: :auto_resolved,
          content: theirs,
          strategy_used: STRATEGY_THEIRS,
          conflicts: []
        )
      end

      def resolve_with_merge(base, ours, theirs)
        # Try line-level intelligent merge
        merged = intelligent_merge(base, ours, theirs)

        if merged[:success]
          MergeResult.new(
            status: :auto_resolved,
            content: merged[:content],
            strategy_used: STRATEGY_MERGE,
            conflicts: []
          )
        else
          # Intelligent merge failed, mark conflict
          resolve_with_markers(ours, theirs)
        end
      end

      def resolve_with_markers(ours, theirs)
        content = <<~CONTENT
          #{MARKER_LOCAL}
          #{ours.chomp}
          #{MARKER_SEPARATOR}
          #{theirs.chomp}
          #{MARKER_UPSTREAM}
        CONTENT

        MergeResult.new(
          status: :has_conflicts,
          content:,
          strategy_used: STRATEGY_MARK,
          conflicts: [Conflict.new(0, ours, theirs, "Full text conflict")]
        )
      end

      def intelligent_merge(base, ours, theirs)
        base_lines = base.lines.map(&:chomp)
        ours_lines = ours.lines.map(&:chomp)
        theirs_lines = theirs.lines.map(&:chomp)

        # Scenario 1: Check if both sides appended after base
        base_size = base_lines.size
        ours_prefix = ours_lines[0...base_size]
        theirs_prefix = theirs_lines[0...base_size]

        # If both modifications are after base
        if ours_prefix == base_lines && theirs_prefix == base_lines
          ours_added = ours_lines[base_size..] || []
          theirs_added = theirs_lines[base_size..] || []

          # Merge both sides' additions
          merged_lines = base_lines.dup
          ours_added.each { |line| merged_lines << line unless merged_lines.include?(line) }
          theirs_added.each { |line| merged_lines << line unless merged_lines.include?(line) }

          return { success: true, content: "#{merged_lines.join("\n")}\n" }
        end

        # Scenario 2: One side completely contains the other
        if ours_lines.size >= theirs_lines.size
          if theirs_lines.each_with_index.all? { |line, i| line == ours_lines[i] }
            return { success: true, content: ours }
          end
        elsif ours_lines.each_with_index.all? { |line, i| line == theirs_lines[i] }
          return { success: true, content: theirs }
        end

        # Scenario 3: Common prefix with safe append-only detection
        # Only auto-merge if the common prefix is 100% match and
        # the remaining lines are pure additions (not modifications)
        common_prefix = 0
        [ours_lines.size, theirs_lines.size].min.times do |i|
          break unless ours_lines[i] == theirs_lines[i]

          common_prefix += 1
        end

        # Only auto-merge if:
        # 1. Common prefix is substantial (>80% of smaller file)
        # 2. Both sides only added lines after the common prefix (no modifications)
        min_size = [ours_lines.size, theirs_lines.size].min
        if common_prefix >= min_size * 0.8 && common_prefix.positive?
          # Check that both sides only appended (didn't modify existing lines)
          ours_remaining = ours_lines[common_prefix..] || []
          theirs_remaining = theirs_lines[common_prefix..] || []

          # If both sides have remaining lines that are different,
          # we need to check if they're truly append-only
          # A safe heuristic: only auto-merge if one side is a prefix of the other
          # (meaning one side only added, the other didn't change the existing content)
          if ours_remaining.empty? || theirs_remaining.empty?
            # One side didn't add anything, safe to use the other
            return { success: true, content: ours.size >= theirs.size ? ours : theirs }
          end

          # Both sides added different content - this is a conflict
          # Don't auto-merge as it could lose data
        end

        # Cannot auto-merge
        { success: false, content: nil }
      end

      def resolve_markers(content, keep: :ours)
        result = []
        in_conflict = false
        use_section = nil

        content.each_line do |line|
          if line.start_with?("<<<<<<<")
            in_conflict = true
            use_section = :ours
            next
          end

          if line.start_with?("=======") && in_conflict
            use_section = :theirs
            next
          end

          if line.start_with?(">>>>>>>") && in_conflict
            in_conflict = false
            use_section = nil
            next
          end

          result << line if !in_conflict || use_section == keep
        end

        result.join
      end
    end
  end
end
