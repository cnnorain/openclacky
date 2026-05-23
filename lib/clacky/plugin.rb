# frozen_string_literal: true

# Clacky Plugin System
#
# Provides a flexible plugin architecture for extending Clacky with:
#   - Custom tools
#   - Lifecycle hooks
#   - Slash commands
#
# Plugin Sources (in priority order, later overrides earlier):
#   1. Default plugins - bundled with gem
#   2. Global plugins  - ~/.clacky/plugins/
#   3. Project plugins - .clacky/plugins/
#
# Each plugin requires a plugin.yaml manifest and optionally an init.rb entry:
#
#   my-plugin/
#   ├── plugin.yaml    # Required: name, version, description
#   └── init.rb        # Optional: register(ctx) function
#
# Example plugin.yaml:
#
#   name: my-plugin
#   version: 1.0.0
#   description: My custom plugin
#   requires_env:
#     - MY_API_KEY
#
# Example init.rb:
#
#   def register(ctx)
#     ctx.add_tool(MyTool.new)
#     ctx.add_hook(:before_tool_use) { |name, args| ctx.log(:info, "Calling #{name}") }
#     ctx.add_command("mycommand", description: "Do something") { |args, _| "Result: #{args}" }
#   end
#
# Configuration (in ~/.clacky/config.yaml):
#
#   plugins:
#     enabled:
#       - my-plugin
#       - another-plugin
#     disabled:
#       - unwanted-plugin
#     my-plugin:
#       api_key: xxx
#
require_relative "plugin/plugin"
require_relative "plugin/plugin_context"
require_relative "plugin/plugin_loader"
require_relative "plugin/plugin_manager"

module Clacky
  module Plugin
    class << self
      # Get or create the global plugin manager.
      #
      # @param working_dir [String, nil] Working directory for project plugins
      # @return [PluginManager] Global plugin manager instance
      def manager(working_dir: nil)
        @manager ||= PluginManager.new(working_dir: working_dir)
      end

      # Reset the global plugin manager (mainly for testing).
      def reset!
        @manager = nil
      end

      # Discover and load all plugins.
      #
      # @param working_dir [String, nil] Working directory
      # @param agent [Object, nil] Agent instance
      # @param tool_registry [Object, nil] Tool registry
      # @param force [Boolean] Force reload
      def setup(working_dir: nil, agent: nil, tool_registry: nil, force: false)
        mgr = manager(working_dir: working_dir)
        mgr.agent = agent if agent
        mgr.tool_registry = tool_registry if tool_registry
        mgr.discover_and_load(force: force)
        mgr
      end

      # Refresh plugin list (safe, doesn't interrupt running plugins).
      def refresh
        @manager&.refresh
      end

      # Hot reload all plugins (WARNING: interrupts running plugins).
      def reload
        @manager&.reload
      end

      # Invoke a hook across all plugins.
      #
      # @param event [Symbol] Hook event name
      # @param kwargs [Hash] Arguments to pass
      # @return [Hash] Combined results
      def invoke_hook(event, **kwargs)
        @manager&.invoke_hook(event, **kwargs) || { action: :allow }
      end
    end
  end
end
