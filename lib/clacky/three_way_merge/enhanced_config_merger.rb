# frozen_string_literal: true

require "json"
require "yaml"
require "set"

module Clacky
  module ThreeWayMerge
    # Enhanced configuration merger
    # Supports better array merge strategies, type coercion, comment preservation
    class EnhancedConfigMerger
      # Maximum merge depth
      MAX_MERGE_DEPTH = 50

      # Conflict value wrapper
      ConflictValue = Struct.new(:ours, :theirs, :path) do
        def to_s
          "<<<<<<< LOCAL: #{ours.inspect} | UPSTREAM: #{theirs.inspect} >>>>>>>"
        end
      end

      # Array merge strategies
      ARRAY_STRATEGIES = {
        append: :append,      # Append mode: keep all new elements
        replace: :replace,    # Replace mode: use new version
        merge_by_id: :merge_by_id # Merge by ID
      }.freeze

      # Initialize
      # @param format [Symbol] :json or :yaml
      # @param array_strategy [Symbol] Array merge strategy
      # @param type_coerce [Boolean] Whether to perform type coercion
      def initialize(format: :json, array_strategy: :append, type_coerce: true)
        @format = format
        @array_strategy = array_strategy
        @type_coerce = type_coerce
        @conflicts = []
      end

      # Merge configuration
      # @param base [String] Base version content
      # @param ours [String] Local version content
      # @param theirs [String] New version content
      # @return [ConfigMergeResult]
      def merge(base, ours, theirs)
        @conflicts = []

        base_config = parse(base)
        ours_config = parse(ours)
        theirs_config = parse(theirs)

        merged = deep_merge(base_config, ours_config, theirs_config, path: [], depth: 0)

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
      def self.config_file?(file_path)
        ext = File.extname(file_path).downcase
        %w[.json .yaml .yml .toml].include?(ext)
      end

      # Auto-detect format
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

        # Remove conflict markers, convert to serializable format
        clean_config = clean_for_serialization(config)

        case @format
        when :json
          JSON.pretty_generate(clean_config)
        when :yaml
          YAML.dump(clean_config)
        else
          JSON.pretty_generate(clean_config)
        end
      end

      def clean_for_serialization(obj)
        case obj
        when ConflictValue
          # Conflict value keeps ours
          obj.ours
        when Hash
          obj.transform_values { |v| clean_for_serialization(v) }
        when Array
          obj.map { |v| clean_for_serialization(v) }
        else
          obj
        end
      end

      def deep_merge(base, ours, theirs, path:, depth: 0)
        # Check recursion depth
        raise ArgumentError, "Merge depth exceeded limit (#{MAX_MERGE_DEPTH})" if depth > MAX_MERGE_DEPTH

        # Type coercion - convert types before comparison
        if @type_coerce && base
          ours = coerce_type(ours, base)
          theirs = coerce_type(theirs, base)
        end

        # All three are same
        return ours if values_equal?(base, ours) && values_equal?(base, theirs)

        # Only one side changed
        return theirs if values_equal?(base, ours)
        return ours if values_equal?(base, theirs)

        # Both sides made same changes
        return ours if values_equal?(ours, theirs)

        # Handle different types of merges
        if ours.is_a?(Hash) && theirs.is_a?(Hash)
          merge_hashes(base.is_a?(Hash) ? base : {}, ours, theirs, path:, depth:)
        elsif ours.is_a?(Array) && theirs.is_a?(Array)
          merge_arrays(base.is_a?(Array) ? base : [], ours, theirs, path:)
        else
          handle_conflict(ours, theirs, path)
        end
      end

      def merge_hashes(base, ours, theirs, path:, depth: 0)
        result = {}
        all_keys = (base.keys + ours.keys + theirs.keys).uniq

        all_keys.each do |key|
          current_path = path + [key]

          base_val = base[key]
          ours_val = ours[key]
          theirs_val = theirs[key]

          # New key
          unless base.key?(key)
            result[key] = if ours.key?(key) && theirs.key?(key)
                            deep_merge(nil, ours_val, theirs_val, path: current_path, depth: depth + 1)
                          elsif ours.key?(key)
                            ours_val
                          else
                            theirs_val
                          end
            next
          end

          # Deleted key
          next if !ours.key?(key) && !theirs.key?(key)

          unless ours.key?(key)
            next if values_equal?(base_val, theirs_val)

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
            next if values_equal?(base_val, ours_val)

            @conflicts << {
              path: current_path.join("."),
              ours: ours_val,
              theirs: nil,
              message: "New version deleted '#{key}', but local modified it"
            }
            result[key] = ConflictValue.new(ours_val, nil, current_path.join("."))

            next
          end

          result[key] = deep_merge(base_val, ours_val, theirs_val, path: current_path, depth: depth + 1)
        end

        result
      end

      def merge_arrays(base, ours, theirs, path:)
        # Neither changed
        return ours if values_equal?(base, ours) && values_equal?(base, theirs)

        # Only one side changed
        return theirs if values_equal?(base, ours)
        return ours if values_equal?(base, theirs)

        # Both sides made same changes
        return ours if values_equal?(ours, theirs)

        # Merge by strategy
        case @array_strategy
        when :append
          merge_arrays_append(base, ours, theirs, path:)
        when :replace
          merge_arrays_replace(base, ours, theirs, path:)
        when :merge_by_id
          merge_arrays_by_id(base, ours, theirs, path:)
        else
          merge_arrays_append(base, ours, theirs, path:)
        end
      end

      # Append mode: keep both sides' additions, respect both sides' deletions
      def merge_arrays_append(base, ours, theirs, path:)
        base_set = base.to_set

        # Find additions from each side
        ours_added = ours.reject { |item| base_set.include?(item) }
        theirs_added = theirs.reject { |item| base_set.include?(item) }

        # Find deletions from each side
        ours_deleted = base.reject { |item| ours.include?(item) }
        theirs_deleted = base.reject { |item| theirs.include?(item) }

        # If only one side deleted, keep deletion
        if ours_deleted.empty? && !theirs_deleted.empty?
          # Only theirs deleted, keep ours result
          return ours
        elsif !ours_deleted.empty? && theirs_deleted.empty?
          # Only ours deleted, keep theirs result
          return theirs
        end

        # Both sides deleted (possibly same items) - respect deletions
        # Start with items that both sides kept
        both_kept = base.select { |item| ours.include?(item) && theirs.include?(item) }

        # Add both sides' additions
        result = both_kept.dup
        result.concat(ours_added)
        result.concat(theirs_added)
        result.uniq
      end

      # Replace mode: use new version
      def merge_arrays_replace(_base, _ours, theirs, path:)
        theirs
      end

      # Merge by ID: for object arrays
      def merge_arrays_by_id(base, ours, theirs, path:)
        # Try to extract ID field
        id_field = detect_id_field(base)
        return merge_arrays_append(base, ours, theirs, path:) unless id_field

        # Index by ID
        base_by_id = index_by(base, id_field)
        ours_by_id = index_by(ours, id_field)
        theirs_by_id = index_by(theirs, id_field)

        result = []
        all_ids = (base_by_id.keys + ours_by_id.keys + theirs_by_id.keys).uniq

        all_ids.each do |id|
          base_item = base_by_id[id]
          ours_item = ours_by_id[id]
          theirs_item = theirs_by_id[id]

          if base_item.nil?
            # New addition
            result << (ours_item || theirs_item)
          elsif ours_item.nil?
            # Deleted locally, check if new version modified
            unless values_equal?(base_item, theirs_item)
              @conflicts << {
                path: "#{path.join(".")}.#{id}",
                ours: nil,
                theirs: theirs_item,
                message: "Local deleted item with ID=#{id}, but new version modified it"
              }
            end
          elsif theirs_item.nil?
            # Deleted by new version, check if local modified
            unless values_equal?(base_item, ours_item)
              @conflicts << {
                path: "#{path.join(".")}.#{id}",
                ours: ours_item,
                theirs: nil,
                message: "New version deleted item with ID=#{id}, but local modified it"
              }
              result << ours_item
            end
          else
            # Both exist, recursive merge
            merged = deep_merge(base_item, ours_item, theirs_item, path: path + [id.to_s], depth: 1)
            result << merged
          end
        end

        result
      end

      def detect_id_field(array)
        return nil if array.empty?

        first = array.first
        return nil unless first.is_a?(Hash)

        # Common ID field names
        %w[id ID _id uuid key name].each do |field|
          return field if first.key?(field)
        end

        nil
      end

      def index_by(array, id_field)
        result = {}
        array.each do |item|
          result[item[id_field]] = item if item.is_a?(Hash) && item.key?(id_field)
        end
        result
      end

      def handle_conflict(ours, theirs, path)
        @conflicts << {
          path: path.join("."),
          ours:,
          theirs:,
          message: "Value conflict at '#{path.join(".")}'"
        }
        ConflictValue.new(ours, theirs, path.join("."))
      end

      # Type coercion
      def coerce_type(value, reference)
        return value if value.nil? || reference.nil?
        return value if value.instance_of?(reference.class)

        case reference
        when Integer
          begin
            value.to_s.to_i
          rescue StandardError
            value
          end
        when Float
          begin
            value.to_s.to_f
          rescue StandardError
            value
          end
        when String
          value.to_s
        when TrueClass, FalseClass
          truthy?(value)
        else
          value
        end
      end

      def truthy?(value)
        return true if value == true
        return false if value == false
        return true if value.to_s.downcase == "true"
        return false if value.to_s.downcase == "false"

        !!value
      end

      def values_equal?(a, b)
        return true if a.nil? && b.nil?
        return false if a.nil? || b.nil?

        # Type coercion comparison
        if @type_coerce
          # Numeric comparison
          if a.is_a?(Numeric) || b.is_a?(Numeric)
            begin
              return (a.to_s.to_f - b.to_s.to_f).abs < Float::EPSILON
            rescue StandardError
              false
            end
          end
          # String comparison
          return a.to_s == b.to_s
        end

        if a.is_a?(Numeric) && b.is_a?(Numeric)
          a == b
        else
          a.to_s == b.to_s
        end
      end
    end
  end
end
