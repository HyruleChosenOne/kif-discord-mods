#==============================================================================
# Kanto Reloaded Logging
#==============================================================================

module KantoReloaded
  module Log
    ROOT = File.expand_path(File.join(File.dirname(__FILE__), "..", ".."))
    GAME_ROOT = File.expand_path(File.join(ROOT, "..", ".."))
    LOG_DIR = File.join(ROOT, "Logging")
    MAIN_LOG = File.join(LOG_DIR, "Log.txt")
    PREVIOUS_LOG = File.join(LOG_DIR, "Log.previous.txt")
    MAX_LOG_BYTES = 2 * 1024 * 1024
    LEVELS = [:debug, :info, :warning, :error, :critical, :fatal].freeze
    @once = {}

    class << self
      def debug(message, channel = :framework); write(channel, message, :level => :debug); end
      def info(message, channel = :framework); write(channel, message, :level => :info); end
      def warning(message, channel = :framework); write(channel, message, :level => :warning); end
      def error(message, channel = :framework); write(channel, message, :level => :error); end
      def critical(message, channel = :framework); write(channel, message, :level => :critical); end
      def fatal(message, channel = :framework); write(channel, message, :level => :fatal); end

      def debug_once(message, channel = :framework, key: nil); write_once(channel, message, :level => :debug, :key => key); end
      def info_once(message, channel = :framework, key: nil); write_once(channel, message, :level => :info, :key => key); end
      def warning_once(message, channel = :framework, key: nil); write_once(channel, message, :level => :warning, :key => key); end
      def error_once(message, channel = :framework, key: nil); write_once(channel, message, :level => :error, :key => key); end

      def write(channel, message, level: :info)
        normalized_level = normalize_level(level)
        line = "[#{timestamp}] [#{normalized_level.to_s.upcase}] [#{sanitize(channel)}] #{sanitize(message)}"
        ensure_log_dir
        rotate_main_log_if_needed(line.bytesize + 2)
        File.open(MAIN_LOG, "a") { |file| file.puts(line) }
        if [:warning, :error, :critical, :fatal].include?(normalized_level)
          echoln(line) rescue nil
        end
        line
      rescue
        nil
      end

      def write_once(channel, message, level: :info, key: nil)
        signature = sanitize(key || "#{channel}:#{level}:#{message}")
        return nil if @once[signature]
        @once[signature] = true
        write(channel, message, :level => level)
      end

      def exception(message, exception, channel: :framework, level: :error)
        write(channel, "#{message}: #{exception.class}: #{exception.message}", :level => level)
        Array(exception.backtrace).first(8).each do |line|
          write(channel, "  #{line}", :level => level)
        end
      end

      def summary(values = {})
        text = values.map { |key, value| "#{key}=#{value}" }.join(" ")
        info(text, :summary)
        values
      end

      # C:/Users/<name>, /home/<name> or /Users/<name> at the start of the
      # save folder, or nil
      def home_folder
        save = defined?(System) && System.respond_to?(:data_directory) ? (System.data_directory.to_s rescue "") : ""
        m = save.tr("\\", "/").match(%r{\A((?:[A-Za-z]:)?/(?:Users|home)/[^/]+)}i)
        return m ? m[1] : nil
      end

      def sanitize(value)
        text = value.to_s.gsub("\\", "/")
        replacements = []
        replacements << [File.expand_path(ROOT).gsub("\\", "/"), "/#{File.basename(ROOT)}"]
        replacements << [File.expand_path(GAME_ROOT).gsub("\\", "/"), "/Game"]
        # the home folder, from where the saves are (nothing of the
        # computer's settings is read: KIF 2.0.0's Mod Safety)
        home = home_folder
        replacements << [home, "/User"] if home
        replacements.sort_by { |entry| -entry[0].length }.each do |root, replacement|
          next if root.empty?
          text = text.gsub(/#{Regexp.escape(root)}(?=\/|\z)/i, replacement)
        end
        text = text.gsub(
          /(authorization\s*[:=]\s*)(?:bearer\s+)?[^\s,;]+/i,
          '\1[REDACTED]'
        )
        text = text.gsub(
          /((?:access[_ -]?token|refresh[_ -]?token|api[_ -]?key|password|secret)\s*[:=]\s*)([^\s,;]+)/i,
          '\1[REDACTED]'
        )
        text = text.gsub(
          /([?&](?:token|key|auth|code|password|secret)=)[^&\s]+/i,
          '\1[REDACTED]'
        )
        text = text.gsub(
          %r{https://(?:canary\.|ptb\.)?discord(?:app)?\.com/api/webhooks/\d+/[^\s]+}i,
          "https://discord.com/api/webhooks/[REDACTED]"
        )
        text.gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
      rescue
        value.to_s
      end

      private

      def ensure_log_dir
        Dir.mkdir(LOG_DIR) unless Dir.exist?(LOG_DIR)
      rescue
        nil
      end

      def rotate_main_log_if_needed(incoming_bytes)
        return unless File.file?(MAIN_LOG)
        return if File.size(MAIN_LOG).to_i + incoming_bytes.to_i <= MAX_LOG_BYTES
        File.delete(PREVIOUS_LOG) if File.file?(PREVIOUS_LOG)
        File.rename(MAIN_LOG, PREVIOUS_LOG)
      rescue
        nil
      end

      def normalize_level(level)
        value = level.to_s.downcase.to_sym
        LEVELS.include?(value) ? value : :info
      end

      def timestamp
        Time.now.strftime("%Y-%m-%d %H:%M:%S")
      rescue
        "unknown"
      end

    end
  end
end
