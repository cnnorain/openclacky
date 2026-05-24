# frozen_string_literal: true

require "json"
require_relative "../skill"

module Clacky
  module Mcp
    # A Skill that exists only in memory, synthesized from an MCP server's
    # registration. It plugs into all the existing skill machinery (system-prompt
    # injection, slash dispatch, subagent fork via invoke_skill) without sitting
    # on disk.
    #
    # When invoked, it always runs as a forked subagent. The subagent's
    # tool_registry is augmented with the MCP server's actual tools so the LLM
    # can call them as first-class function calls — there is no two-layer
    # "mcp_call(server, tool, args)" wrapper.
    class VirtualSkill < Clacky::Skill
      attr_reader :mcp_server_name, :tool_definitions

      # @param server_name [String] e.g. "github" — used as the skill identifier
      #   prefixed with "mcp:" so it never collides with on-disk skills.
      # @param description [String] One-line capability summary for system prompt.
      # @param tool_definitions [Array<Hash>] OpenAI-style function defs from the
      #   MCP server's tools/list. Embedded into the subagent's system prompt so
      #   the LLM knows what's available before fork.
      def initialize(server_name:, description:, tool_definitions: [])
        # Deliberately do NOT call super — Skill#initialize reads SKILL.md from
        # disk. We synthesize all required fields manually instead.
        @mcp_server_name = server_name

        @directory       = Pathname.new("/dev/null/mcp/#{server_name}")
        @source_path     = @directory
        @brand_skill     = false
        @brand_config    = nil
        @cached_metadata = nil
        @encrypted       = false
        @warnings        = []
        @invalid         = false
        @invalid_reason  = nil
        @frontmatter     = {}

        @name        = "mcp:#{server_name}"
        @description = description
        @name_zh        = nil
        @description_zh = nil

        @user_invocable           = true
        @disable_model_invocation = false
        @allowed_tools  = nil
        @context        = nil
        @agent_type     = nil
        @argument_hint  = nil
        @hooks          = nil
        @fork_agent     = true              # always run in subagent — schemas stay out of main context
        @model          = nil
        @forbidden_tools = nil
        @auto_summarize = true

        @tool_definitions = tool_definitions
        @content = build_content
      end

      def encrypted?
        false
      end

      def has_supporting_files?
        false
      end

      def supporting_files
        []
      end

      def slash_command
        # Identifier contains ":" which isn't a valid slug character — present
        # the slash form with a hyphen instead.
        "/mcp-#{@mcp_server_name}"
      end

      # Override: there are no supporting files to list, no env vars to expand.
      # The content is fully synthesized at build time.
      def process_content(shell_output: {}, template_context: {}, script_dir: nil)
        @content
      end

      def to_h
        super.merge(mcp: true, mcp_server: @mcp_server_name)
      end

      private def build_content
        lines = []
        lines << "# MCP Server: #{@mcp_server_name}"
        lines << ""
        lines << "You are a subagent operating the **#{@mcp_server_name}** MCP server."
        lines << ""
        lines << "## How to call tools"
        lines << ""
        lines << "All MCP calls go through the `mcp_call` tool that is already in your tool registry:"
        lines << ""
        lines << "```"
        lines << "mcp_call(server: \"#{@mcp_server_name}\", tool: \"<tool_name>\", arguments: { ... })"
        lines << "```"
        lines << ""
        lines << "Pick a tool from the list below, build the arguments according to its `inputSchema`, and call it."
        lines << ""
        lines << "## Available Tools"
        lines << ""

        if @tool_definitions.empty?
          lines << "_(no tools advertised by this server)_"
        else
          @tool_definitions.each do |defn|
            fn = defn[:function] || defn["function"] || {}
            name = fn[:name] || fn["name"]
            desc = fn[:description] || fn["description"]
            schema = fn[:parameters] || fn["parameters"] || {}

            lines << "### `#{name}`"
            lines << desc.to_s if desc && !desc.empty?
            lines << ""
            lines << "**inputSchema:**"
            lines << ""
            lines << "```json"
            lines << JSON.pretty_generate(schema)
            lines << "```"
            lines << ""
          end
        end

        lines << "## Workflow"
        lines << ""
        lines << "1. Understand the task delegated by the parent agent."
        lines << "2. Pick the right tool(s); call them via `mcp_call` with valid arguments."
        lines << "3. When done, return a concise summary of what was accomplished and any results the parent needs."
        lines << "4. Do not chit-chat — the parent only sees your final response."

        lines.join("\n")
      end
    end
  end
end
