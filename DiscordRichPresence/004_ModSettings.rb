#===============================================================================
# Discord Rich Presence - 004_ModSettings.rb
# Registers mod settings into ModSettingsMenu (Options > Mods)
#===============================================================================
module DiscordRichPresence
  MOD_FOLDER_ID = (defined?(KIF::Mods) && KIF::Mods.respond_to?(:current) && KIF::Mods.current) ? KIF::Mods.current : "DiscordRichPresence"

  SPRITE_STYLES = ["showdown", "pixel", "artwork"].freeze
  TIME_MODES    = ["session", "playtime", "off"].freeze

  def self.init_game_settings
    init_mod_settings_menu
    sync_config_to_game
  rescue StandardError => e
    log("Failed to initialize game settings UI: #{e.class}: #{e.message}") rescue nil
  end

  def self.sprite_style_index
    idx = SPRITE_STYLES.index(get_setting("leader_sprite_style", "showdown").to_s.downcase)
    idx || 0
  end

  def self.time_mode_index
    return 2 unless get_bool_setting("show_elapsed_time", true)
    idx = TIME_MODES.index(get_setting("elapsed_time_mode", "session").to_s.downcase)
    idx || 0
  end

  def self.trigger_manual_reconnect
    ok, uname = reconnect_now
    if ok
      who = (uname && !uname.to_s.empty?) ? " as #{uname}" : ""
      pbMessage(_INTL("Connected to Discord{1}! Rich Presence updated.", who)) if defined?(pbMessage)
    else
      pbMessage(_INTL("Could not connect to Discord desktop client. Make sure Discord is open on your PC.")) if defined?(pbMessage)
    end
  rescue StandardError
    nil
  end

  def self.init_mod_settings_menu
    return unless defined?(ModSettingsMenu) && ModSettingsMenu.respond_to?(:register)

    cat = "Discord RPC"
    mod_id = MOD_FOLDER_ID

    ModSettingsMenu.register(:kif_rpc_enabled,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Discord RPC",
      :description => "Enable or disable Discord Rich Presence broadcasting",
      :default => 1, :on_change => proc { |v| DiscordRichPresence.set_setting("rpc_enabled", v == 1, :kif_rpc_enabled, v) }
    )

    ModSettingsMenu.register(:kif_rpc_primary_image,
      :mod => mod_id, :category => cat, :type => :enum, :name => "Primary Image",
      :values => ["Leader Sprite", "Location Art"],
      :description => "Leader Sprite shows Pokémon full-size; Location Art shows scenery full-size",
      :default => 0, :on_change => proc { |v| DiscordRichPresence.set_setting("primary_image", v == 1 ? "location" : "leader", :kif_rpc_primary_image, v) }
    )

    ModSettingsMenu.register(:kif_rpc_sprite_style,
      :mod => mod_id, :category => cat, :type => :enum, :name => "Unfused Sprite Style",
      :values => ["Animated", "Pixel", "Artwork"],
      :description => "Sprite style for unfused Pokémon (fusions always use custom fusion sprites)",
      :default => 0, :on_change => proc { |v|
        style = DiscordRichPresence::SPRITE_STYLES[v.to_i] || "showdown"
        DiscordRichPresence.set_setting("leader_sprite_style", style, :kif_rpc_sprite_style, v.to_i)
      }
    )

    ModSettingsMenu.register(:kif_rpc_location_art,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Location Artwork",
      :description => "Display stylized pixel art scenes of your current town, gym, dungeon, or route",
      :default => 1, :on_change => proc { |v| DiscordRichPresence.set_setting("show_location_art", v == 1, :kif_rpc_location_art, v) }
    )

    ModSettingsMenu.register(:kif_rpc_leader_details,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Leader Breakdown",
      :description => "Show fused Head + Body Pokémon names or typing when hovering on the leader sprite",
      :default => 1, :on_change => proc { |v| DiscordRichPresence.set_setting("show_leader_details", v == 1, :kif_rpc_leader_details, v) }
    )

    ModSettingsMenu.register(:kif_rpc_show_badges,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Show Badges",
      :description => "Show gym badge count in the Discord status line",
      :default => 1, :on_change => proc { |v| DiscordRichPresence.set_setting("show_badges", v == 1, :kif_rpc_show_badges, v) }
    )

    ModSettingsMenu.register(:kif_rpc_show_pokedex,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Show Pokédex",
      :description => "Show Pokédex catches in the Discord status line",
      :default => 1, :on_change => proc { |v| DiscordRichPresence.set_setting("show_pokedex", v == 1, :kif_rpc_show_pokedex, v) }
    )

    ModSettingsMenu.register(:kif_rpc_show_shinies,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Show Shinies",
      :description => "Show total caught shiny Pokémon in the Discord status line",
      :default => 1, :on_change => proc { |v| DiscordRichPresence.set_setting("show_shinies_count", v == 1, :kif_rpc_show_shinies, v) }
    )

    ModSettingsMenu.register(:kif_rpc_show_fusions,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Show Fusions",
      :description => "Show total fusions in the Discord status line",
      :default => 1, :on_change => proc { |v| DiscordRichPresence.set_setting("show_fusions_count", v == 1, :kif_rpc_show_fusions, v) }
    )

    ModSettingsMenu.register(:kif_rpc_show_money,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Show Money",
      :description => "Show money balance in the Discord status line",
      :default => 0, :on_change => proc { |v| DiscordRichPresence.set_setting("show_money", v == 1, :kif_rpc_show_money, v) }
    )

    ModSettingsMenu.register(:kif_rpc_show_battle,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Battle Opponent Info",
      :description => "Show trainer opponent or wild Pokémon name during battles",
      :default => 1, :on_change => proc { |v| DiscordRichPresence.set_setting("show_battle_status", v == 1, :kif_rpc_show_battle, v) }
    )

    ModSettingsMenu.register(:kif_rpc_show_mode,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Show Game Mode",
      :description => "Show game mode, difficulty, and active challenges in hover tooltip",
      :default => 1, :on_change => proc { |v| DiscordRichPresence.set_setting("show_game_mode", v == 1, :kif_rpc_show_mode, v) }
    )

    ModSettingsMenu.register(:kif_rpc_show_challenge,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Show Challenge in Text",
      :description => "Show active challenge (Nuzlocke, Soul Link, etc.) in the Discord status text line",
      :default => 0, :on_change => proc { |v| DiscordRichPresence.set_setting("show_challenge_in_state", v == 1, :kif_rpc_show_challenge, v) }
    )

    ModSettingsMenu.register(:kif_rpc_show_session,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Show Session Type",
      :description => "Show Solo or Co-op session status in hover tooltip",
      :default => 1, :on_change => proc { |v| DiscordRichPresence.set_setting("show_session_info", v == 1, :kif_rpc_show_session, v) }
    )

    ModSettingsMenu.register(:kif_rpc_coop_partner_orb,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Co-op Leader Orb",
      :description => "Display co-op partner's team leader Pokémon sprite in the small corner orb",
      :default => 1, :on_change => proc { |v| DiscordRichPresence.set_setting("show_coop_partner_orb", v == 1, :kif_rpc_coop_partner_orb, v) }
    )

    ModSettingsMenu.register(:kif_rpc_show_coop,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Co-op Leader in Text",
      :description => "Show co-op partner's team leader and fusion breakdown in the status text line",
      :default => 0, :on_change => proc { |v| DiscordRichPresence.set_setting("show_coop_in_state", v == 1, :kif_rpc_show_coop, v) }
    )

    ModSettingsMenu.register(:kif_rpc_time_mode,
      :mod => mod_id, :category => cat, :type => :enum, :name => "Elapsed Timer",
      :values => ["Session Time", "Save Playtime", "Off"],
      :description => "Show current session time, total save playtime, or hide elapsed timer",
      :default => 0, :on_change => proc { |v|
        idx = v.to_i
        mode = DiscordRichPresence::TIME_MODES[idx] || "session"
        DiscordRichPresence.config["show_elapsed_time"] = (mode != "off")
        DiscordRichPresence.set_setting("elapsed_time_mode", mode, :kif_rpc_time_mode, idx)
      }
    )

    ModSettingsMenu.register(:kif_rpc_leader_in_state,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Leader in Status Text",
      :description => "Also show your party leader name and level in the text status line",
      :default => 0, :on_change => proc { |v| DiscordRichPresence.set_setting("show_party_leader_in_state", v == 1, :kif_rpc_leader_in_state, v) }
    )

    ModSettingsMenu.register(:kif_rpc_nuzlocke,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Nuzlocke Tracker",
      :description => "Show Nuzlocke losses and deaths in status line (off by default)",
      :default => 0, :on_change => proc { |v| DiscordRichPresence.set_setting("show_nuzlocke_tracker", v == 1, :kif_rpc_nuzlocke, v) }
    )

    ModSettingsMenu.register(:kif_rpc_level_cap,
      :mod => mod_id, :category => cat, :type => :toggle, :name => "Level Cap Indicator",
      :description => "Show active gym level cap in status line when level caps are enabled",
      :default => 0, :on_change => proc { |v| DiscordRichPresence.set_setting("show_level_cap", v == 1, :kif_rpc_level_cap, v) }
    )

    ModSettingsMenu.register(:kif_rpc_reconnect,
      :mod => mod_id, :category => cat, :type => :button, :name => "Reconnect Discord",
      :description => "Reconnect to Discord desktop client and refresh Rich Presence immediately",
      :on_press => proc { DiscordRichPresence.trigger_manual_reconnect }
    )
  end

  def self.sync_config_to_game
    return unless defined?(ModSettingsMenu) && ModSettingsMenu.respond_to?(:set)
    cfg = @config || DEFAULT_CONFIG
    mapping = [
      [:kif_rpc_enabled,          cfg["rpc_enabled"] == false ? 0 : 1],
      [:kif_rpc_primary_image,    cfg["primary_image"].to_s == "location" ? 1 : 0],
      [:kif_rpc_sprite_style,     sprite_style_index],
      [:kif_rpc_location_art,     cfg["show_location_art"] == false ? 0 : 1],
      [:kif_rpc_leader_details,   cfg["show_leader_details"] == false ? 0 : 1],
      [:kif_rpc_show_badges,      cfg["show_badges"] == false ? 0 : 1],
      [:kif_rpc_show_pokedex,     cfg["show_pokedex"] == false ? 0 : 1],
      [:kif_rpc_show_shinies,     cfg["show_shinies_count"] == false ? 0 : 1],
      [:kif_rpc_show_fusions,     cfg["show_fusions_count"] == false ? 0 : 1],
      [:kif_rpc_show_money,       cfg["show_money"] == true ? 1 : 0],
      [:kif_rpc_show_battle,      cfg["show_battle_status"] == false ? 0 : 1],
      [:kif_rpc_show_mode,        cfg["show_game_mode"] == false ? 0 : 1],
      [:kif_rpc_show_challenge,   cfg["show_challenge_in_state"] == true ? 1 : 0],
      [:kif_rpc_show_session,     cfg["show_session_info"] == false ? 0 : 1],
      [:kif_rpc_coop_partner_orb, cfg["show_coop_partner_orb"] == false ? 0 : 1],
      [:kif_rpc_show_coop,        cfg["show_coop_in_state"] == true ? 1 : 0],
      [:kif_rpc_time_mode,        time_mode_index],
      [:kif_rpc_leader_in_state,  cfg["show_party_leader_in_state"] == true ? 1 : 0],
      [:kif_rpc_nuzlocke,         cfg["show_nuzlocke_tracker"] == true ? 1 : 0],
      [:kif_rpc_level_cap,        cfg["show_level_cap"] == true ? 1 : 0]
    ]

    mapping.each do |mod_key, val|
      ModSettingsMenu.set(mod_key, val) rescue nil
    end
  rescue StandardError
    nil
  end
end

begin
  DiscordRichPresence.init_game_settings
rescue StandardError
  nil
end
