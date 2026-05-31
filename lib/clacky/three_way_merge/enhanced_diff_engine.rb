# frozen_string_literal: true

require "diffy"

module Clacky
  module ThreeWayMerge
    # Enhanced difference calculation engine
    # Supports caching, better conflict markers, binary detection
    class EnhancedDiffEngine
      # Difference types
      ADDED = :added
      DELETED = :deleted
      CHANGED = :changed
      UNCHANGED = :unchanged

      # Enhanced difference result
      DiffResult = Struct.new(
        :type, :old_line, :new_line,
        :old_line_num, :new_line_num,
        :context_before, :context_after,
        keyword_init: true
      ) do
        def to_s
          case type
          when ADDED then "+ #{new_line}"
          when DELETED then "- #{old_line}"
          when CHANGED then "~ #{old_line} => #{new_line}"
          else "  #{old_line}"
          end
        end
      end

      # Initialize
      # @param options [Hash] Options
      # @option options [Integer] :cache_size Cache size
      # @option options [Integer] :context_lines Context lines
      def initialize(options = {})
        @cache_size = options.fetch(:cache_size, 100)
        @context_lines = options.fetch(:context_lines, 3)
        @cache = {}
        @cache_order = []
      end

      # Calculate line-level differences (with cache)
      # @param old_text [String]
      # @param new_text [String]
      # @return [Array<DiffResult>]
      def diff_lines(old_text, new_text)
        cache_key = generate_cache_key(old_text, new_text)

        # Check cache
        if @cache.key?(cache_key)
          touch_cache(cache_key)
          return @cache[cache_key]
        end

        # Calculate differences
        result = compute_diff(old_text, new_text)

        # Store in cache
        store_in_cache(cache_key, result)

        result
      end

      # Generate conflict markers with context
      # @param file_path [String] File path
      # @param ours [String] Local content
      # @param theirs [String] New version content
      # @param base [String] Base content
      # @return [String] Content with markers
      def generate_conflict_markers(file_path, ours, theirs, _base)
        ours_lines = ours.to_s.lines
        theirs_lines = theirs.to_s.lines

        result = []
        result << "# <<<<<<< Conflict Start [#{file_path}]"
        result << "# Local Version (Ours):"
        result << "# -------"

        ours_lines.each do |line|
          result << line.chomp
        end

        result << "# ======="
        result << "# New Version (Theirs):"
        result << "# -------"

        theirs_lines.each do |line|
          result << line.chomp
        end

        result << "# >>>>>>> Conflict End [#{file_path}]"
        result.join("\n")
      end

      # Detect file renames (based on content similarity)
      # @param old_files [Hash] { path => content }
      # @param new_files [Hash] { path => content }
      # @param threshold [Float] Similarity threshold (0.0 - 1.0)
      # @return [Array<Hash>] Rename list [{ old:, new:, similarity: }]
      def detect_renames(old_files, new_files, threshold: 0.8)
        renames = []
        used_old = Set.new
        used_new = Set.new

        # Find added and deleted files
        deleted = old_files.keys - new_files.keys
        added = new_files.keys - old_files.keys

        # Compare similarity
        deleted.each do |old_path|
          best_match = nil
          best_score = 0

          added.each do |new_path|
            next if used_new.include?(new_path)

            score = calculate_similarity(old_files[old_path], new_files[new_path])
            if score > best_score
              best_score = score
              best_match = new_path
            end
          end

          next unless best_match && best_score >= threshold

          renames << {
            old: old_path,
            new: best_match,
            similarity: best_score
          }
          used_old << old_path
          used_new << best_match
        end

        renames
      end

      # Clear cache
      def clear_cache
        @cache.clear
        @cache_order.clear
      end

      private

      def compute_diff(old_text, new_text)
        return [] if old_text == new_text

        # Use Diffy to calculate differences
        diff = Diffy::Diff.new(old_text, new_text, context: @context_lines)

        results = []
        changes = parse_diff_output(diff)

        changes.each do |change|
          case change[:type]
          when :added
            results << DiffResult.new(
              type: ADDED,
              old_line: nil,
              new_line: change[:line],
              old_line_num: nil,
              new_line_num: change[:new_line_num],
              context_before: change[:context_before],
              context_after: change[:context_after]
            )
          when :deleted
            results << DiffResult.new(
              type: DELETED,
              old_line: change[:line],
              new_line: nil,
              old_line_num: change[:old_line_num],
              new_line_num: nil,
              context_before: change[:context_before],
              context_after: change[:context_after]
            )
          when :unchanged
            results << DiffResult.new(
              type: UNCHANGED,
              old_line: change[:line],
              new_line: change[:line],
              old_line_num: change[:old_line_num],
              new_line_num: change[:new_line_num]
            )
          end
        end

        results
      end

      def parse_diff_output(diff)
        changes = []
        line_num = 0

        diff.each do |change|
          case change
          when /^\+\s*(.*)$/
            changes << { type: :added, line: ::Regexp.last_match(1), new_line_num: line_num + 1 }
          when /^-\s*(.*)$/
            changes << { type: :deleted, line: ::Regexp.last_match(1), old_line_num: line_num + 1 }
          else
            change.lines.each do |line|
              changes << {
                type: :unchanged,
                line: line.chomp,
                old_line_num: line_num + 1,
                new_line_num: line_num + 1
              }
              line_num += 1
            end
          end
        end

        # Add context information
        add_context_to_changes(changes)
      end

      def add_context_to_changes(changes)
        changes.each_with_index do |change, i|
          # Context before
          context_before = []
          ([i - @context_lines, 0].max...i).each do |j|
            context_before << changes[j][:line] if changes[j][:line]
          end
          change[:context_before] = context_before

          # Context after
          context_after = []
          ((i + 1)..[i + @context_lines, changes.size - 1].min).each do |j|
            context_after << changes[j][:line] if changes[j][:line]
          end
          change[:context_after] = context_after
        end

        changes
      end

      def split_lines(text)
        text.to_s.lines.map(&:chomp)
      end

      # Calculate similarity between two texts (0.0 - 1.0)
      def calculate_similarity(text1, text2)
        return 1.0 if text1 == text2
        return 0.0 if text1.nil? || text2.nil?

        lines1 = split_lines(text1).to_set
        lines2 = split_lines(text2).to_set

        intersection = (lines1 & lines2).size
        union = (lines1 | lines2).size

        return 0.0 if union.zero?

        intersection.to_f / union
      end

      def generate_cache_key(old_text, new_text)
        "#{old_text.hash}:#{new_text.hash}:#{@context_lines}"
      end

      def touch_cache(key)
        @cache_order.delete(key)
        @cache_order << key
      end

      def store_in_cache(key, value)
        # If cache is full, remove oldest
        if @cache.size >= @cache_size
          oldest = @cache_order.shift
          @cache.delete(oldest)
        end

        @cache[key] = value
        @cache_order << key
      end
    end
  end
end
