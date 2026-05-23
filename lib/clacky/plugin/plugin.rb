# frozen_string_literal: true

require "yaml"
require "pathname"

module Clacky
  module Plugin
    # Represents a single plugin with its manifest and runtime state.
    #
    # A plugin is defined by a `plugin.yaml` manifest file and optionally
    # an `init.rb` entry point that calls register(ctx) to register
    # tools, hooks, and other extensions.
    class Plugin
      # Valid plugin kinds
      VALID_KINDS = %w[standalone backend platform provider].freeze

      # Manifest fields
      attr_reader :name, :version, :description, :author
      attr_reader :kind, :key, :path
      attr_reader :entry_file, :requires_env
      attr_reader :provides_tools, :provides_hooks

      # Runtime state
      attr_reader :module_instance, :error
      attr_accessor :enabled
      attr_reader :tools_registered, :hooks_registered, :commands_registered

      def initialize(manifest_path, prefix: "")
        @manifest_path = Pathname.new(manifest_path)
        @path = @manifest_path.dirname
        @prefix = prefix

        # Runtime state
        @enabled = false
        @module_instance = nil
        @error = nil
        @tools_registered = []
        @hooks_registered = []
        @commands_registered = []

        parse_manifest
      end

      def directory
        @path
      end

      # Check if plugin is valid (no parse errors)
      def valid?
        @error.nil?
      end

      # Check if plugin has an entry file
      def has_entry?
        entry_path.exist?
      end

      # Get full path to entry file
      def entry_path
        @path.join(@entry_file || "init.rb")
      end

      # Human-readable identifier for logging
      def display_name
        @key.empty? ? @name : @key
      end

      # Check if a required environment variable is set
      def env_satisfied?
        return true if @requires_env.empty?

        @requires_env.all? do |env_spec|
          case env_spec
          when String
            ENV[env_spec] && !ENV[env_spec].empty?
          when Hash
            env_name = env_spec["name"] || env_spec[:name]
            ENV[env_name] && !ENV[env_name].empty?
          else
            true
          end
        end
      end

      # Get missing environment variables
      def missing_env
        @requires_env.select do |env_spec|
          env_name = env_spec.is_a?(Hash) ? (env_spec["name"] || env_spec[:name]) : env_spec
          !ENV[env_name] || ENV[env_name].empty?
        end.map do |env_spec|
          env_spec.is_a?(Hash) ? (env_spec["name"] || env_spec[:name]) : env_spec
        end
      end

      # Record an error
      def record_error(message)
        @error = message
        @enabled = false
      end

      # Clear error state
      def clear_error
        @error = nil
      end

      # To hash for serialization
      def to_h
        {
          name: @name,
          version: @version,
          description: @description,
          kind: @kind,
          key: @key,
          path: @path.to_s,
          enabled: @enabled,
          error: @error,
          tools_registered: @tools_registered,
          hooks_registered: @hooks_registered,
          commands_registered: @commands_registered
        }
      end

      private

      def parse_manifest
        unless @manifest_path.exist?
          @error = "Manifest file not found: #{@manifest_path}"
          return
        end

        begin
          data = YAML.safe_load(@manifest_path.read, permitted_classes: [Symbol]) || {}

          @name = data["name"] || @path.basename.to_s
          @version = data["version"] || "0.0.0"
          @description = data["description"] || ""
          @author = data["author"] || ""
          @entry_file = data["entry"] || "init.rb"
          @requires_env = Array(data["requires_env"] || [])
          @provides_tools = Array(data["provides_tools"] || data["tools"] || [])
          @provides_hooks = Array(data["provides_hooks"] || data["hooks"] || [])

          # Parse kind
          raw_kind = data["kind"] || "standalone"
          @kind = VALID_KINDS.include?(raw_kind.to_s.downcase) ? raw_kind.to_s.downcase : "standalone"

          # Compute key (used for enable/disable lookups)
          @key = @prefix.empty? ? @name : "#{@prefix}/#{@path.basename}"

        rescue Psych::SyntaxError => e
          @error = "YAML parse error: #{e.message}"
          @name = @path.basename.to_s
          @version = "0.0.0"
          @kind = "standalone"
          @key = @name
        rescue StandardError => e
          @error = "Failed to parse manifest: #{e.message}"
          @name = @path.basename.to_s
          @version = "0.0.0"
          @kind = "standalone"
          @key = @name
        end
      end
    end
  end
end
