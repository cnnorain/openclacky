# frozen_string_literal: true

require "json"
require "yaml"
require "fileutils"
require "digest"
require "pathname"

module Clacky
  module UpgradeMerger
    # 升级时需要合并的文件类型
    MERGEABLE_EXTENSIONS = %w[.md .yml .yaml .json .rb .sh .py .js].freeze

    # 默认技能目录（gem 内置）
    DEFAULT_SKILLS_DIR = File.expand_path("../default_skills", __dir__)

    # 用户技能目录
    USER_SKILLS_DIR = File.join(Dir.home, ".clacky", "skills")

    # 品牌技能目录
    BRAND_SKILLS_DIR = File.join(Dir.home, ".clacky", "brand_skills")

    # 升级快照目录
    UPGRADE_SNAPSHOTS_DIR = File.join(Dir.home, ".clacky", "upgrade_snapshots")

    class << self
      # 保存当前版本的快照（升级前调用）
      # @param version [String] 当前版本号
      # @return [Hash] 快照信息
      def save_pre_upgrade_snapshot(version)
        snapshot_dir = File.join(UPGRADE_SNAPSHOTS_DIR, version)
        FileUtils.mkdir_p(snapshot_dir)

        # 保存默认技能的快照
        default_skills_snapshot = save_default_skills_snapshot(snapshot_dir)

        # 保存配置文件快照
        config_snapshot = save_config_snapshot(snapshot_dir)

        # 保存快照元数据
        metadata = {
          version: version,
          timestamp: Time.now.iso8601,
          default_skills: default_skills_snapshot,
          config_files: config_snapshot
        }

        metadata_path = File.join(snapshot_dir, "metadata.json")
        File.write(metadata_path, JSON.pretty_generate(metadata))

        metadata
      end

      # 执行三路合并（升级后调用）
      # @param old_version [String] 旧版本号
      # @param new_version [String] 新版本号
      # @return [Hash] 合并结果
      def merge_after_upgrade(old_version, new_version)
        snapshot_dir = File.join(UPGRADE_SNAPSHOTS_DIR, old_version)
        return { success: false, error: "No pre-upgrade snapshot found" } unless Dir.exist?(snapshot_dir)

        metadata_path = File.join(snapshot_dir, "metadata.json")
        return { success: false, error: "No snapshot metadata found" } unless File.exist?(metadata_path)

        metadata = JSON.parse(File.read(metadata_path))

        results = {
          success: true,
          merged_files: [],
          conflicts: [],
          skipped: []
        }

        # 合并默认技能
        merge_default_skills(metadata, snapshot_dir, results)

        # 合并配置文件
        merge_config_files(metadata, snapshot_dir, results)

        # 清理旧快照
        cleanup_old_snapshots(old_version)

        results
      end

      # 检查是否有需要合并的文件
      # @param version [String] 版本号
      # @return [Boolean]
      def has_mergeable_files?(version)
        snapshot_dir = File.join(UPGRADE_SNAPSHOTS_DIR, version)
        return false unless Dir.exist?(snapshot_dir)

        metadata_path = File.join(snapshot_dir, "metadata.json")
        return false unless File.exist?(metadata_path)

        metadata = JSON.parse(File.read(metadata_path))
        metadata["default_skills"]&.any? || metadata["config_files"]&.any?
      end

      private

      # 保存默认技能快照
      def save_default_skills_snapshot(snapshot_dir)
        return [] unless Dir.exist?(DEFAULT_SKILLS_DIR)

        skills_snapshot = []
        skills_backup_dir = File.join(snapshot_dir, "default_skills")
        FileUtils.mkdir_p(skills_backup_dir)

        Dir.glob(File.join(DEFAULT_SKILLS_DIR, "*/SKILL.md")).each do |skill_file|
          skill_dir = File.dirname(skill_file)
          skill_name = File.basename(skill_dir)
          skill_backup_dir = File.join(skills_backup_dir, skill_name)
          FileUtils.mkdir_p(skill_backup_dir)

          # 复制技能目录中的所有文件
          Dir.glob(File.join(skill_dir, "**", "*")).each do |file|
            next unless File.file?(file)
            relative_path = file.sub(skill_dir + "/", "")
            dest_path = File.join(skill_backup_dir, relative_path)
            FileUtils.mkdir_p(File.dirname(dest_path))
            FileUtils.cp(file, dest_path)
          end

          skills_snapshot << {
            name: skill_name,
            path: skill_dir,
            files: Dir.glob(File.join(skill_dir, "**", "*")).select { |f| File.file?(f) }.map { |f| f.sub(skill_dir + "/", "") }
          }
        end

        skills_snapshot
      end

      # 保存配置文件快照
      def save_config_snapshot(snapshot_dir)
        config_snapshot = []
        config_backup_dir = File.join(snapshot_dir, "config")
        FileUtils.mkdir_p(config_backup_dir)

        # 保存用户配置文件
        user_config_file = File.join(Dir.home, ".clacky", "config.yml")
        if File.exist?(user_config_file)
          FileUtils.cp(user_config_file, File.join(config_backup_dir, "config.yml"))
          config_snapshot << { name: "config.yml", path: user_config_file }
        end

        # 保存品牌配置文件
        brand_config_file = File.join(Dir.home, ".clacky", "brand.yml")
        if File.exist?(brand_config_file)
          FileUtils.cp(brand_config_file, File.join(config_backup_dir, "brand.yml"))
          config_snapshot << { name: "brand.yml", path: brand_config_file }
        end

        config_snapshot
      end

      # 合并默认技能
      def merge_default_skills(metadata, snapshot_dir, results)
        return unless metadata["default_skills"]

        metadata["default_skills"].each do |skill_info|
          skill_name = skill_info["name"]
          old_skill_dir = File.join(snapshot_dir, "default_skills", skill_name)
          new_skill_dir = File.join(DEFAULT_SKILLS_DIR, skill_name)
          user_skill_dir = File.join(USER_SKILLS_DIR, skill_name)

          # 如果用户没有修改过这个技能，跳过
          next unless Dir.exist?(user_skill_dir)

          # 如果新版本没有这个技能，跳过
          next unless Dir.exist?(new_skill_dir)

          # 合并每个文件
          skill_info["files"]&.each do |file_path|
            old_file = File.join(old_skill_dir, file_path)
            new_file = File.join(new_skill_dir, file_path)
            user_file = File.join(user_skill_dir, file_path)

            # 如果用户没有这个文件，跳过
            next unless File.exist?(user_file)

            # 如果旧版本没有这个文件，跳过
            next unless File.exist?(old_file)

            # 如果新版本没有这个文件，跳过
            next unless File.exist?(new_file)

            # 检查用户是否修改过
            old_content = File.read(old_file)
            user_content = File.read(user_file)
            next if old_content == user_content

            # 检查新版本是否有变化
            new_content = File.read(new_file)
            next if old_content == new_content

            # 执行三路合并
            merge_result = merge_file(old_content, user_content, new_content, "#{skill_name}/#{file_path}")
            
            if merge_result[:success]
              # 写入合并结果
              File.write(user_file, merge_result[:content])
              results[:merged_files] << "#{skill_name}/#{file_path}"
            else
              results[:conflicts] << {
                file: "#{skill_name}/#{file_path}",
                error: merge_result[:error]
              }
            end
          end
        end
      end

      # 合并配置文件
      def merge_config_files(metadata, snapshot_dir, results)
        return unless metadata["config_files"]

        metadata["config_files"].each do |config_info|
          config_name = config_info["name"]
          old_file = File.join(snapshot_dir, "config", config_name)
          new_file = config_info["path"]  # 用户当前文件
          new_default_file = File.join(DEFAULT_SKILLS_DIR, "..", "..", "default_agents", config_name.sub(".yml", ""), "config.yml")

          # 如果用户没有修改过，跳过
          next unless File.exist?(old_file)
          next unless File.exist?(new_file)

          old_content = File.read(old_file)
          user_content = File.read(new_file)
          next if old_content == user_content

          # 如果新版本没有默认配置，跳过
          next unless File.exist?(new_default_file)

          new_content = File.read(new_default_file)
          next if old_content == new_content

          # 执行三路合并
          merge_result = merge_file(old_content, user_content, new_content, config_name)
          
          if merge_result[:success]
            File.write(new_file, merge_result[:content])
            results[:merged_files] << config_name
          else
            results[:conflicts] << {
              file: config_name,
              error: merge_result[:error]
            }
          end
        end
      end

      # 执行单个文件的三路合并
      # @param base [String] 基础内容（旧版本）
      # @param ours [String] 我们的内容（用户修改）
      # @param theirs [String] 他们的内容（新版本）
      # @param file_path [String] 文件路径（用于日志）
      # @return [Hash] 合并结果
      def merge_file(base, ours, theirs, file_path)
        require_relative "three_way_merge"

        merger = Clacky::ThreeWayMerge.create_merger
        result = merger.merge_file(file_path, base, ours, theirs)

        if result.success?
          { success: true, content: result.content }
        elsif result.has_conflicts?
          # 尝试自动解决冲突
          resolved_content = auto_resolve_conflicts(result.content)
          if resolved_content
            { success: true, content: resolved_content }
          else
            { success: false, error: "Conflicts in #{file_path}: #{result.conflicts.join(', ')}" }
          end
        else
          { success: false, error: "Merge failed for #{file_path}" }
        end
      rescue StandardError => e
        { success: false, error: "Error merging #{file_path}: #{e.message}" }
      end

      # 自动解决冲突
      # @param content [String] 包含冲突标记的内容
      # @return [String, nil] 解决后的内容，如果无法解决返回 nil
      def auto_resolve_conflicts(content)
        # 智能冲突解决策略：
        # 1. 保留用户修改的行（ours）
        # 2. 添加新版本的新行（theirs）
        # 3. 对于冲突的行，保留用户修改（保守策略）
        lines = content.lines
        resolved_lines = []
        in_conflict = false
        ours_lines = []
        theirs_lines = []

        lines.each do |line|
          if line.start_with?("<<<<<<<")
            in_conflict = true
            ours_lines = []
            theirs_lines = []
            next
          elsif line.start_with?("=======")
            next
          elsif line.start_with?(">>>>>>>")
            in_conflict = false
            
            # 智能合并：保留用户修改，添加新版本的新行
            merged = smart_merge(ours_lines, theirs_lines)
            resolved_lines.concat(merged)
            next
          end

          if in_conflict
            if line.start_with?("=======")
              # 已经处理过
            else
              # 判断是 ours 还是 theirs
              if ours_lines.empty? || !line.start_with?("=")
                ours_lines << line
              else
                theirs_lines << line
              end
            end
          else
            resolved_lines << line
          end
        end

        resolved_lines.join
      end

      # 智能合并两边的行
      # @param ours [Array] 用户修改的行
      # @param theirs [Array] 新版本的行
      # @return [Array] 合并后的行
      def smart_merge(ours, theirs)
        # 简单策略：保留 ours，添加 theirs 中的新行
        # 这是一个保守的策略，优先保留用户的修改
        
        # 找出 theirs 中的新行（不在 ours 中的行）
        new_lines = theirs.reject do |theirs_line|
          ours.any? { |ours_line| ours_line.strip == theirs_line.strip }
        end
        
        # 合并：保留 ours，添加新行
        ours + new_lines
      end

      # 清理旧快照
      def cleanup_old_snapshots(current_version)
        return unless Dir.exist?(UPGRADE_SNAPSHOTS_DIR)

        Dir.glob(File.join(UPGRADE_SNAPSHOTS_DIR, "*")).each do |snapshot_dir|
          next unless File.directory?(snapshot_dir)
          version = File.basename(snapshot_dir)
          next if version == current_version

          # 保留最近 3 个版本的快照
          FileUtils.rm_rf(snapshot_dir) if should_cleanup_snapshot?(snapshot_dir)
        end
      end

      # 检查是否应该清理快照
      def should_cleanup_snapshot?(snapshot_dir)
        metadata_path = File.join(snapshot_dir, "metadata.json")
        return false unless File.exist?(metadata_path)

        metadata = JSON.parse(File.read(metadata_path))
        timestamp = Time.parse(metadata["timestamp"])
        
        # 保留 7 天内的快照
        Time.now - timestamp > 7 * 24 * 60 * 60
      rescue StandardError
        false
      end
    end
  end
end
