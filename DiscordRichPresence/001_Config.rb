#===============================================================================
# Discord Rich Presence - 001_Config.rb
# Configuration management, JSON serialization, and ModSettingsMenu sync
#===============================================================================
module DiscordRichPresence
  DEFAULT_CONFIG = {
    "client_id"                  => "1569904868767047821",
    "rpc_enabled"                => true,
    "update_interval"            => 10,
    "primary_image"              => "leader",
    "large_image_key"            => "icon",
    "large_image_text"           => "Kuray's Infinite Fusion",
    "show_zone"                  => true,
    "show_location_art"          => true,
    "show_badges"                => true,
    "show_pokedex"               => true,
    "show_shinies_count"         => true,
    "show_fusions_count"         => true,
    "show_money"                 => false,
    "show_party_leader_in_state" => false,
    "show_leader_sprite"         => true,
    "show_leader_details"        => true,
    "leader_sprite_style"        => "showdown",
    "stat_separator"             => " • ",
    "shiny_label"                => "★ Shinies",
    "fusion_label"               => "Fusions",
    "fusion_count_source"        => "auto",
    "show_battle_status"         => true,
    "show_game_mode"             => true,
    "show_challenge_in_state"    => false,
    "show_nuzlocke_tracker"      => false,
    "show_level_cap"             => false,
    "show_coop_partner_orb"      => true,
    "show_coop_in_state"         => false,
    "show_session_info"          => true,
    "show_elapsed_time"          => true,
    "elapsed_time_mode"          => "session"
  }.freeze

  @config = DEFAULT_CONFIG.dup
  @mod_dir = nil

  def self.mod_dir
    @mod_dir ||= File.expand_path(File.dirname(__FILE__))
  end

  def self.config_path
    File.join(mod_dir, "config.json")
  end

  def self.config
    @config
  end

  def self.log_path
    File.join(mod_dir, "rpc.log")
  end

  def self.log(msg)
    time_str = Time.now.strftime("%H:%M:%S")
    formatted = "[#{time_str}] #{msg}"
    echoln("[DiscordRPC] #{msg}") if defined?(echoln)
    File.open(log_path, "a") { |f| f.puts(formatted) } rescue nil
  end

  def self.init_log
    File.open(log_path, "w") { |f| f.puts("[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] Discord Rich Presence v1.2.0 initialized") } rescue nil
  end

  def self.load_config
    path = config_path
    if File.exist?(path)
      content = (File.read(path, encoding: "UTF-8") rescue nil)
      if content && !content.empty?
        parsed = parse_json(content)
        if parsed.is_a?(Hash)
          @config = DEFAULT_CONFIG.merge(parsed)
          return @config
        end
      end
    end
    save_config(DEFAULT_CONFIG)
    @config = DEFAULT_CONFIG.dup
  end

  def self.save_config(cfg = @config)
    path = config_path
    json_str = to_json(cfg)
    File.open(path, "wb") { |f| f.write(json_str + "\n") } rescue nil
  end

  def self.get_bool_setting(key, default = false)
    v = @config ? @config[key.to_s] : nil
    return (v == true || v == 1) unless v.nil?
    default
  rescue StandardError
    default
  end

  def self.get_setting(key, default = nil)
    v = @config ? @config[key.to_s] : nil
    return v unless v.nil?
    default
  rescue StandardError
    default
  end

  def self.set_setting(key, value, mod_key = nil, mod_val = nil)
    @config[key.to_s] = value if @config
    if mod_key && defined?(ModSettingsMenu) && ModSettingsMenu.respond_to?(:set)
      v_num = mod_val.nil? ? (value == true ? 1 : (value == false ? 0 : value)) : mod_val
      ModSettingsMenu.set(mod_key, v_num) rescue nil
    end
    save_config rescue nil
    snapshot_activity rescue nil
  end

  def self.parse_json(str)
    if defined?(KIF::Mods::MiniJSON) && KIF::Mods::MiniJSON.respond_to?(:parse)
      res = (KIF::Mods::MiniJSON.parse(str) rescue nil)
      return res if res.is_a?(Hash)
    end
    if defined?(::JSON) && ::JSON.respond_to?(:parse)
      return ::JSON.parse(str) rescue nil
    end
    nil
  end

  def self.to_json(obj)
    case obj
    when Hash
      items = obj.map { |k, v| "  #{to_json(k.to_s)}: #{to_json(v)}" }
      "{\n#{items.join(",\n")}\n}"
    when Array
      "[" + obj.map { |v| to_json(v) }.join(", ") + "]"
    when String
      "\"#{escape_json_string(obj)}\""
    when Numeric, true, false
      obj.to_s
    when nil
      "null"
    else
      "\"#{escape_json_string(obj.to_s)}\""
    end
  end

  def self.escape_json_string(str)
    str.to_s.gsub(/["\\]/) { |m| "\\#{m}" }
      .gsub("\n", "\\n")
      .gsub("\t", "\\t")
      .gsub("\r", "\\r")
  end
end
