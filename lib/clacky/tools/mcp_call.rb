# frozen_string_literal: true

module Clacky
  module Tools
    # Bridge from the agent's tool-calling layer to the MCP registry.
    #
    # This is the *only* tool added to the registry on behalf of MCP. Its
    # schema is constant — no matter how many MCP servers are configured or
    # how many tools each server exposes. That keeps the system prompt's
    # cache key stable.
    #
    # The tool is registered at agent boot only when at least one MCP server
    # is configured (see Agent#register_builtin_tools). Zero-MCP users pay
    # nothing in main-context tokens.
    class McpCall < Base
      self.tool_name = "mcp_call"
      self.tool_description =
        "Call a tool on a configured MCP (Model Context Protocol) server. " \
        "Server names appear in the AVAILABLE MCP SERVERS section of the system prompt. " \
        "Use invoke_skill('mcp:<server>', '<task>') first if you do not know the exact tool name " \
        "or argument shape — that forks a subagent loaded with the server's full tool list."
      self.tool_category = "mcp"
      self.tool_parameters = {
        type: "object",
        properties: {
          server: {
            type: "string",
            description: "Name of the MCP server (key from mcp.json)"
          },
          tool: {
            type: "string",
            description: "Name of the tool to invoke on that server"
          },
          arguments: {
            type: "object",
            description: "Arguments object matching the tool's inputSchema. Pass {} if the tool takes no arguments.",
            additionalProperties: true
          }
        },
        required: ["server", "tool"]
      }

      def execute(server:, tool:, arguments: {}, agent: nil, **)
        registry = agent&.mcp_registry
        return { error: "MCP is not configured for this agent" } unless registry
        return { error: "MCP server '#{server}' is not configured in mcp.json" } unless registry.configured?(server)

        result = registry.call_tool(server, tool, arguments || {})
        format_mcp_result(result)
      rescue Clacky::Mcp::Client::McpError => e
        { error: "MCP error: #{e.message}" }
      end

      def format_call(args)
        srv = args[:server] || args["server"]
        tool = args[:tool] || args["tool"]
        "mcp_call(#{srv}.#{tool})"
      end

      def format_result(result)
        case result
        when String
          result.length > 200 ? "#{result[0, 200]}..." : result
        when Hash
          result[:error] ? "Error: #{result[:error]}" : "Done"
        else
          "Done"
        end
      end

      private def format_mcp_result(result)
        return result.to_s unless result.is_a?(Hash)

        content  = result["content"]  || result[:content]  || []
        is_error = result["isError"]  || result[:isError]

        text = Array(content).filter_map do |part|
          h = part.is_a?(Hash) ? part : {}
          case h["type"] || h[:type]
          when "text"     then h["text"] || h[:text]
          when "image"    then "[image: #{h["mimeType"] || h[:mimeType] || "binary"}]"
          when "resource"
            uri = h.dig("resource", "uri") || h.dig(:resource, :uri)
            "[resource: #{uri}]"
          else h.to_json
          end
        end.join("\n")

        is_error ? { error: text.empty? ? "tool reported error" : text } : text
      end
    end
  end
end
