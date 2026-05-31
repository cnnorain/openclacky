# frozen_string_literal: true

module Clacky
  module ThreeWayMerge
    # Security utility module
    # Provides path validation, file security checks, and other security features
    module Security
      # Default maximum file size 10MB
      MAX_FILE_SIZE = 10 * 1024 * 1024

      # Binary file extensions
      BINARY_EXTENSIONS = %w[
        .png .jpg .jpeg .gif .bmp .ico .webp .svg
        .mp3 .mp4 .avi .mov .wmv .flv .webm
        .zip .tar .gz .bz2 .rar .7z
        .pdf .doc .docx .xls .xlsx .ppt .pptx
        .exe .dll .so .dylib .o .a .lib
        .pyc .pyo .class .jar
        .sqlite .db .sqlite3
        .woff .woff2 .ttf .otf .eot
      ].freeze

      class << self
        # Validate file path safety
        # @param file_path [String] File path
        # @param base_dir [String, nil] Base directory (optional, for path traversal prevention)
        # @return [Boolean] Whether safe
        # @raise [SecurityError] When path is unsafe
        def validate_path!(file_path, base_dir = nil)
          raise SecurityError, "File path cannot be empty" if file_path.nil? || file_path.strip.empty?

          # Check path traversal - check original path before normalization
          if file_path.include?("..")
            raise SecurityError, "Path contains '..', potential path traversal risk: #{file_path}"
          end

          # Check repeated ./ patterns (like ./././etc/passwd)
          if file_path.match?(%r{^\./}) || file_path.match?(%r{/\./})
            raise SecurityError, "Path contains suspicious ./ pattern, potential path traversal risk: #{file_path}"
          end

          # Check absolute path
          raise SecurityError, "Absolute path not allowed: #{file_path}" if File.absolute_path?(file_path) && base_dir

          # If base directory specified, check if path is within it
          if base_dir
            full_path = File.expand_path(file_path, base_dir)
            expanded_base = File.expand_path(base_dir)

            unless full_path.start_with?(expanded_base)
              raise SecurityError, "Path exceeds base directory scope: #{file_path}"
            end
          end

          true
        end

        # Safely normalize path
        # @param file_path [String]
        # @return [String]
        def normalize_path(file_path)
          # Remove leading slashes and dots
          path = file_path.to_s.gsub(%r{^[/.]+}, "")
          # Merge multiple slashes
          path = path.gsub(%r{/+}, "/")
          # Remove trailing slash
          path.chomp("/")
        end

        # Check if file size is within limit
        # @param file_path [String] File path
        # @param max_size [Integer] Maximum bytes
        # @return [Boolean]
        def safe_file_size?(file_path, max_size = MAX_FILE_SIZE)
          return true unless File.exist?(file_path)

          File.size(file_path) <= max_size
        end

        # Check if content size is within limit
        # @param content [String] File content
        # @param max_size [Integer] Maximum bytes
        # @return [Boolean]
        def safe_content_size?(content, max_size = MAX_FILE_SIZE)
          return true if content.nil?

          content.bytesize <= max_size
        end

        # Check if file is a symbolic link
        # @param file_path [String]
        # @return [Boolean]
        def symlink?(file_path)
          File.symlink?(file_path)
        end

        # Safely read file (skip symbolic links)
        # @param file_path [String]
        # @return [String, nil]
        def safe_read(file_path)
          return nil if symlink?(file_path)
          return nil unless File.exist?(file_path)
          return nil unless safe_file_size?(file_path)

          File.read(file_path)
        end

        # Check if file is binary (based on extension)
        # @param file_path [String]
        # @return [Boolean]
        def binary_file?(file_path)
          ext = File.extname(file_path).downcase
          BINARY_EXTENSIONS.include?(ext)
        end

        # Check if content is binary (based on byte analysis)
        # @param content [String]
        # @return [Boolean]
        def binary_content?(content)
          return false if content.nil? || content.empty?

          # Check first 8KB for null bytes
          sample = content.byteslice(0, 8192)
          sample.include?("\x00")
        end

        # Detect file encoding
        # @param content [String]
        # @return [String] Encoding name
        def detect_encoding(content)
          return "UTF-8" if content.nil? || content.empty?

          # Try UTF-8
          return "UTF-8" if content.valid_encoding? && (content.encoding == Encoding::UTF_8)

          # Try common encodings
          %w[UTF-8 ISO-8859-1 Windows-1252 ASCII-8BIT].each do |enc|
            encoded = content.force_encoding(enc)
            return enc if encoded.valid_encoding?
          rescue StandardError
            next
          end

          "BINARY"
        end

        # Safely write file (atomic write)
        # @param file_path [String] Target path
        # @param content [String] Content
        # @param base_dir [String, nil] Base directory
        # @return [Boolean] Whether successful
        def safe_write(file_path, content, base_dir: nil)
          validate_path!(file_path, base_dir)
          return false unless safe_content_size?(content)

          # Create temporary file
          tmp_path = "#{file_path}.tmp.#{Process.pid}"

          begin
            FileUtils.mkdir_p(File.dirname(file_path))
            File.write(tmp_path, content)
            FileUtils.mv(tmp_path, file_path)
            true
          rescue StandardError => e
            File.delete(tmp_path) if File.exist?(tmp_path)
            raise e
          end
        end

        # Safely delete file
        # @param file_path [String]
        # @param base_dir [String, nil]
        # @return [Boolean]
        def safe_delete(file_path, base_dir: nil)
          validate_path!(file_path, base_dir)
          return false if symlink?(file_path)

          if File.exist?(file_path)
            File.delete(file_path)
            true
          else
            false
          end
        end
      end
    end
  end
end
