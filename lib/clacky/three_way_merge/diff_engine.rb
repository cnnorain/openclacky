# frozen_string_literal: true

require "diffy"

module Clacky
  module ThreeWayMerge
    # Difference calculation engine
    # Responsible for calculating differences between two texts, supporting line-level and character-level differences
    class DiffEngine
      # Difference types
      ADDED = :added       # Added lines
      DELETED = :deleted   # Deleted lines
      CHANGED = :changed   # Modified lines
      UNCHANGED = :unchanged # Unchanged

      # Difference result structure
      DiffResult = Struct.new(:type, :old_line, :new_line, :old_line_num, :new_line_num) do
        def to_s
          case type
          when ADDED then "+ #{new_line}"
          when DELETED then "- #{old_line}"
          when CHANGED then "~ #{old_line} => #{new_line}"
          else "  #{old_line}"
          end
        end
      end

      # Calculate line-level differences
      # @param old_text [String] Old text
      # @param new_text [String] New text
      # @return [Array<DiffResult>] Difference list
      def diff_lines(old_text, new_text)
        # Use Diffy to calculate differences
        diff = Diffy::Diff.new(old_text, new_text, context: 0)

        results = []
        old_idx = 0
        new_idx = 0

        diff.each do |change|
          case change
          when /^\+\s*(.*)$/
            # Added line
            results << DiffResult.new(ADDED, nil, ::Regexp.last_match(1), nil, new_idx + 1)
            new_idx += 1
          when /^-\s*(.*)$/
            # Deleted line
            results << DiffResult.new(DELETED, ::Regexp.last_match(1), nil, old_idx + 1, nil)
            old_idx += 1
          else
            # Unchanged line (won't appear with context: 0, but keep for safety)
            lines = change.lines
            lines.each do |line|
              line = line.strip
              results << DiffResult.new(UNCHANGED, line, line, old_idx + 1, new_idx + 1)
              old_idx += 1
              new_idx += 1
            end
          end
        end

        results
      end

      # Calculate patch (unified diff format)
      # @param old_text [String] Old text
      # @param new_text [String] New text
      # @return [String] Unified diff patch
      def generate_patch(old_text, new_text)
        Diffy::Diff.new(old_text, new_text).to_s(:text)
      end

      # Check if two texts are identical
      # @param text1 [String]
      # @param text2 [String]
      # @return [Boolean]
      def identical?(text1, text2)
        text1 == text2
      end

      # Check if differences are empty (texts are same)
      # @param old_text [String]
      # @param new_text [String]
      # @return [Boolean]
      def no_change?(old_text, new_text)
        normalize_text(old_text) == normalize_text(new_text)
      end

      private

      def split_lines(text)
        text.to_s.lines.map(&:chomp)
      end

      def normalize_text(text)
        text.to_s.gsub(/\r\n/, "\n").strip
      end
    end
  end
end
