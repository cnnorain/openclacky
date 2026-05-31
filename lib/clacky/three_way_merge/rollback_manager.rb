# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

module Clacky
  module ThreeWayMerge
    # Rollback manager
    # Provides backup, rollback, and transaction support for merge operations
    class RollbackManager
      BACKUP_DIR = File.join(Dir.home, ".clacky", "merge_backups")
      LOG_FILE = "operation.log"

      # Operation record
      Operation = Struct.new(:id, :timestamp, :type, :files, :status, :error, keyword_init: true)

      # Initialize rollback manager
      # @param backup_dir [String] Backup storage directory
      def initialize(backup_dir = BACKUP_DIR)
        @backup_dir = backup_dir
        FileUtils.mkdir_p(@backup_dir)
      end

      # Create backup
      # @param files [Hash] { file_path => current_content }
      # @param description [String] Operation description
      # @return [String] Backup ID
      def create_backup(files, description = "")
        backup_id = generate_backup_id
        backup_path = File.join(@backup_dir, backup_id)
        FileUtils.mkdir_p(backup_path)

        # Save file contents
        files.each do |file_path, content|
          file_backup_path = File.join(backup_path, "files", file_path)
          FileUtils.mkdir_p(File.dirname(file_backup_path))
          File.write(file_backup_path, content || "")
        end

        # Save metadata
        metadata = {
          id: backup_id,
          timestamp: Time.now.iso8601,
          description:,
          files: files.keys,
          file_count: files.size
        }
        File.write(File.join(backup_path, "metadata.json"), JSON.pretty_generate(metadata))

        # Record operation log
        log_operation(Operation.new(
                        id: backup_id,
                        timestamp: Time.now.iso8601,
                        type: :backup,
                        files: files.keys,
                        status: :success,
                        error: nil
                      ))

        backup_id
      end

      # Rollback to specified backup
      # @param backup_id [String] Backup ID
      # @return [Hash] { success: [...], failed: [...] }
      def rollback(backup_id)
        backup_path = File.join(@backup_dir, backup_id)
        return { success: [], failed: [], error: "Backup does not exist: #{backup_id}" } unless Dir.exist?(backup_path)

        metadata = load_metadata(backup_path)
        files_dir = File.join(backup_path, "files")

        results = { success: [], failed: [] }

        # Restore each file
        metadata["files"].each do |file_path|
          backup_file = File.join(files_dir, file_path)
          unless File.exist?(backup_file)
            results[:failed] << { file: file_path, error: "Backup file does not exist" }
            next
          end

          begin
            content = File.read(backup_file)
            # If content is empty and original file does not exist, skip
            if content.empty? && !File.exist?(file_path)
              # File did not exist originally, skip
            else
              FileUtils.mkdir_p(File.dirname(file_path))
              File.write(file_path, content)
            end
            results[:success] << file_path
          rescue StandardError => e
            results[:failed] << { file: file_path, error: e.message }
          end
        end

        # Record rollback operation
        log_operation(Operation.new(
                        id: backup_id,
                        timestamp: Time.now.iso8601,
                        type: :rollback,
                        files: metadata["files"],
                        status: results[:failed].empty? ? :success : :partial,
                        error: results[:failed].any? ? "Some files failed to rollback" : nil
                      ))

        results
      end

      # Transactional merge
      # @param files [Hash] { file_path => { base:, ours:, theirs: } }
      # @param merger [ThreeWayMerger] Merger instance
      # @return [Hash] Merge result
      def transaction(files, merger)
        # 1. Create backup (backup current file state)
        backup_files = {}
        files.each_key do |file_path|
          backup_files[file_path] = File.exist?(file_path) ? File.read(file_path) : nil
        end

        backup_id = create_backup(backup_files, "Merge transaction")

        # 2. Execute merge
        begin
          results = merger.merge_files(files)

          # 3. Check for conflicts
          conflicts = results.select { |_, r| r.has_conflicts? }

          if conflicts.any?
            # Has conflicts, auto-rollback
            rollback(backup_id)
            return {
              success: false,
              error: "Merge has conflicts, auto-rollback performed",
              conflicts: conflicts.keys,
              backup_id:,
              results:
            }
          end

          # 4. Write merge results
          write_failures = {}
          results.each do |file_path, result|
            next if result.skipped?
            # Skip delete operations (content is nil and file does not exist)
            next if result.content.nil? && !File.exist?(file_path)

            begin
              if result.content.nil?
                # Delete file
                File.delete(file_path) if File.exist?(file_path)
              else
                # Write file
                FileUtils.mkdir_p(File.dirname(file_path))
                File.write(file_path, result.content)
              end
            rescue StandardError => e
              write_failures[file_path] = e.message
            end
          end

          # Check if any writes failed
          if write_failures.any?
            # Write failed, rollback
            rollback(backup_id)
            return {
              success: false,
              error: "File write failed, auto-rollback performed",
              failures: write_failures,
              backup_id:
            }
          end

          # Success
          {
            success: true,
            results:,
            backup_id:,
            message: "Merge completed successfully"
          }
        rescue StandardError => e
          # Exception, rollback
          rollback(backup_id)
          {
            success: false,
            error: "Merge process exception: #{e.message}",
            backtrace: e.backtrace&.first(5),
            backup_id:
          }
        end
      end

      # Get backup list
      # @return [Array<Hash>] Backup info list
      def list_backups
        backups = []

        Dir.glob("*", base: @backup_dir).each do |backup_id|
          backup_path = File.join(@backup_dir, backup_id)
          next unless File.directory?(backup_path)

          metadata = load_metadata(backup_path)
          backups << metadata if metadata
        end

        backups.sort_by { |b| b["timestamp"] || "" }.reverse
      end

      # Delete backup
      # @param backup_id [String] Backup ID
      # @return [Boolean]
      def delete_backup(backup_id)
        backup_path = File.join(@backup_dir, backup_id)
        return false unless Dir.exist?(backup_path)

        FileUtils.rm_rf(backup_path)
        true
      end

      # Cleanup old backups (keep most recent N)
      # @param keep_count [Integer] Number to keep
      # @return [Integer] Number deleted
      def cleanup_old_backups(keep_count = 10)
        backups = list_backups
        return 0 if backups.size <= keep_count

        to_delete = backups[keep_count..]
        deleted = 0

        to_delete.each do |backup|
          delete_backup(backup["id"])
          deleted += 1
        end

        deleted
      end

      # Get operation log
      # @param limit [Integer] Number of entries to return
      # @return [Array<Operation>]
      def operation_log(limit = 50)
        log_path = File.join(@backup_dir, LOG_FILE)
        return [] unless File.exist?(log_path)

        lines = File.readlines(log_path).last(limit)
        lines.map do |line|
          data = JSON.parse(line.strip)
          Operation.new(**data.transform_keys(&:to_sym))
        rescue StandardError
          nil
        end.compact
      end

      private

      def generate_backup_id
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        random = SecureRandom.hex(4)
        "#{timestamp}_#{random}"
      end

      def load_metadata(backup_path)
        metadata_path = File.join(backup_path, "metadata.json")
        return nil unless File.exist?(metadata_path)

        JSON.parse(File.read(metadata_path))
      rescue StandardError
        nil
      end

      def log_operation(operation)
        log_path = File.join(@backup_dir, LOG_FILE)
        entry = {
          id: operation.id,
          timestamp: operation.timestamp,
          type: operation.type.to_s,
          files: operation.files,
          status: operation.status.to_s,
          error: operation.error
        }

        File.open(log_path, "a") do |f|
          f.puts JSON.generate(entry)
        end
      end
    end
  end
end
