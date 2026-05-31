# frozen_string_literal: true

require "json"
require "yaml"
require "set"

module Clacky
  module ThreeWayMerge
    # Configuration merge result
    ConfigMergeResult = Struct.new(:status, :content, :conflicts, :merged_config, keyword_init: true) do
      def success?
        status == :auto_merged
      end

      def has_conflicts?
        status == :has_conflicts
      end

      def error?
        status == :error
      end
    end

    # Parse error for invalid configuration content
    class ParseError < StandardError; end

    # Configuration file merger
    # Supports structured merging for JSON and YAML formats
    class ConfigMerger
      # Conflict value wrapper
      ConflictValue = Struct.new(:ours, :theirs, :path) do
        def to_s
          "<<<<<<< LOCAL: #{ours.inspect} | UPSTREAM: #{theirs.inspect} >>>>>>>"
        end
      end

      # Initialize configuration merger
      # @param format [Symbol] :json or :yaml
      def initialize(format: :json)
        @format = format
        @conflicts = []
      end

      # Merge configuration content
      # @param base [String] Base version content
      # @param ours [String] Local version content
      # @param theirs [String] New version content
      # @return [ConfigMergeResult] Merge result
      def merge(base, ours, theirs)
        @conflicts = []

        base_config = parse(base)
        ours_config = parse(ours)
        theirs_config = parse(theirs)

        merged = deep_merge(base_config, ours_config, theirs_config, path: [])

        ConfigMergeResult.new(
          status: @conflicts.empty? ? :auto_merged : :has_conflicts,
          content: serialize(merged),
          conflicts: @conflicts.dup,
          merged_config: merged
        )
      rescue ParseError => e
        ConfigMergeResult.new(
          status: :error,
          content: nil,
          conflicts: [e.message],
          merged_config: nil
        )
      end

      # Check if file is a configuration file
      # @param file_path [String]
      # @return [Boolean]
      def self.config_file?(file_path)
        ext = File.extname(file_path).downcase
        %w[.json .yaml .yml .toml].include?(ext)
      end

      # Auto-detect format
      # @param file_path [String]
      # @return [Symbol]
      def self.detect_format(file_path)
        case File.extname(file_path).downcase
        when ".json" then :json
        when ".yaml", ".yml" then :yaml
        when ".toml" then :toml
        else :json
        end
      end

      private

      def parse(content)
        return {} if content.nil? || content.strip.empty?

        case @format
        when :json
          JSON.parse(content)
        when :yaml
          YAML.safe_load(content, permitted_classes: [Symbol, Date, Time]) || {}
        else
          JSON.parse(content)
        end
      rescue JSON::ParserError, Psych::SyntaxError => e
        raise ParseError, "#{@format} parse error: #{e.message}"
      end

      def serialize(config)
        return "" if config.nil?

        case @format
        when :json
          JSON.pretty_generate(config)
        when :yaml
          YAML.dump(config)
        else
          JSON.pretty_generate(config)
        end
      end

      # Recursive deep merge
      # @param base [Hash, Array, Object] Base value
      # @param ours [Hash, Array, Object] Local value
      # @param theirs [Hash, Array, Object] New version value
      # @param path [Array] Current path (for conflict reporting)
      # @return [Hash, Array, Object] Merged value
      def deep_merge(base, ours, theirs, path:)
        # All three are identical
        return ours if values_equal?(base, ours) && values_equal?(base, theirs)

        # Only one side changed
        return theirs if values_equal?(base, ours) # Local unchanged, use new version
        return ours if values_equal?(base, theirs) # New version unchanged, use local

        # Both sides made identical changes
        return ours if values_equal?(ours, theirs)

        # Handle different types of merges
        if ours.is_a?(Hash) && theirs.is_a?(Hash)
          merge_hashes(base.is_a?(Hash) ? base : {}, ours, theirs, path:)
        elsif ours.is_a?(Array) && theirs.is_a?(Array)
          merge_arrays(base.is_a?(Array) ? base : [], ours, theirs, path:)
        else
          # Primitive type conflict
          handle_conflict(ours, theirs, path)
        end
      end

      # Merge two Hashes
      def merge_hashes(base, ours, theirs, path:)
        result = {}
        all_keys = (base.keys + ours.keys + theirs.keys).uniq

        all_keys.each do |key|
          current_path = path + [key]

          base_val = base[key]
          ours_val = ours[key]
          theirs_val = theirs[key]

          # New key added
          unless base.key?(key)
            result[key] = if ours.key?(key) && theirs.key?(key)
                            # Both sides added the same key
                            deep_merge(nil, ours_val, theirs_val, path: current_path)
                          elsif ours.key?(key)
                            ours_val
                          else
                            theirs_val
                          end
            next
          end

          # Deleted key
          if !ours.key?(key) && !theirs.key?(key)
            # Both sides deleted
            next
          end

          unless ours.key?(key)
            # Local deleted
            next if values_equal?(base_val, theirs_val)

            # New version unchanged, keep deletion

            # New version modified, conflict
            @conflicts << {
              path: current_path.join("."),
              ours: nil,
              theirs: theirs_val,
              message: "Local deleted '#{key}', but new version modified it"
            }
            result[key] = ConflictValue.new(nil, theirs_val, current_path.join("."))

            next
          end

          unless theirs.key?(key)
            # New version deleted
            next if values_equal?(base_val, ours_val)

            # Local unchanged, keep deletion

            # Local modified, conflict
            @conflicts << {
              path: current_path.join("."),
              ours: ours_val,
              theirs: nil,
              message: "New version deleted '#{key}', but local modified it"
            }
            result[key] = ConflictValue.new(ours_val, nil, current_path.join("."))

            next
          end

          # Both sides exist, recursive merge
          result[key] = deep_merge(base_val, ours_val, theirs_val, path: current_path)
        end

        result
      end

      # Merge two Arrays
      def merge_arrays(base, ours, theirs, path:)
        # Simple strategy: if both sides changed, prefer new version
        if values_equal?(base, ours)
          theirs
        elsif values_equal?(base, theirs)
          ours
        elsif values_equal?(ours, theirs)
          ours
        else
          # Array conflict: attempt smart merge
          # If only appended elements, can merge
          base_set = base.to_set
          ours_added = ours.reject { |item| base_set.include?(item) }
          theirs_added = theirs.reject { |item| base_set.include?(item) }

          # If only append operations, merge both sides' additions
          return (base + ours_added + theirs_added).uniq if (base - ours).empty? && (base - theirs).empty?

          # Otherwise mark conflict
          @conflicts << {
            path: path.join("."),
            ours:,
            theirs:,
            message: "Array '#{path.last}' modified by both sides"
          }
          ConflictValue.new(ours, theirs, path.join("."))
        end
      end

      # Handle primitive type conflict
      def handle_conflict(ours, theirs, path)
        @conflicts << {
          path: path.join("."),
          ours:,
          theirs:,
          message: "Value conflict at '#{path.join(".")}'"
        }
        ConflictValue.new(ours, theirs, path.join("."))
      end

      # Compare two values for equality
      # Note: Type-aware comparison - different types are not equal
      def values_equal?(a, b)
        return true if a.nil? && b.nil?
        return false if a.nil? || b.nil?

        # Different types are not equal (e.g., 42 != "42")
        return false unless a.class == b.class || (a.is_a?(Numeric) && b.is_a?(Numeric))

        if a.is_a?(Numeric) && b.is_a?(Numeric)
          a == b
        else
          a == b
        end
      end
    end
  end
end
