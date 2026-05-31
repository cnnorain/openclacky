#!/usr/bin/env ruby
# frozen_string_literal: true

# 三路合并使用示例

require_relative "../lib/clacky/three_way_merge"

puts "=" * 60
puts "  三路合并示例"
puts "=" * 60
puts

# 示例 1: 合并单个文本文件
puts "【示例 1】合并文本文件"
puts "-" * 40

base = <<~TEXT
  # 配置文件
  host = localhost
  port = 3000
  debug = true
TEXT

ours = <<~TEXT
  # 配置文件
  host = localhost
  port = 8080
  debug = true
  # 本地添加的配置
  cache_enabled = true
TEXT

theirs = <<~TEXT
  # 配置文件
  host = 0.0.0.0
  port = 3000
  debug = false
TEXT

result = Clacky::ThreeWayMerge.merge_file("config.txt", base, ours, theirs)

puts "状态: #{result.status}"
puts "策略: #{result.strategy_used}"
puts "冲突数: #{result.conflicts&.size || 0}"
puts "内容:"
puts result.content
puts

# 示例 2: 合并 JSON 配置文件
puts "【示例 2】合并 JSON 配置"
puts "-" * 40

base_json = '{"database": {"host": "localhost", "port": 5432}, "debug": true}'
ours_json = '{"database": {"host": "localhost", "port": 5432}, "debug": false, "cache": true}'
theirs_json = '{"database": {"host": "db.example.com", "port": 5432}, "debug": true}'

result = Clacky::ThreeWayMerge.merge_file("config.json", base_json, ours_json, theirs_json)

puts "状态: #{result.status}"
puts "内容:"
if result.content
  puts result.content
end
puts

# 示例 3: 批量合并文件
puts "【示例 3】批量合并"
puts "-" * 40

files = {
  "app.rb" => {
    base: "class App\n  def run\n    puts 'v1'\n  end\nend",
    ours: "class App\n  def run\n    puts 'v1-modified'\n  end\nend",
    theirs: "class App\n  def run\n    puts 'v2'\n  end\nend"
  },
  "README.md" => {
    base: "# Project\nVersion 1.0",
    ours: "# Project\nVersion 1.0\n\n## Local Notes\nMy changes",
    theirs: "# Project\nVersion 2.0"
  },
  "new_file.txt" => {
    base: nil,
    ours: "This is a new local file",
    theirs: nil
  }
}

results = Clacky::ThreeWayMerge.merge_files(files)
puts Clacky::ThreeWayMerge::ThreeWayMerger.new.generate_report(results)
puts

# 示例 4: 使用版本管理器
puts "【示例 4】版本管理器"
puts "-" * 40

require "tmpdir"
require "fileutils"

# 使用默认路径 ~/.clacky/versions/
# vm = Clacky::ThreeWayMerge.version_manager

# 或指定自定义路径
vm = Clacky::ThreeWayMerge.version_manager("/tmp/test_versions")

# 创建版本 1
v1_dir = Dir.mktmpdir
File.write(File.join(v1_dir, "app.rb"), "class App\n  def initialize\n    @version = 1\n  end\nend")
File.write(File.join(v1_dir, "config.json"), '{"version": 1}')

vm.save_snapshot("1.0.0", v1_dir)
puts "保存版本 1.0.0"

# 创建版本 2
v2_dir = Dir.mktmpdir
File.write(File.join(v2_dir, "app.rb"), "class App\n  def initialize\n    @version = 2\n  end\n\n  def new_feature\n    puts 'new'\n  end\nend")
File.write(File.join(v2_dir, "config.json"), '{"version": 2, "new_option": true}')

vm.save_snapshot("1.1.0", v2_dir)
puts "保存版本 1.1.0"

puts
puts "当前版本: #{vm.current_version}"
puts "所有版本: #{vm.versions.join(', ')}"

diff = vm.diff_versions("1.0.0", "1.1.0")
puts
puts "版本差异:"
puts "  新增文件: #{diff[:added].join(', ') || '无'}"
puts "  删除文件: #{diff[:deleted].join(', ') || '无'}"
puts "  修改文件: #{diff[:modified].join(', ') || '无'}"

# 清理
FileUtils.rm_rf(tmp_dir)
FileUtils.rm_rf(v1_dir)
FileUtils.rm_rf(v2_dir)
puts

# 示例 5: 冲突解决
puts "【示例 5】冲突解决"
puts "-" * 40

conflicted_content = <<~TEXT
  line1
  line2
  <<<<<<< LOCAL (你的修改)
  这是我的修改
  =======
  这是新版本的修改
  >>>>>>> UPSTREAM (新版本)
  line5
TEXT

puts "包含冲突标记的内容:"
puts conflicted_content

puts "冲突数量: #{Clacky::ThreeWayMerge.has_conflicts?(conflicted_content)}"
puts

puts "解决冲突（保留本地）:"
resolved = Clacky::ThreeWayMerge.resolve_to_ours(conflicted_content)
puts resolved

puts "=" * 60
puts "  示例结束"
puts "=" * 60
