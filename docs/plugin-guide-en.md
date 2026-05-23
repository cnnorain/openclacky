# Clacky Plugin Development Guide

This document describes how to develop and use Clacky plugins.

## Overview

The Clacky plugin system allows you to extend the Agent's capabilities:

- **Custom Tools** - Add new AI-callable tools
- **Lifecycle Hooks** - Inject custom logic at key moments
- **Slash Commands** - Add user-invokable commands
- **Platform Adapters** - Integrate new communication channels

## Quick Start

### 1. Create Plugin Directory

```bash
mkdir -p ~/.clacky/plugins/my-plugin
cd ~/.clacky/plugins/my-plugin
```

### 2. Create Manifest File

`plugin.yaml`:

```yaml
name: my-plugin
version: 1.0.0
description: My first plugin
author: Your Name

# Optional: required environment variables
requires_env:
  - MY_API_KEY

# Optional: declare provided features
tools:
  - my_tool
hooks:
  - before_tool_use
commands:
  - mycmd
```

### 3. Create Entry File

`init.rb`:

```ruby
# frozen_string_literal: true

def register(ctx)
  ctx.log(:info, "Plugin loaded successfully!")
end
```

### 4. Reload Plugins

Click the "Reload" button on the WebUI plugin management page, or call via API.

## Plugin Structure

```
my-plugin/
├── plugin.yaml    # Required: plugin manifest
├── init.rb        # Optional: entry file (default)
├── lib/           # Optional: additional code
└── README.md      # Optional: documentation
```

## plugin.yaml Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Unique plugin identifier |
| `version` | No | Version number (SemVer) |
| `description` | No | Plugin description |
| `author` | No | Author information |
| `entry` | No | Entry file, defaults to `init.rb` |
| `kind` | No | Type: `standalone`/`backend`/`platform` |
| `requires_env` | No | Required environment variables |
| `tools` | No | Provided tools (declarative) |
| `hooks` | No | Provided hooks (declarative) |
| `commands` | No | Provided commands (declarative) |

## PluginContext API

Plugins receive a PluginContext instance via the `register(ctx)` function.

### Tool Registration

```ruby
class MyTool
  def name
    "my_tool"
  end

  def execute(input:, **_)
    "Result: #{input}"
  end

  def to_function_definition
    {
      name: name,
      description: "Process input and return result",
      parameters: {
        type: "object",
        properties: {
          input: { type: "string", description: "Input content" }
        },
        required: ["input"]
      }
    }
  end
end

def register(ctx)
  ctx.add_tool(MyTool.new)
end
```

### Hook Registration

```ruby
def register(ctx)
  # Before tool call
  ctx.add_hook(:before_tool_use) do |tool_name:, args:, **_|
    ctx.log(:info, "About to call tool: #{tool_name}")
    { action: :allow }  # or { action: :skip } to skip
  end

  # After tool call
  ctx.add_hook(:after_tool_use) do |tool_name:, result:, **_|
    ctx.log(:info, "Tool returned: #{result}")
  end

  # Before LLM call
  ctx.add_hook(:pre_llm_call) do |messages:, **_|
    # Can modify messages
  end
end
```

### Slash Commands

```ruby
def register(ctx)
  ctx.add_command("search",
    description: "Search for content",
    args_hint: "<keyword>"
  ) do |args|
    "Search results: #{args}"
  end

  ctx.add_command("status", description: "Show status") do |_args|
    "System running normally"
  end
end
```

### Tool Dispatch

```ruby
def register(ctx)
  ctx.add_command("readfile", description: "Read a file", args_hint: "<path>") do |args|
    # Call a registered tool
    result = ctx.dispatch_tool("read_file", { path: args.strip })
    result || "Read failed"
  end
end
```

### Platform Adapters

```ruby
class MyPlatformAdapter
  def initialize(config)
    @config = config
  end

  def start
    # Start the adapter
  end

  def stop
    # Stop the adapter
  end

  def send_message(text)
    # Send a message
  end
end

def register(ctx)
  ctx.add_platform("myplatform",
    label: "My Platform",
    adapter_class: MyPlatformAdapter,
    check_fn: -> { true },
    required_env: ["MY_PLATFORM_TOKEN"],
    install_hint: "Set the MY_PLATFORM_TOKEN environment variable",
    emoji: "🔌"
  )
end
```

### Configuration Access

```ruby
def register(ctx)
  # Read plugin config (from ~/.clacky/config.yaml)
  api_key = ctx.config("api_key")
  timeout = ctx.config("timeout", default: 30)

  # Access context
  ctx.log(:info, "Working dir: #{ctx.working_dir}")
  ctx.log(:info, "Session ID: #{ctx.session_id}")
  ctx.log(:info, "Plugin dir: #{ctx.plugin_dir}")

  # Read file from plugin directory
  content = ctx.read_plugin_file("data/template.txt")
end
```

## Available Hooks

| Hook | Parameters | Description |
|------|------------|-------------|
| `:before_tool_use` | `tool_name`, `args` | Before tool call, can return `{action: :skip}` to skip |
| `:after_tool_use` | `tool_name`, `args`, `result` | After tool call |
| `:on_tool_error` | `tool_name`, `error` | When tool errors |
| `:on_start` | `session_id` | Task start |
| `:on_complete` | `session_id` | Task complete |
| `:on_iteration` | `iteration` | Each iteration |
| `:pre_llm_call` | `messages`, `model` | Before LLM call |
| `:post_llm_call` | `response` | After LLM call |
| `:transform_output` | `output` | Transform final output |
| `:on_message` | `message` | When user message received |
| `:session_rollback` | `session_id`, `task_id` | On session rollback |

## Plugin Configuration

Configure plugins in `~/.clacky/config.yaml`:

```yaml
plugins:
  # Enable list (optional, all enabled if not set)
  enabled:
    - my-plugin
    - another-plugin

  # Disable list
  disabled:
    - unwanted-plugin

  # Plugin-specific config
  my-plugin:
    api_key: "your-api-key"
    timeout: 60
```

## Best Practices

### 1. Error Handling

```ruby
def register(ctx)
  ctx.add_hook(:before_tool_use) do |**kwargs|
    begin
      # Your logic
      { action: :allow }
    rescue StandardError => e
      ctx.log(:error, "Hook error: #{e.message}")
      { action: :allow }  # Don't block flow on failure
    end
  end
end
```

### 2. Logging

```ruby
ctx.log(:debug, "Debug info")
ctx.log(:info, "General info")
ctx.log(:warn, "Warning")
ctx.log(:error, "Error")
```

### 3. Environment Variable Checks

Declare `requires_env` in `plugin.yaml`, the system will check before loading:

```yaml
requires_env:
  - MY_API_KEY
  - MY_SECRET
```

### 4. Version Management

Follow Semantic Versioning (SemVer):

```yaml
version: 1.0.0  # MAJOR.MINOR.PATCH
```

## Debugging

### Enable Debug Logging

Set environment variable:

```bash
export CLACKY_DEBUG=1
```

### View Plugin Status

Check the "Plugin Management" page in WebUI to view all plugin statuses and errors.

## Example Plugin

Refer to the example plugin in `~/.clacky/plugins/example/` directory.

## FAQ

### Plugin Not Loading

1. Check if `plugin.yaml` format is correct
2. Check if it's in the `disabled` list
3. Check if environment variables in `requires_env` are set

### Tool Not Registered

1. Ensure tool class implements `name`, `execute`, `to_function_definition` methods
2. Check logs for error messages

### Hook Not Triggering

1. Confirm hook name is correct (see available hooks list)
2. Check if plugin loaded successfully
