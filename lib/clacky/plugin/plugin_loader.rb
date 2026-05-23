# frozen_string_literal: true

require "pathname"
require_relative "plugin"

module Clacky
  module Plugin
    # Discovers plugins from the data directory.
    #
    # Plugin directory: ~/.clacky/plugins/
    #
    # Each plugin directory must contain a plugin.yaml manifest.
    class PluginLoader
      attr_reader :plugins, :errors

      def initialize(working_dir: nil)
        @plugins = {}      # key -> Plugin
        @errors = []       # Loading errors
      end

      # Discover all plugins from configured locations.
      #
      # @param force [Boolean] Force rediscovery even if already done
      # @return [Hash<String, Plugin>] Discovered plugins by key
      def discover(force: false)
        return @plugins if @plugins.any? && !force

        @plugins.clear
        @errors.clear

        # Scan plugin directory (~/.clacky/plugins/)
        plugins_dir = Pathname.new(File.join(Dir.home, ".clacky", "plugins"))
        scan_directory(plugins_dir) if plugins_dir.exist?

        Clacky::Logger.info(
          "[PluginLoader] Discovery complete: #{@plugins.size} plugins found"
        ) if @plugins.any?

        @plugins
      end

      # Reload plugins (for hot reload).
      #
      # @return [Hash<String, Plugin>] Reloaded plugins
      def reload
        discover(force: true)
      end

      # Get a plugin by key or name.
      #
      # @param identifier [String] Plugin key or name
      # @return [Plugin, nil] Found plugin or nil
      def get(identifier)
        @plugins[identifier] || @plugins.values.find { |p| p.name == identifier }
      end

      # List all discovered plugins.
      #
      # @param enabled_only [Boolean] Only return enabled plugins
      # @return [Array<Plugin>] Matching plugins
      def list(enabled_only: false)
        result = @plugins.values
        result = result.select(&:enabled) if enabled_only
        result
      end

      private

      # Scan a directory for plugins.
      #
      # Supports two layouts:
      #   - Flat: <dir>/<plugin-name>/plugin.yaml
      #   - Category: <dir>/<category>/<plugin-name>/plugin.yaml
      #
      # @param dir [Pathname] Directory to scan
      # @param prefix [String] Category prefix for nested plugins
      # @param depth [Integer] Current recursion depth (max 2)
      def scan_directory(dir, prefix: "", depth: 0)
        return unless dir.exist? && dir.directory?

        dir.children.select(&:directory?).sort.each do |child|
          manifest_path = child.join("plugin.yaml")
          manifest_path = child.join("plugin.yml") unless manifest_path.exist?

          if manifest_path.exist?
            # Found a plugin
            plugin = Plugin.new(manifest_path, prefix: prefix)
            register_plugin(plugin)
          elsif depth < 1
            # No manifest, treat as category and recurse one level
            sub_prefix = prefix.empty? ? child.basename.to_s : "#{prefix}/#{child.basename}"
            scan_directory(child, prefix: sub_prefix, depth: depth + 1)
          end
        end
      end

      # Register a discovered plugin.
      #
      # Later sources override earlier ones on key collision.
      #
      # @param plugin [Plugin] Plugin to register
      def register_plugin(plugin)
        key = plugin.key

        if @plugins.key?(key)
          Clacky::Logger.debug("[PluginLoader] Plugin '#{key}' overridden by later definition")
        end

        @plugins[key] = plugin

        if plugin.error
          @errors << { key: key, error: plugin.error }
          Clacky::Logger.warn("[PluginLoader] Plugin '#{key}' has error: #{plugin.error}")
        else
          Clacky::Logger.debug("[PluginLoader] Discovered plugin: #{key}")
        end
      end
    end
  end
end
