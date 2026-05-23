# Clacky 插件开发指南

本文档介绍如何开发和使用 Clacky 插件。

## 概述

Clacky 插件系统允许你通过插件扩展 Agent 的能力：

- **自定义工具** - 添加新的 AI 可调用工具
- **生命周期钩子** - 在关键时刻注入自定义逻辑
- **斜杠命令** - 添加用户可直接调用的命令
- **平台适配器** - 集成新的通信渠道

## 快速开始

### 1. 创建插件目录

```bash
mkdir -p ~/.clacky/plugins/my-plugin
cd ~/.clacky/plugins/my-plugin
```

### 2. 创建清单文件

`plugin.yaml`:

```yaml
name: my-plugin
version: 1.0.0
description: 我的第一个插件
author: 你的名字

# 可选：需要的环境变量
requires_env:
  - MY_API_KEY

# 可选：声明提供的功能
tools:
  - my_tool
hooks:
  - before_tool_use
commands:
  - mycmd
```

### 3. 创建入口文件

`init.rb`:

```ruby
# frozen_string_literal: true

def register(ctx)
  ctx.log(:info, "插件加载成功!")
end
```

### 4. 重载插件

在 WebUI 插件管理页面点击"重载"按钮，或通过 API 调用。

## 插件生命周期

```ruby
# frozen_string_literal: true

# 插件加载时调用
def self.register(ctx)
  ctx.log(:info, "插件加载")
  # 初始化资源、注册工具/钩子/命令
end

# 插件卸载时调用（可选）
def self.unload
  # 清理资源、停止后台线程
  Clacky::Logger.info("[MyPlugin] 插件已卸载")
end
```

**生命周期顺序**：
1. `register(ctx)` - 插件启用时调用
2. `unload()` - 插件禁用/卸载时调用

## 插件结构

```
my-plugin/
├── plugin.yaml    # 必须：插件清单
├── init.rb        # 可选：入口文件（默认）
├── lib/           # 可选：额外代码
└── README.md      # 可选：文档
```

## plugin.yaml 字段

| 字段 | 必须 | 说明 |
|------|------|------|
| `name` | 是 | 插件唯一标识 |
| `version` | 否 | 版本号 (SemVer) |
| `description` | 否 | 插件描述 |
| `author` | 否 | 作者信息 |
| `entry` | 否 | 入口文件，默认 `init.rb` |
| `kind` | 否 | 类型：`standalone`/`backend`/`platform` |
| `requires_env` | 否 | 必需的环境变量列表 |
| `tools` | 否 | 提供的工具列表（声明性） |
| `hooks` | 否 | 提供的钩子列表（声明性） |
| `commands` | 否 | 提供的命令列表（声明性） |

## PluginContext API

插件通过 `register(ctx)` 函数接收 PluginContext 实例。

### 工具注册

```ruby
class MyTool
  def name
    "my_tool"
  end

  def execute(input:, **_)
    "处理结果: #{input}"
  end

  def to_function_definition
    {
      name: name,
      description: "处理输入并返回结果",
      parameters: {
        type: "object",
        properties: {
          input: { type: "string", description: "输入内容" }
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

### 钩子注册

```ruby
def register(ctx)
  # 工具调用前
  ctx.add_hook(:before_tool_use) do |tool_name:, args:, **_|
    ctx.log(:info, "即将调用工具: #{tool_name}")
    { action: :allow }  # 或 { action: :skip } 跳过
  end

  # 工具调用后
  ctx.add_hook(:after_tool_use) do |tool_name:, result:, **_|
    ctx.log(:info, "工具返回: #{result}")
  end

  # LLM 调用前
  ctx.add_hook(:pre_llm_call) do |messages:, **_|
    # 可以修改消息
  end
end
```

### 斜杠命令

```ruby
def register(ctx)
  ctx.add_command("search",
    description: "搜索内容",
    args_hint: "<关键词>"
  ) do |args|
    "搜索结果: #{args}"
  end

  ctx.add_command("status", description: "显示状态") do |_args|
    "系统运行正常"
  end
end
```

### 工具调用

```ruby
def register(ctx)
  ctx.add_command("readfile", description: "读取文件", args_hint: "<路径>") do |args|
    # 调用已注册的工具
    result = ctx.dispatch_tool("read_file", { path: args.strip })
    result || "读取失败"
  end
end
```

### 平台适配器（消息渠道）

消息平台适配器用于连接外部消息平台（如微信、Telegram、Discord）。

**完整示例** (`init.rb`):

```ruby
# frozen_string_literal: true

@adapter = nil

def self.register(ctx)
  require_relative "lib/adapter"

  # 读取配置
  ws_url = ctx.config("ws_url")
  http_url = ctx.config("http_url")

  unless ws_url && http_url
    ctx.log(:warn, "未配置 ws_url 和 http_url")
    return
  end

  config = {
    ws_url: ws_url,
    http_url: http_url,
    group_wakeup_prefix: ctx.config("group_wakeup_prefix")
  }

  # 创建适配器
  @adapter = MyPlatform::Adapter.new(config)

  # 注册平台
  ctx.add_platform("myplatform",
    label: "My Platform",
    adapter_class: MyPlatform::Adapter,
    emoji: "💬"
  )

  # 启动后台线程
  Thread.new do
    @adapter.start do |event|
      ctx.log(:info, "收到消息: #{event[:text]}")
      # TODO: 将消息发送给 Agent 处理
    end
  rescue StandardError => e
    ctx.log(:error, "适配器错误: #{e.message}")
  end

  ctx.log(:info, "平台已启动")
