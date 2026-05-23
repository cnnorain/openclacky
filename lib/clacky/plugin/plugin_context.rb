# frozen_string_literal: true

module Clacky
  module Plugin
    # API facade provided to plugins during registration.
    #
    # Plugins receive a PluginContext instance in their register(ctx) function
    # and use it to register tools, hooks, commands, and other extensions.
    #
    # Example usage in init.rb:
    #
    #   def register(ctx)
    #     ctx.add_tool(MyCustomTool.new)
    #     ctx.add_hook(:before_tool_use) { |name, args| puts "Calling #{name}" }
    #   end
    #
    class PluginContext
      attr_reader :plugin, :manager

      def initialize(plugin, manager)
        @plugin = plugin
        @manager = manager
      end

      # -----------------------------------------------------------------------
      # Tool Registration
      # -----------------------------------------------------------------------

      # Register a custom tool.
      #
      # @param tool [Object] Tool instance with #name, #execute, #to_function_definition
      # @param override [Boolean] If true, replace existing tool with same name
      # @return [Boolean] True if registered successfully
      def add_tool(tool, override: false)
        unless tool.respond_to?(:name) && tool.respond_to?(:execute)
          Clacky::Logger.warn(
            "[Plugin:#{@plugin.display_name}] Tool must respond to #name and #execute"
          )
          return false
        end

        tool_name = tool.name.to_s

        # Check for existing tool
        if @manager.tool_registry&.resolve(tool_name) && !override
          Clacky::Logger.warn(
            "[Plugin:#{@plugin.display_name}] Tool '#{tool_name}' already exists. " \
            "Use override: true to replace."
          )
          return false
        end

        @manager.register_plugin_tool(tool, plugin: @plugin)
        @plugin.tools_registered << tool_name
        Clacky::Logger.info("[Plugin:#{@plugin.display_name}] Registered tool: #{tool_name}")
        true
      end

      # -----------------------------------------------------------------------
      # Hook Registration
      # -----------------------------------------------------------------------

      # Register a lifecycle hook callback.
      #
      # Valid hooks:
      #   - :before_tool_use
      #   - :after_tool_use
      #   - :on_tool_error
      #   - :on_start
      #   - :on_complete
      #   - :on_iteration
      #   - :pre_llm_call
      #   - :post_llm_call
      #   - :transform_output
      #
      # @param event [Symbol] Hook event name
      # @param block [Proc] Callback to execute
      # @return [Boolean] True if registered successfully
      def add_hook(event, &block)
        unless block_given?
          Clacky::Logger.warn(
            "[Plugin:#{@plugin.display_name}] add_hook requires a block"
          )
          return false
        end

        event_sym = event.to_sym

        # Warn about unknown hooks but still register (forward compatibility)
        unless @manager.valid_hook?(event_sym)
          Clacky::Logger.warn(
            "[Plugin:#{@plugin.display_name}] Unknown hook '#{event}'. " \
            "Valid hooks: #{@manager.valid_hooks.join(', ')}"
          )
        end

        @manager.register_plugin_hook(event_sym, block, plugin: @plugin)
        @plugin.hooks_registered << event_sym.to_s
        Clacky::Logger.debug("[Plugin:#{@plugin.display_name}] Registered hook: #{event}")
        true
      end

      # -----------------------------------------------------------------------
      # Command Registration
      # -----------------------------------------------------------------------

      # Register a slash command (e.g., /mycommand).
      #
      # Commands are available in CLI and gateway sessions. The handler receives
      # the raw argument string and returns a response string.
      #
      # @param name [String] Command name (without leading /)
      # @param description [String] Help text for the command
      # @param args_hint [String] Optional argument hint (e.g., "<file>" or "days:7")
      # @param handler [Proc] Handler that receives (args_string) and returns String
      # @return [Boolean] True if registered successfully
      def add_command(name, description: "", args_hint: "", &handler)
        unless block_given?
          Clacky::Logger.warn(
            "[Plugin:#{@plugin.display_name}] add_command requires a block handler"
          )
          return false
        end

        clean_name = name.to_s.downcase.strip.delete_prefix("/").tr(" ", "-")
        if clean_name.empty?
          Clacky::Logger.warn(
            "[Plugin:#{@plugin.display_name}] Command name cannot be empty"
          )
          return false
        end

        @manager.register_plugin_command(
          clean_name,
          handler,
          description: description,
          args_hint: args_hint,
          plugin: @plugin
        )
        @plugin.commands_registered << clean_name
        Clacky::Logger.info("[Plugin:#{@plugin.display_name}] Registered command: /#{clean_name}")
        true
      end

      # -----------------------------------------------------------------------
      # Tool Dispatch
      # -----------------------------------------------------------------------

      # Dispatch a tool call through the registry.
      #
      # This allows plugins to call registered tools (built-in or plugin-provided)
      # without accessing framework internals directly.
      #
      # @param tool_name [String] Name of the tool to call
      # @param args [Hash] Arguments to pass to the tool
      # @return [String, nil] Tool result or nil if tool not found
      def dispatch_tool(tool_name, args = {})
        registry = @manager.tool_registry
        unless registry
          log(:warn, "Tool registry not available")
          return nil
        end

        tool = registry.resolve(tool_name)
        unless tool
          log(:warn, "Tool '#{tool_name}' not found")
          return nil
        end

        begin
          tool.execute(args)
        rescue StandardError => e
          log(:error, "Tool '#{tool_name}' failed: #{e.message}")
          nil
        end
      end

      # -----------------------------------------------------------------------
      # Platform Adapter Registration
      # -----------------------------------------------------------------------

      # Register a gateway platform adapter.
      #
      # Platform adapters enable the agent to communicate through different
      # channels (Telegram, Discord, Slack, etc.).
      #
      # @param name [String] Platform identifier (e.g., "telegram", "discord")
      # @param label [String] Display name (e.g., "Telegram", "Discord")
      # @param adapter_class [Class] Adapter class that handles platform communication
      # @param check_fn [Proc] Function to verify dependencies are available
      # @param options [Hash] Additional options:
      #   - :required_env [Array<String>] Required environment variables
      #   - :install_hint [String] Installation instructions
      #   - :emoji [String] Platform emoji icon
      # @return [Boolean] True if registered successfully
      def add_platform(name, label:, adapter_class:, check_fn: nil, **options)
        clean_name = name.to_s.downcase.strip.tr(" ", "-")
        if clean_name.empty?
          log(:warn, "Platform name cannot be empty")
          return false
        end

        unless adapter_class.is_a?(Class)
          log(:warn, "adapter_class must be a Class")
          return false
        end

        @manager.register_plugin_platform(
          clean_name,
          label: label,
          adapter_class: adapter_class,
          check_fn: check_fn,
          plugin: @plugin,
          **options
        )
        log(:info, "Registered platform: #{clean_name}")
        true
      end

      # -----------------------------------------------------------------------
      # Configuration Access
      # -----------------------------------------------------------------------

      # Get plugin-specific configuration from config.yaml.
      #
      # Looks up: plugins.<plugin_name>.<key>
      #
      # @param key [String, Symbol] Configuration key
      # @param default [Object] Default value if not found
      # @return [Object] Configuration value
      def config(key = nil, default: nil)
        plugin_config = @manager.get_plugin_config(@plugin.name)
        return plugin_config if key.nil?

        plugin_config.dig(key.to_s) || default
      end

      # -----------------------------------------------------------------------
      # Agent Access (read-only)
      # -----------------------------------------------------------------------

      # Get the current working directory.
      #
      # @return [String, nil] Working directory path
      def working_dir
        @manager.agent&.working_dir
      end

      # Get the current session ID.
      #
      # @return [String, nil] Session ID
      def session_id
        @manager.agent&.session_id
      end

      # -----------------------------------------------------------------------
      # Utility Methods
      # -----------------------------------------------------------------------

      # Log a message with plugin context.
      #
      # @param level [Symbol] Log level (:debug, :info, :warn, :error)
      # @param message [String] Log message
      def log(level, message)
        prefix = "[Plugin:#{@plugin.display_name}]"
        case level
        when :debug
          Clacky::Logger.debug("#{prefix} #{message}")
        when :info
          Clacky::Logger.info("#{prefix} #{message}")
        when :warn
          Clacky::Logger.warn("#{prefix} #{message}")
        when :error
          Clacky::Logger.error("#{prefix} #{message}")
        else
          Clacky::Logger.info("#{prefix} #{message}")
        end
      end

      # Get the plugin's directory path.
      #
      # @return [Pathname] Plugin directory
      def plugin_dir
        @plugin.directory
      end

      # Read a file from the plugin's directory.
      #
      # @param relative_path [String] Path relative to plugin directory
      # @return [String, nil] File contents or nil if not found
      def read_plugin_file(relative_path)
        file_path = @plugin.directory.join(relative_path)
        return nil unless file_path.exist?

        file_path.read
      rescue StandardError => e
        Clacky::Logger.warn("[Plugin:#{@plugin.display_name}] Failed to read #{relative_path}: #{e.message}")
        nil
      end
    end
  end
end
