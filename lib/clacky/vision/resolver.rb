# frozen_string_literal: true

require "digest"
require "base64"
require "fileutils"
require "json"
require_relative "../utils/file_processor"

module Clacky
  module Vision
    # OCR sidecar — turns image bytes into a text description by calling a
    # vision-capable model. Used when the user's primary model is text-only
    # (e.g. DeepSeek V4) so that uploaded images and tool screenshots still
    # reach the conversation as useful context.
    #
    # Routes through Clacky::Client so we get the same OpenAI/Anthropic/
    # Bedrock format negotiation, retry, and credit-error handling as the
    # main agent path. Image content travels as a canonical `image_url`
    # block (the unified internal shape understood by all three formats).
    class Resolver
      DEFAULT_PROMPT = <<~PROMPT.strip
        Extract every legible text and describe the visual content of this image.
        Output as Markdown. Preserve table layout where possible (use Markdown tables).
        For UI screenshots, describe the layout, visible labels, and active state.
        Be thorough but concise — the user cannot see the image and must rely on
        your description.
      PROMPT

      MAX_TOKENS = 2048
      CACHE_DIR  = File.join(Dir.home, ".clacky", "ocr_cache")
      CACHE_VERSION = 1

      class << self
        # Convenience entry-point. Looks up the configured OCR sidecar and
        # invokes #describe. Returns nil when no sidecar is available
        # (caller falls back to today's "no vision" behaviour).
        # @param agent_config [Clacky::AgentConfig]
        # @param image [Hash] one of:
        #   { data_url: "data:image/png;base64,..." }
        #   { path: "/abs/path.png" }
        #   { bytes: "<binary>", mime_type: "image/png" }
        # @param prompt [String, nil] override prompt (caching key includes it)
        # @return [String, nil] description text, or nil on unavailable/error
        def describe(agent_config:, image:, prompt: nil)
          entry = agent_config.find_model_by_type("ocr")
          return nil unless entry
          new(entry).describe(image, prompt: prompt)
        end
      end

      def initialize(model_entry)
        @model_entry = model_entry
        @model       = model_entry["model"]
        @base_url    = model_entry["base_url"]
        @api_key     = model_entry["api_key"]
        @anthropic   = !!model_entry["anthropic_format"]
      end

      # @return [String, nil] description, or nil on failure (logged)
      def describe(image, prompt: nil)
        prompt = prompt.to_s.strip
        prompt = DEFAULT_PROMPT if prompt.empty?

        bytes, mime = read_image(image)
        return nil unless bytes && !bytes.empty?

        cached = cache_get(bytes, prompt)
        return cached if cached

        text = call_vlm(bytes, mime, prompt)
        return nil if text.nil? || text.strip.empty?

        cache_put(bytes, prompt, text)
        text
      rescue => e
        Clacky::Logger.warn("[Vision::Resolver] failed: #{e.class}: #{e.message}") if defined?(Clacky::Logger)
        nil
      end

      private def read_image(image)
        if image[:bytes]
          [image[:bytes], image[:mime_type] || "image/png"]
        elsif image[:data_url] || image["data_url"]
          url = image[:data_url] || image["data_url"]
          m = url.match(/\Adata:([^;]+);base64,(.*)\z/m)
          return [nil, nil] unless m
          [Base64.decode64(m[2]), m[1]]
        elsif image[:path] || image["path"]
          path = image[:path] || image["path"]
          return [nil, nil] unless File.exist?(path)
          [File.binread(path), Utils::FileProcessor.detect_mime_type(path, nil) || "image/png"]
        else
          [nil, nil]
        end
      end

      private def call_vlm(bytes, mime, prompt)
        data_url = "data:#{mime};base64,#{Base64.strict_encode64(bytes)}"
        message = {
          role: "user",
          content: [
            { type: "text", text: prompt },
            { type: "image_url", image_url: { url: data_url } }
          ]
        }

        client = Clacky::Client.new(
          @api_key,
          base_url: @base_url,
          model: @model,
          anthropic_format: @anthropic
        )
        response = client.send_messages([message], model: @model, max_tokens: MAX_TOKENS)
        extract_text(response)
      end

      # Client#send_messages returns the raw upstream string for OpenAI/Anthropic;
      # for Bedrock it returns the parsed text content. Normalise to String.
      private def extract_text(response)
        case response
        when String then response
        when Hash   then response[:content] || response["content"] || response.to_s
        else response.to_s
        end
      end

      # ── Cache ─────────────────────────────────────────────────────────────

      private def cache_key(bytes, prompt)
        sha = Digest::SHA256.hexdigest(bytes)
        prompt_sha = Digest::SHA256.hexdigest(prompt)[0, 12]
        "#{sha}_#{@model.gsub(/[^A-Za-z0-9_.-]/, '_')}_#{prompt_sha}"
      end

      private def cache_path(key)
        File.join(CACHE_DIR, "#{key}.json")
      end

      private def cache_get(bytes, prompt)
        path = cache_path(cache_key(bytes, prompt))
        return nil unless File.exist?(path)
        data = JSON.parse(File.read(path))
        return nil unless data["v"] == CACHE_VERSION
        data["text"]
      rescue JSON::ParserError, Errno::ENOENT
        nil
      end

      private def cache_put(bytes, prompt, text)
        FileUtils.mkdir_p(CACHE_DIR)
        path = cache_path(cache_key(bytes, prompt))
        File.write(path, JSON.generate({
          "v"     => CACHE_VERSION,
          "model" => @model,
          "text"  => text,
          "ts"    => Time.now.to_i
        }))
      rescue => _
        # Cache is best-effort — never fail the request because we can't write.
        nil
      end
    end
  end
end
