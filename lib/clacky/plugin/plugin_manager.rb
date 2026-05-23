# frozen_string_literal: true

require_relative "plugin"
require_relative "plugin_loader"
require_relative "plugin_context"

module Clacky
  module Plugin
    # Central manager for discovering, loading, and invoking plugins.
    #
    # Handles:
    #   - Plugin discovery and loading
    #   - Tool, hook, and command registration
    #   - Hot reload support
    #   - Plugin lifecycle management
    #
    # Usage:
    #   manager = PluginManager.new(working_dir: Dir.pwd)
    #   manager.discover_and_load
    #   manager.invoke_hook(:on_start, session_id: "abc")
    #
    class PluginManager
      # Extended hook events (beyond HookManager's defaults)
      VALID_HOOKS = %i[
        before_tool_use
        after_tool_use
        on_tool_error
        on_start
        on_complete
        on_iteration
        session_rollback
        pre_llm_call
        post_llm_call
        transform_output
        on_message
      ].freeze

      attr_reader :loader, :agent, :tool_registry
      attr_reader :plugin_tools, :plugin_hooks, :plugin_commands

      def initialize(working_dir: nil, agent: nil, tool_registry: nil)
        @working_dir = working_dir
        @agent = agent
        @tool_registry = tool_registry
        @loader = PluginLoader.new(working_dir: working_dir)

        # Plugin-provided extensions
        @plugin_tools = {}       # tool_name -> { tool:, plugin: }
        @plugin_hooks = {}       # event -> [{ callback:, plugin: }]
        @plugin_commands = {}    # command_name -> { handler:, plugin:, description: }

        # State tracking
        @discovered = false
        @loaded_modules = {}     # plugin_key -> loaded module
        @config_cache = nil
      end

      # -----------------------------------------------------------------------
      # Discovery and Loading
      # -----------------------------------------------------------------------

      # Discover and load all plugins.
      #
      # @param force [Boolean] Force rediscovery and reload
      def discover_and_load(force: false)
        return if @discovered && !force

        if force
          clear_registrations
        end

        @loader.discover(force: force)
        @discovered = true

        # Clean up config entries for deleted plugins
        cleanup_stale_plugin_configs

        # Load enabled plugins
        enabled_plugins = get_enabled_plugins
        disabled_plugins = get_disabled_plugins

        @loader.plugins.each do |key, plugin|
          # Check persisted enabled state first
          unless get_plugin_enabled_state(key)
            plugin.record_error("Disabled by user")
            next
          end

          # Check disabled list
          if disabled_plugins.include?(key) || disabled_plugins.include?(plugin.name)
            plugin.record_error("Disabled via config")
            next
          end

          # Check enabled list (if specified)
          if enabled_plugins && !enabled_plugins.include?(key) && !enabled_plugins.include?(plugin.name)
            plugin.record_error("Not in enabled list")
            next
          end

          # Check environment requirements
          unless plugin.env_satisfied?
            plugin.record_error("Missing env: #{plugin.missing_env.join(', ')}")
            next
          end

          load_plugin(plugin)
        end

        loaded_count = @loader.plugins.values.count(&:enabled)
        Clacky::Logger.info(
          "[PluginManager] Loaded #{loaded_count}/#{@loader.plugins.size} plugins"
        ) if @loader.plugins.any?
      end

      # Refresh plugin list without unloading running plugins.
      #
      # Only discovers new plugins and removes deleted ones.
      # Does NOT reload already-enabled plugins.
      def refresh
        Clacky::Logger.info("[PluginManager] Refreshing plugin list...")

        # Remember currently enabled plugins
        previously_enabled = @loader.plugins.values.select(&:enabled).map(&:key)

        # Rediscover plugins
        @loader.discover(force: true)
        @config_cache = nil

        # Clean up config entries for deleted plugins
        cleanup_stale_plugin_configs

        # Load any newly discovered plugins (that aren't already enabled)
        enabled_plugins = get_enabled_plugins
        disabled_plugins = get_disabled_plugins

        @loader.plugins.each do |key, plugin|
          # Skip already enabled plugins
          next if previously_enabled.include?(key)

          # Check persisted enabled state
          unless get_plugin_enabled_state(key)
            plugin.record_error("Disabled by user")
            next
          end

          # Check disabled list
          if disabled_plugins.include?(key) || disabled_plugins.include?(plugin.name)
            plugin.record_error("Disabled via config")
            next
          end

          # Check enabled list (if specified)
          if enabled_plugins && !enabled_plugins.include?(key) && !enabled_plugins.include?(plugin.name)
            plugin.record_error("Not in enabled list")
            next
          end

          # Check environment requirements
          unless plugin.env_satisfied?
            plugin.record_error("Missing env: #{plugin.missing_env.join(', ')}")
            next
          end

          load_plugin(plugin)
        end

        loaded_count = @loader.plugins.values.count(&:enabled)
        Clacky::Logger.info("[PluginManager] Refresh complete: #{loaded_count}/#{@loader.plugins.size} plugins enabled")
      end

      # Hot reload all plugins (full reload).
      #
      # Clears all registrations and reloads from disk.
      # WARNING: This will interrupt running plugins!
      def reload
        Clacky::Logger.info("[PluginManager] Hot reloading all plugins...")

        # Unload all plugins
        @loader.plugins.values.each do |plugin|
          unload_plugin(plugin) if plugin.enabled
        end

        # Clear state
        clear_registrations
        @loaded_modules.clear
        @discovered = false
        @config_cache = nil

        # Rediscover and load (will check persisted enabled state from config)
        discover_and_load(force: true)
      end

      # -----------------------------------------------------------------------
      # Plugin Loading
      # -----------------------------------------------------------------------

      # Load a single plugin.
      #
      # @param plugin [Plugin] Plugin to load
      # @return [Boolean] True if loaded successfully
      def load_plugin(plugin)
        return false unless plugin.valid?
        return true if plugin.enabled

        unless plugin.has_entry?
          # Plugin without entry file - just mark as enabled
          plugin.enabled = true
          Clacky::Logger.debug("[PluginManager] Plugin '#{plugin.display_name}' enabled (no entry file)")
          return true
        end

        begin
          entry_path = plugin.entry_path.to_s

          # Load the plugin file
          plugin_module = load_plugin_file(entry_path, plugin)
          return false unless plugin_module

          @loaded_modules[plugin.key] = plugin_module

          # Call register(ctx) if defined
          ctx = PluginContext.new(plugin, self)

          if plugin_module.respond_to?(:register)
            plugin_module.register(ctx)
          elsif plugin_module.instance_methods(false).include?(:register)
            obj = Object.new
            obj.extend(plugin_module)
            obj.register(ctx)
          end

          plugin.enabled = true
          plugin.clear_error
          Clacky::Logger.info("[PluginManager] Loaded plugin: #{plugin.display_name}")
          true

        rescue StandardError => e
          plugin.record_error("Load failed: #{e.message}")
          Clacky::Logger.error(
            "[PluginManager] Failed to load '#{plugin.display_name}': #{e.message}",
            error: e
          )
          false
        end
      end

      # Unload a plugin.
      #
      # @param plugin [Plugin] Plugin to unload
      def unload_plugin(plugin, timeout: 5)
        return unless plugin.enabled

        plugin_module = @loaded_modules[plugin.key]
        if plugin_module
          # Check if plugin is busy and wait
          if plugin_module.respond_to?(:busy?) && plugin_module.busy?
            Clacky::Logger.info("[PluginManager] Waiting for #{plugin.display_name} to finish tasks...")
            deadline = Time.now + timeout
            while plugin_module.busy? && Time.now < deadline
              sleep 0.1
            end
            if plugin_module.busy?
              Clacky::Logger.warn("[PluginManager] #{plugin.display_name} still busy after #{timeout}s, forcing unload")
            end
          end

          # Call unload() if defined
          if plugin_module.respond_to?(:unload)
            begin
              plugin_module.unload
              Clacky::Logger.debug("[PluginManager] Called unload() for: #{plugin.display_name}")
            rescue StandardError => e
              Clacky::Logger.warn("[PluginManager] unload() failed for #{plugin.display_name}: #{e.message}")
            end
          end
        end

        # Remove registered tools
        plugin.tools_registered.each do |tool_name|
          @plugin_tools.delete(tool_name)
        end

        # Remove registered hooks
        plugin.hooks_registered.each do |hook_name|
          event = hook_name.to_sym
          @plugin_hooks[event]&.reject! { |h| h[:plugin] == plugin }
        end

        # Remove registered commands
        plugin.commands_registered.each do |cmd_name|
          @plugin_commands.delete(cmd_name)
        end

        # Clear plugin state
        plugin.tools_registered.clear
        plugin.hooks_registered.clear
        plugin.commands_registered.clear
        plugin.enabled = false

        # Remove loaded module
        @loaded_modules.delete(plugin.key)

        Clacky::Logger.debug("[PluginManager] Unloaded plugin: #{plugin.display_name}")
      end

      # Disable a plugin by key.
      #
      # @param key [String] Plugin key
      # @return [Boolean] True if disabled successfully
      def disable_plugin(key)
        plugin = @loader.plugins[key]
        return false unless plugin

        unload_plugin(plugin) if plugin.enabled
        plugin.record_error("Disabled by user")
        save_plugin_enabled_state(key, false)
        Clacky::Logger.info("[PluginManager] Disabled plugin: #{plugin.display_name}")
        true
      end

      # Enable a plugin by key.
      #
      # @param key [String] Plugin key
      # @return [Boolean] True if enabled successfully
      def enable_plugin(key)
        plugin = @loader.plugins[key]
        return false unless plugin

        plugin.clear_error
        result = load_plugin(plugin)
        save_plugin_enabled_state(key, true) if result
        Clacky::Logger.info("[PluginManager] Enabled plugin: #{plugin.display_name}") if result
        result
      end

      # Save plugin enabled state to config file
      def save_plugin_enabled_state(key, enabled)
        config_path = config_file_path
        config = if File.exist?(config_path)
          YAMLCompat.safe_load(File.read(config_path), permitted_classes: [Symbol]) || {}
        else
          {}
        end

        config["plugins"] ||= {}
        config["plugins"][key] ||= {}
        config["plugins"][key]["enabled"] = enabled

        FileUtils.mkdir_p(File.dirname(config_path))
        File.write(config_path, YAML.dump(config))
        reload_config
      end

      # Get plugin enabled state from config file
      def get_plugin_enabled_state(key)
        load_config unless @config_cache
        enabled = @config_cache.dig("plugins", key, "enabled")
        # Default to true if not explicitly set
        enabled.nil? ? true : enabled
      end

      # Clean up config entries for plugins that no longer exist
      def cleanup_stale_plugin_configs
        load_config unless @config_cache
        return unless @config_cache["plugins"]

        existing_keys = @loader.plugins.keys
        stale_keys = @config_cache["plugins"].keys - existing_keys

        return if stale_keys.empty?

        config_path = config_file_path
        return unless File.exist?(config_path)

        config = YAMLCompat.safe_load(File.read(config_path), permitted_classes: [Symbol]) || {}
        return unless config["plugins"]

        stale_keys.each do |key|
          config["plugins"].delete(key)
          Clacky::Logger.debug("[PluginManager] Cleaned up stale config for: #{key}")
        end

        File.write(config_path, YAML.dump(config))
        reload_config
      end

      # -----------------------------------------------------------------------
      # Registration (called by PluginContext)
      # -----------------------------------------------------------------------

      # Register a tool provided by a plugin.
      def register_plugin_tool(tool, plugin:)
        tool_name = tool.name.to_s
        @plugin_tools[tool_name] = { tool: tool, plugin: plugin }

        # Also register in the main tool registry if available
        @tool_registry&.register(tool)
      end

      # Register a hook callback provided by a plugin.
      def register_plugin_hook(event, callback, plugin:)
        @plugin_hooks[event] ||= []
        @plugin_hooks[event] << { callback: callback, plugin: plugin }
      end

      # Register a command provided by a plugin.
      def register_plugin_command(name, handler, description:, plugin:, args_hint: "")
        @plugin_commands[name] = {
          handler: handler,
          plugin: plugin,
          description: description,
          args_hint: args_hint.to_s.strip
        }
      end

      # Register a platform adapter provided by a plugin.
      def register_plugin_platform(name, label:, adapter_class:, check_fn:, plugin:, **options)
        @plugin_platforms ||= {}
        @plugin_platforms[name] = {
          name: name,
          label: label,
          adapter_class: adapter_class,
          check_fn: check_fn,
          plugin: plugin,
          required_env: options[:required_env] || [],
          install_hint: options[:install_hint] || "",
          emoji: options[:emoji] || ""
        }
      end

      # Get all registered platform adapters.
      def plugin_platforms
        @plugin_platforms ||= {}
      end

      # -----------------------------------------------------------------------
      # Hook Invocation
      # -----------------------------------------------------------------------

      # Check if a hook event is valid.
      def valid_hook?(event)
        VALID_HOOKS.include?(event.to_sym)
      end

      # Get list of valid hooks.
      def valid_hooks
        VALID_HOOKS
      end

      # Invoke all registered callbacks for a hook.
      #
      # @param event [Symbol] Hook event name
      # @param kwargs [Hash] Arguments to pass to callbacks
      # @return [Hash] Combined results from all callbacks
      def invoke_hook(event, **kwargs)
        result = { action: :allow }
        callbacks = @plugin_hooks[event.to_sym] || []

        callbacks.each do |entry|
          begin
            hook_result = entry[:callback].call(**kwargs)
            result.merge!(hook_result) if hook_result.is_a?(Hash)
          rescue StandardError => e
            Clacky::Logger.warn(
              "[PluginManager] Hook error in '#{entry[:plugin].display_name}' for #{event}: #{e.message}"
            )
          end
        end

        result
      end

      # -----------------------------------------------------------------------
      # Command Dispatch
      # -----------------------------------------------------------------------

      # Get a plugin command by name.
      #
      # @param name [String] Command name
      # @return [Hash, nil] Command entry or nil
      def get_command(name)
        @plugin_commands[name.to_s.downcase]
      end

      # Execute a plugin command.
      #
      # @param name [String] Command name
      # @param args [String] Arguments string
      # @param context [Hash] Execution context
      # @return [String, nil] Command result
      def execute_command(name, args, context: {})
        cmd = get_command(name)
        return nil unless cmd

        begin
          handler = cmd[:handler]
          # Support handlers with 1 or 2 parameters
          if handler.arity == 1 || handler.arity == -1
            handler.call(args)
          else
            handler.call(args, context)
          end
        rescue StandardError => e
          Clacky::Logger.error(
            "[PluginManager] Command '#{name}' failed: #{e.message}"
          )
          "Error: #{e.message}"
        end
      end

      # List all plugin commands.
      #
      # @return [Array<Hash>] Command entries with :name, :description, :args_hint, :plugin
      def list_commands
        @plugin_commands.map do |name, entry|
          {
            name: name,
            description: entry[:description],
            args_hint: entry[:args_hint] || "",
            plugin: entry[:plugin].display_name
          }
        end
      end

      # -----------------------------------------------------------------------
      # Configuration
      # -----------------------------------------------------------------------

      # Get plugin-specific configuration.
      #
      # @param plugin_name [String] Plugin name
      # @return [Hash] Plugin configuration
      def get_plugin_config(plugin_name)
        load_config unless @config_cache
        @config_cache.dig("plugins", plugin_name) || {}
      end

      # Reload configuration cache.
      def reload_config
        @config_cache = nil
        load_config
      end

      # -----------------------------------------------------------------------
      # Accessors
      # -----------------------------------------------------------------------

      # Set the agent reference (for PluginContext access).
      def agent=(agent)
        @agent = agent
      end

      # Set the tool registry reference.
      def tool_registry=(registry)
        @tool_registry = registry
      end

      # Get all loaded plugins.
      def plugins
        @loader.plugins
      end

      # Get a plugin by key.
      def get_plugin(key)
        @loader.get(key)
      end

      # Get the config file path
      def config_file_path
        paths = []
        if @working_dir
          paths << File.join(@working_dir, ".clacky", "config.yml")
          paths << File.join(@working_dir, ".clacky", "config.yaml")
        end
        paths << File.expand_path("~/.clacky/config.yml")
        paths << File.expand_path("~/.clacky/config.yaml")

        paths.find { |p| File.exist?(p) } || paths.first
      end

      # Save plugin config to file
      def save_plugin_config(plugin_name, config)
        path = config_file_path
        full_config = File.exist?(path) ? YAML.load_file(path) || {} : {}
        full_config["plugins"] ||= {}
        full_config["plugins"][plugin_name] = config
        File.write(path, YAML.dump(full_config))
        reload_config
      end

      # Load a plugin file and return the module.
      private def load_plugin_file(path, plugin)
        # Create a new module to contain the plugin code
        plugin_module = Module.new

        # Load the file content
        code = File.read(path)

        # Evaluate in the module context
        # Use class_eval to allow def self.register to work
        plugin_module.class_eval(code, path, 1)

        plugin_module
      rescue SyntaxError => e
        plugin.record_error("Syntax error: #{e.message}")
        nil
      rescue StandardError => e
        plugin.record_error("Load error: #{e.message}")
        nil
      end

      # Clear all plugin registrations.
      private def clear_registrations
        @plugin_tools.clear
        @plugin_hooks.clear
        @plugin_commands.clear
        @plugin_platforms&.clear
      end

      # Load configuration from config.yaml.
      private def load_config
        @config_cache = {}

        config_paths = [
          File.expand_path("~/.clacky/config.yaml"),
          File.expand_path("~/.clacky/config.yml")
        ]

        if @working_dir
          config_paths.unshift(File.join(@working_dir, ".clacky", "config.yaml"))
          config_paths.unshift(File.join(@working_dir, ".clacky", "config.yml"))
        end

        config_paths.each do |path|
          if File.exist?(path)
            @config_cache = YAML.safe_load(File.read(path), permitted_classes: [Symbol]) || {}
            break
          end
        end

        @config_cache
      end

      # Get list of enabled plugins from config.
      private def get_enabled_plugins
        load_config unless @config_cache
        enabled = @config_cache.dig("plugins", "enabled")
        enabled.is_a?(Array) ? Set.new(enabled) : nil
      end

      # Get list of disabled plugins from config.
      private def get_disabled_plugins
        load_config unless @config_cache
        disabled = @config_cache.dig("plugins", "disabled") || []
        Set.new(disabled)
      end
    end
  end
end