end

def self.unload
  @adapter&.stop
  @adapter = nil
end
```

**适配器类** (`lib/adapter.rb`):

```ruby
module MyPlatform
  class Adapter
    def initialize(config)
      @config = config
      @running = false
    end

    def self.platform_id
      :myplatform
    end

    # 启动适配器，接收消息
    def start(&on_message)
      @running = true
      @on_message = on_message
      # 实现 WebSocket/轮询等接收逻辑
    end

    # 停止适配器
    def stop
      @running = false
    end

    # 发送文本消息
    def send_text(chat_id, text, reply_to: nil)
      # 实现发送逻辑
      { message_id: "sent" }
    end

    # 发送文件
    def send_file(chat_id, filepath)
      # 实现发送逻辑
      { message_id: "sent" }
    end
  end
end
```

**标准事件格式**：

```ruby
event = {
  platform: :myplatform,    # 平台标识
  chat_id: "123456",        # 会话 ID
  sender_id: "user123",     # 发送者 ID
  sender_name: "张三",       # 发送者昵称
  message_id: "msg001",     # 消息 ID
  text: "你好",              # 消息文本
  is_group: false,          # 是否群聊
  raw: { ... }              # 原始消息数据
}
```

### 配置访问

```ruby
def register(ctx)
  # 读取插件配置 (从 ~/.clacky/config.yaml)
  api_key = ctx.config("api_key")
  timeout = ctx.config("timeout", default: 30)

  # 访问上下文
  ctx.log(:info, "工作目录: #{ctx.working_dir}")
  ctx.log(:info, "会话ID: #{ctx.session_id}")
  ctx.log(:info, "插件目录: #{ctx.plugin_dir}")

  # 读取插件内文件
  content = ctx.read_plugin_file("data/template.txt")
end
```

## 可用钩子

| 钩子 | 参数 | 说明 |
|------|------|------|
| `:before_tool_use` | `tool_name`, `args` | 工具调用前，可返回 `{action: :skip}` 跳过 |
| `:after_tool_use` | `tool_name`, `args`, `result` | 工具调用后 |
| `:on_tool_error` | `tool_name`, `error` | 工具出错时 |
| `:on_start` | `session_id` | 任务开始 |
| `:on_complete` | `session_id` | 任务完成 |
| `:on_iteration` | `iteration` | 每次迭代 |
| `:pre_llm_call` | `messages`, `model` | LLM 调用前 |
| `:post_llm_call` | `response` | LLM 调用后 |
| `:transform_output` | `output` | 转换最终输出 |
| `:on_message` | `message` | 收到用户消息时 |
| `:session_rollback` | `session_id`, `task_id` | 会话回滚时 |

## 插件配置

在 `~/.clacky/config.yaml` 中配置插件：

```yaml
plugins:
  # 启用列表（可选，不设置则全部启用）
  enabled:
    - my-plugin
    - another-plugin

  # 禁用列表
  disabled:
    - unwanted-plugin

  # 插件专属配置
  my-plugin:
    api_key: "your-api-key"
    timeout: 60
```

## 最佳实践

### 1. 错误处理

```ruby
def register(ctx)
  ctx.add_hook(:before_tool_use) do |**kwargs|
    begin
      # 你的逻辑
      { action: :allow }
    rescue StandardError => e
      ctx.log(:error, "钩子错误: #{e.message}")
      { action: :allow }  # 失败时不阻断流程
    end
  end
end
```

### 2. 日志记录

```ruby
ctx.log(:debug, "调试信息")
ctx.log(:info, "一般信息")
ctx.log(:warn, "警告信息")
ctx.log(:error, "错误信息")
```

### 3. 环境变量检查

在 `plugin.yaml` 中声明 `requires_env`，系统会在加载前检查：

```yaml
requires_env:
  - MY_API_KEY
  - MY_SECRET
```

### 4. 版本管理

遵循语义化版本 (SemVer)：

```yaml
version: 1.0.0  # MAJOR.MINOR.PATCH
```

## 调试

### 启用调试日志

设置环境变量：

```bash
export CLACKY_DEBUG=1
```

### 查看插件状态

在 WebUI 的"插件管理"页面可以查看所有插件的状态、错误信息。

## 示例插件

参考 `~/.clacky/plugins/example/` 目录中的示例插件。

## 常见问题

### 插件未加载

1. 检查 `plugin.yaml` 格式是否正确
2. 检查是否在 `disabled` 列表中
3. 检查 `requires_env` 中的环境变量是否设置

### 工具未注册

1. 确保工具类实现了 `name`、`execute`、`to_function_definition` 方法
2. 检查日志中是否有错误信息

### 钩子未触发

1. 确认钩子名称正确（参考可用钩子列表）
2. 检查插件是否成功加载
