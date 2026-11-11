#===============================================================================
# Discord Rich Presence - 003_Presence.rb
# Gathers read-only game information and broadcasts it to Discord IPC
#===============================================================================
module DiscordRichPresence
  @client = nil
  @worker_thread = nil
  @running = false
  @mutex = Mutex.new
  @current_activity = nil
  @last_activity = nil
  @last_send_time = 0
  @start_time = nil
  @battle_context = nil
  @battle_is_wild_fusion = false
  @last_known_partner_data = nil

  @cached_shiny_count = 0
  @cached_shiny_time = 0
  @cached_fusion_count = 0
  @cached_fusion_time = 0

  class << self
    attr_reader :client, :running, :start_time
    attr_accessor :battle_context, :battle_is_wild_fusion
  end

  def self.start
    return if @running

    load_config
    init_log
    log("Mod started. Update interval: #{(@config && @config["update_interval"]) || 10}s")
    @client = PipeClient.new
    @running = true
    @start_time ||= Time.now.to_i
    @last_activity = nil
    @last_send_time = 0
    @battle_context = nil
    @battle_is_wild_fusion = false
    @mutex ||= Mutex.new

    register_events
    register_timer
    start_worker
  end

  def self.stop
    @running = false
    if @worker_thread && @worker_thread.alive?
      @worker_thread.kill rescue nil
      @worker_thread = nil
    end
    if @client
      @client.clear_activity rescue nil
      @client.close rescue nil
    end
  end

  def self.reconnect_now
    cfg = @config || DEFAULT_CONFIG
    client_id = cfg["client_id"] || DEFAULT_CONFIG["client_id"]
    @client ||= PipeClient.new
    @client.close rescue nil
    invalidate_caches
    if @client.connect(client_id)
      act = snapshot_activity
      if act && get_bool_setting("rpc_enabled", true)
        @client.send_activity(act)
        @last_activity = act
        @last_send_time = Time.now.to_i
      end
      return [true, @client.username]
    end
    [false, nil]
  rescue StandardError
    [false, nil]
  end

  def self.invalidate_caches
    @cached_shiny_time = 0
    @cached_fusion_time = 0
  end

  def self.register_events
    return unless defined?(KIF::API) && KIF::API.respond_to?(:on)

    KIF::API.on(:game_loaded, "discord_rpc_game_loaded") do |_ctx|
      DiscordRichPresence.invalidate_caches
      DiscordRichPresence.snapshot_activity
    end

    KIF::API.on(:game_new, "discord_rpc_game_new") do |_ctx|
      DiscordRichPresence.invalidate_caches
      DiscordRichPresence.snapshot_activity
    end

    KIF::API.on(:map_changed, "discord_rpc_map") do |_ctx|
      DiscordRichPresence.snapshot_activity
    end

    KIF::API.on(:battle_start, "discord_rpc_battle_start") do |ctx|
      DiscordRichPresence.capture_battle_context(ctx)
      DiscordRichPresence.snapshot_activity
    end

    KIF::API.on(:battle_ended, "discord_rpc_battle_end") do |_ctx|
      DiscordRichPresence.battle_context = nil
      DiscordRichPresence.battle_is_wild_fusion = false
      DiscordRichPresence.invalidate_caches
      DiscordRichPresence.snapshot_activity
    end

    KIF::API.on(:pokemon_added, "discord_rpc_pokemon_added") do |_ctx|
      DiscordRichPresence.invalidate_caches
      DiscordRichPresence.snapshot_activity
    end

    KIF::API.on(:fusion_done, "discord_rpc_fusion") do |_ctx|
      DiscordRichPresence.invalidate_caches
      DiscordRichPresence.snapshot_activity
    end

    KIF::API.on(:unfuse_done, "discord_rpc_unfuse") do |_ctx|
      DiscordRichPresence.invalidate_caches
      DiscordRichPresence.snapshot_activity
    end

    KIF::API.on(:level_changed, "discord_rpc_level") do |_ctx|
      DiscordRichPresence.snapshot_activity
    end
  rescue StandardError
    nil
  end

  def self.current_language_sym
    if defined?(getCurrentLanguage)
      lang = (getCurrentLanguage() rescue nil)
      return lang if lang && lang.is_a?(Symbol)
    end
    if defined?($PokemonSystem) && $PokemonSystem && $PokemonSystem.respond_to?(:language)
      lang = ($PokemonSystem.language rescue 0).to_i
      if defined?(Settings::LANGUAGES) && defined?(Settings::GAME_ID)
        langs = (Settings::LANGUAGES[Settings::GAME_ID] rescue nil)
        if langs && langs[lang]
          sym = (langs[lang][2] rescue nil)
          return sym if sym && sym.is_a?(Symbol)
        end
      end
      return :FRENCH if lang == 1
      return :FRENCH_QC if lang == 2
      return :CHINESE if lang == 3
    end
    :ENGLISH
  rescue StandardError
    :ENGLISH
  end

  def self.french_language?
    sym = current_language_sym
    sym == :FRENCH || sym == :FRENCH_QC
  end

  def self.localized_fusion_name(head_id, body_id)
    return nil unless head_id && body_id && head_id > 0 && body_id > 0

    head_dex = head_id
    body_dex = body_id
    if defined?(GameData::NAT_DEX_MAPPING) && GameData::NAT_DEX_MAPPING
      head_dex = GameData::NAT_DEX_MAPPING[head_id] || head_id
      body_dex = GameData::NAT_DEX_MAPPING[body_id] || body_id
    end

    split_names = nil
    case current_language_sym
    when :FRENCH
      split_names = GameData::SPLIT_NAMES_FRENCH if defined?(GameData::SPLIT_NAMES_FRENCH)
    when :CHINESE
      split_names = GameData::SPLIT_NAMES_CHINESE if defined?(GameData::SPLIT_NAMES_CHINESE)
    end
    split_names ||= (GameData::SPLIT_NAMES if defined?(GameData::SPLIT_NAMES))

    if split_names && split_names[head_dex] && split_names[body_dex]
      prefix = split_names[head_dex][0]
      suffix = split_names[body_dex][1]
      if prefix && suffix && !prefix.empty? && !suffix.empty?
        prefix = prefix[0..-2] if prefix[-1] == suffix[0]
        suffix = suffix.capitalize if prefix.end_with?(" ")
        return "#{prefix}#{suffix}"
      end
    end

    h_name = localized_species_name(head_id)
    b_name = localized_species_name(body_id)
    (h_name && b_name) ? "#{h_name}/#{b_name}" : nil
  rescue StandardError
    nil
  end

  def self.localized_species_name(species_or_id, ignore_nickname = false)
    return nil unless species_or_id

    if species_or_id.respond_to?(:species)
      if !ignore_nickname && species_or_id.respond_to?(:nicknamed?) && species_or_id.nicknamed?
        return species_or_id.name.to_s
      end
      if species_or_id.respond_to?(:head_id) && pokemon_fusion?(species_or_id)
        h_id = (species_or_id.head_id rescue nil)
        b_id = (species_or_id.body_id rescue nil)
        if h_id && b_id && h_id > 0 && b_id > 0
          fname = localized_fusion_name(h_id, b_id)
          return fname if fname && !fname.empty?
        end
        return (species_or_id.species_data.name rescue species_or_id.name).to_s
      end
      if species_or_id.respond_to?(:species_data) && species_or_id.species_data
        n = (species_or_id.species_data.name rescue nil)
        return n.to_s if n && !n.empty?
      end
      species_or_id = (species_or_id.species rescue species_or_id)
    end

    if defined?(GameData::Species) && species_or_id.is_a?(GameData::Species)
      n = (species_or_id.name rescue nil)
      return n.to_s if n && !n.empty?
      species_or_id = (species_or_id.id_number rescue species_or_id.id)
    end

    if species_or_id.is_a?(Symbol) || species_or_id.is_a?(String)
      str_spec = species_or_id.to_s
      if str_spec =~ /\AB(\d+)H(\d+)\z/i
        b_id = $1.to_i
        h_id = $2.to_i
        return localized_fusion_name(h_id, b_id) || "#{localized_species_name(h_id)}/#{localized_species_name(b_id)}"
      end
    end

    dex_num = nil
    if species_or_id.is_a?(Integer)
      dex_num = species_or_id
    elsif defined?(GameData::Species)
      sp = (GameData::Species.try_get(species_or_id) rescue (GameData::Species.get(species_or_id) rescue nil))
      if sp
        n = (sp.name rescue nil)
        return n.to_s if n && !n.empty?
        dex_num = (sp.id_number rescue nil)
      end
    end

    if dex_num && dex_num > 0
      if current_language_sym == :FRENCH_QC
        if defined?(GameData::Species)
          sp = (GameData::Species.get(dex_num) rescue nil)
          return sp.real_name.to_s if sp && sp.respond_to?(:real_name)
        end
      elsif defined?(MessageTypes) && defined?(MessageTypes::Species)
        msg = (MessageTypes.get(MessageTypes::Species, dex_num) rescue nil)
        return msg.to_s if msg && !msg.empty?
      end
    end

    if defined?(GameData::Species)
      sp = (GameData::Species.try_get(species_or_id) rescue (GameData::Species.get(species_or_id) rescue nil))
      if sp
        n = (sp.name rescue (sp.real_name rescue nil))
        return n.to_s if n && !n.empty?
      end
    end

    species_or_id.to_s
  rescue StandardError
    species_or_id.to_s
  end

  def self.fusion_breakdown_text(head_id, body_id)
    return nil unless head_id && body_id && head_id > 0 && body_id > 0
    h_name = localized_species_name(head_id)
    b_name = localized_species_name(body_id)
    (h_name && b_name) ? "#{h_name} + #{b_name}" : nil
  rescue StandardError
    nil
  end

  def self.localized_trainer_name(trainer)
    return nil unless trainer
    raw_name = (trainer.respond_to?(:name) ? trainer.name : nil) rescue nil
    raw_name = (trainer.respond_to?(:full_name) ? trainer.full_name : nil) if !raw_name || raw_name.to_s.strip.empty?
    return (raw_name ? raw_name.to_s : (french_language? ? "Dresseur" : "Trainer")) unless raw_name

    if defined?(MessageTypes::TrainerNames) && defined?(pbGetMessageFromHash)
      tr_name = (pbGetMessageFromHash(MessageTypes::TrainerNames, raw_name) rescue nil)
      return tr_name.to_s if tr_name && !tr_name.empty?
    end
    raw_name.to_s
  rescue StandardError
    (trainer.respond_to?(:name) ? trainer.name : trainer.to_s) rescue "Trainer"
  end

  def self.classify_trainer_role(trainer)
    return nil unless trainer
    tr_type = (trainer.respond_to?(:trainer_type) ? trainer.trainer_type : nil).to_s.upcase
    tr_name = (trainer.respond_to?(:name) ? trainer.name : "").to_s.upcase

    return nil if tr_type.include?("DEM") || tr_name.include?("DEM")

    if tr_type.include?("CHAMPION")
      return :champion
    elsif tr_type.include?("ELITEFOUR") || tr_type.include?("ELITE_FOUR")
      return :elite_four
    elsif tr_type.include?("LEADER")
      return :gym_leader
    elsif tr_type.include?("RIVAL")
      return :rival
    elsif tr_type.include?("ROCKETBOSS") || tr_type.include?("BOSS") || tr_type.include?("ROCKETEXEC")
      return :boss
    end

    if defined?(GameData::TrainerType) && trainer.respond_to?(:trainer_type)
      tt = (GameData::TrainerType.try_get(trainer.trainer_type) rescue nil)
      if tt
        real = (tt.real_name rescue "").to_s.downcase
        return :champion if real.include?("champion")
        return :elite_four if real.include?("elite four") || real.include?("elite")
        return :gym_leader if real.include?("leader")
        return :rival if real.include?("rival")
        return :boss if real.include?("boss") || real.include?("executive")
      end
    end

    nil
  rescue StandardError
    nil
  end

  def self.battle_format_tag(battle, ctx = nil)
    return "" unless battle || (ctx.is_a?(Hash) && ctx[:double])
    side0 = (battle.respond_to?(:pbSideSize) ? battle.pbSideSize(0) : 1) rescue 1
    side1 = (battle.respond_to?(:pbSideSize) ? battle.pbSideSize(1) : 1) rescue 1
    max_side = [side0.to_i, side1.to_i].max
    if max_side >= 3
      " [3v3]"
    elsif max_side == 2 || (ctx.is_a?(Hash) && (ctx[:double] rescue false))
      " [2v2]"
    else
      ""
    end
  rescue StandardError
    ""
  end

  def self.capture_battle_context(ctx)
    return unless ctx
    @battle_is_wild_fusion = false
    is_fr = french_language?
    battle = (ctx.is_a?(Hash) ? ctx[:battle] : nil) rescue nil
    format_suffix = battle_format_tag(battle, ctx)

    trainer = (ctx[:trainer] rescue nil) if ctx.is_a?(Hash)
    trainer ||= (battle.opponent rescue nil) if battle && battle.respond_to?(:opponent)

    if trainer
      if trainer.is_a?(Array)
        names = trainer.map { |t| localized_trainer_name(t) }.compact.uniq
        roles = trainer.map { |t| classify_trainer_role(t) }.compact
        if names.empty?
          @battle_context = (is_fr ? "Combat de dresseurs" : "Trainer Battle") + format_suffix
        else
          title_prefix = nil
          if roles.include?(:champion)
            title_prefix = is_fr ? "Match de Maître vs " : "Champion Match vs. "
          elsif roles.include?(:elite_four)
            title_prefix = is_fr ? "Conseil des 4 vs " : "Elite Four vs. "
          elsif roles.include?(:gym_leader)
            title_prefix = is_fr ? "Combat d'Arène vs " : "Gym Battle vs. "
          elsif roles.include?(:boss)
            title_prefix = is_fr ? "Combat de Boss vs " : "Boss Battle vs. "
          elsif roles.include?(:rival)
            title_prefix = is_fr ? "Combat de Rival vs " : "Rival Battle vs. "
          else
            title_prefix = is_fr ? "Vs " : "Vs. "
          end
          @battle_context = "#{title_prefix}#{names.join(' & ')}#{format_suffix}"
        end
      else
        t_name = localized_trainer_name(trainer)
        role = classify_trainer_role(trainer)
        title = nil
        case role
        when :gym_leader
          title = is_fr ? "Combat d'Arène vs #{t_name}" : "Gym Battle vs. #{t_name}"
        when :elite_four
          title = is_fr ? "Conseil des 4 vs #{t_name}" : "Elite Four vs. #{t_name}"
        when :champion
          title = is_fr ? "Match de Maître vs #{t_name}" : "Champion Match vs. #{t_name}"
        when :rival
          title = is_fr ? "Combat de Rival vs #{t_name}" : "Rival Battle vs. #{t_name}"
        when :boss
          title = is_fr ? "Combat de Boss vs #{t_name}" : "Boss Battle vs. #{t_name}"
        else
          title = (t_name && !t_name.empty?) ? (is_fr ? "Vs #{t_name}" : "Vs. #{t_name}") : (is_fr ? "Combat de dresseur" : "Trainer Battle")
        end
        @battle_context = "#{title}#{format_suffix}"
      end
      return
    end

    is_wild = false
    if ctx.is_a?(Hash)
      is_wild = !!ctx[:wild]
      is_wild ||= (battle.wildBattle? rescue false) if battle && battle.respond_to?(:wildBattle?)
    end

    if is_wild
      foes = (battle && battle.respond_to?(:pbParty) ? battle.pbParty(1) : nil) rescue nil
      foes ||= (battle.respond_to?(:party2) ? battle.party2 : nil) rescue nil
      foe = foes.is_a?(Array) ? foes.compact.first : nil
      if foe
        foe_name = localized_species_name(foe, true) || (foe.name rescue "Pokémon")
        foe_lvl = (foe.level rescue nil)
        shiny_star = pokemon_shiny?(foe) ? "★ " : ""
        fusion_part = ""
        if pokemon_fusion?(foe)
          h_id = (foe.head_id rescue nil)
          b_id = (foe.body_id rescue nil)
          bd = fusion_breakdown_text(h_id, b_id)
          if bd && !bd.empty?
            fusion_part = " • #{bd}"
            @battle_is_wild_fusion = true
          end
        end
        if foe_name && !foe_name.to_s.empty?
          if is_fr
            lvl_str = foe_lvl ? " (Niv. #{foe_lvl})" : ""
            @battle_context = "#{shiny_star}#{foe_name} sauvage#{lvl_str}#{format_suffix}#{fusion_part}"
          else
            lvl_str = foe_lvl ? " (Lv. #{foe_lvl})" : ""
            @battle_context = "Wild #{shiny_star}#{foe_name}#{lvl_str}#{format_suffix}#{fusion_part}"
          end
          return
        end
      end
      @battle_context = (is_fr ? "Combat sauvage" : "Wild Battle") + format_suffix
      return
    end

    @battle_context = (is_fr ? "En combat" : "In Battle") + format_suffix
  rescue StandardError
    @battle_context = french_language? ? "En combat" : "In Battle"
  end

  def self.register_timer
    if defined?(KIF::API) && KIF::API.respond_to?(:every)
      interval = [((@config && @config["update_interval"]) || 10).to_i, 5].max
      KIF::API.every(seconds: interval, scope: :always, id: "discord_rpc_tick") do
        snapshot_activity
      end
    end
  rescue StandardError
    nil
  end

  def self.snapshot_activity
    act = build_activity
    @mutex.synchronize { @current_activity = act } if @mutex
    act
  rescue StandardError
    nil
  end

  def self.start_worker
    return if @worker_thread && @worker_thread.alive?

    @worker_thread = Thread.new do
      while @running
        begin
          cfg = @config || DEFAULT_CONFIG
          interval = [cfg["update_interval"].to_i, 5].max
          client_id = cfg["client_id"] || DEFAULT_CONFIG["client_id"]

          unless get_bool_setting("rpc_enabled", true)
            if @client && @client.connected
              @client.clear_activity rescue nil
              @last_activity = nil
            end
            sleep 2
            next
          end

          unless @client && @client.connected
            @client.connect(client_id) if @client
          end

          if @client && @client.connected
            act = @mutex ? @mutex.synchronize { @current_activity } : nil
            act ||= snapshot_activity

            now = Time.now.to_i
            if act && (act != @last_activity || (now - @last_send_time >= 60))
              if @client.send_activity(act)
                @last_activity = act
                @last_send_time = now
              else
                @last_activity = nil
              end
            end
          end
        rescue StandardError
          nil
        end

        sleep_steps = interval
        while sleep_steps > 0 && @running
          sleep 1
          sleep_steps -= 1
        end
      end
    end

    @worker_thread.abort_on_exception = false
  rescue StandardError
    nil
  end

  def self.build_activity
    cfg = @config || DEFAULT_CONFIG

    if !defined?($Trainer) || $Trainer.nil?
      act = {}
      is_fr = french_language?
      act["details"] = is_fr ? "Menu principal" : "Main Menu"
      act["state"] = is_fr ? "Écran titre" : "Title Screen"
      ts = build_timestamps(cfg, false)
      act["timestamps"] = ts if ts
      assets = build_assets(cfg)
      act["assets"] = assets if assets && !assets.empty?
      return act
    end

    details = build_details(cfg)
    state = build_state(cfg)
    assets = build_assets(cfg)
    ts = build_timestamps(cfg, true)

    act = {}
    act["details"] = details[0, 128] if details && !details.empty?
    act["state"] = state[0, 128] if state && !state.empty?
    act["timestamps"] = ts if ts
    act["assets"] = assets if assets && !assets.empty?
    act
  rescue StandardError
    nil
  end

  def self.build_timestamps(cfg, in_save = false)
    return nil unless get_bool_setting("show_elapsed_time", true)
    mode = get_setting("elapsed_time_mode", "session").to_s.downcase
    return nil if mode == "off"

    if mode == "playtime" && in_save
      play_sec = current_save_playtime
      return { "start" => Time.now.to_i - play_sec } if play_sec && play_sec > 0
    end

    @start_time ? { "start" => @start_time } : nil
  rescue StandardError
    @start_time ? { "start" => @start_time } : nil
  end

  def self.current_save_playtime
    if defined?($Trainer) && $Trainer && $Trainer.respond_to?(:play_time) && $Trainer.play_time
      return $Trainer.play_time.to_i
    elsif defined?($PokemonGlobal) && $PokemonGlobal && $PokemonGlobal.respond_to?(:playtime) && $PokemonGlobal.playtime
      return $PokemonGlobal.playtime.to_i
    elsif defined?(Graphics) && Graphics.respond_to?(:frame_count) && defined?(Graphics.frame_rate)
      return (Graphics.frame_count / [Graphics.frame_rate.to_i, 40].max).to_i
    end
    nil
  rescue StandardError
    nil
  end

  def self.build_details(cfg)
    show_zone = get_bool_setting("show_zone", true)
    map_name = current_map_name if show_zone
    in_battle = (defined?($game_temp) && $game_temp && ($game_temp.in_battle rescue false))
    is_fr = french_language?

    if in_battle
      default_battle = is_fr ? "En combat" : "In Battle"
      if get_bool_setting("show_battle_status", true) && @battle_context && !@battle_context.empty?
        return @battle_context if @battle_is_wild_fusion || !map_name
        return "#{@battle_context} • #{map_name}"
      end
      return map_name ? "#{default_battle} • #{map_name}" : default_battle
    else
      @battle_context = nil
      @battle_is_wild_fusion = false
    end

    if map_name
      if defined?(pbInSafari?) && (pbInSafari? rescue false)
        return is_fr ? "Parc Safari • #{map_name}" : "Safari Zone • #{map_name}"
      end
      if defined?(pbInChallenge?) && (pbInChallenge? rescue false)
        return is_fr ? "Défi de Combat • #{map_name}" : "Battle Challenge • #{map_name}"
      end
      if defined?($game_player) && $game_player
        char_name = ($game_player.instance_variable_get(:@character_name).to_s rescue "")
        if char_name == "fish"
          return is_fr ? "Pêche • #{map_name}" : "Fishing • #{map_name}"
        end
      end
      if defined?($PokemonGlobal) && $PokemonGlobal
        if ($PokemonGlobal.bicycle rescue false)
          return is_fr ? "À vélo • #{map_name}" : "Cycling • #{map_name}"
        end
        if ($PokemonGlobal.surfing rescue false)
          return is_fr ? "En surf • #{map_name}" : "Surfing • #{map_name}"
        end
        if ($PokemonGlobal.diving rescue false)
          return is_fr ? "En plongée • #{map_name}" : "Diving • #{map_name}"
        end
      end
      return is_fr ? "Exploration : #{map_name}" : "Exploring #{map_name}"
    end

    is_fr ? "Exploration de la région" : "Exploring the Region"
  rescue StandardError
    french_language? ? "En jeu" : "In Game"
  end

  def self.build_state(cfg)
    parts = []
    sep = cfg["stat_separator"] || " • "
    is_fr = french_language?

    if get_bool_setting("show_badges", true) && defined?($Trainer) && $Trainer && $Trainer.respond_to?(:badge_count)
      badges = ($Trainer.badge_count rescue 0).to_i
      parts << "#{badges} #{badges <= 1 ? 'Badge' : 'Badges'}"
    end

    if get_bool_setting("show_pokedex", true)
      caught = current_pokedex_count
      dex_lbl = is_fr ? "Pokédex" : "Dex"
      parts << "#{dex_lbl}: #{caught}" if caught
    end

    if get_bool_setting("show_shinies_count", true)
      shinies = count_caught_shinies
      label = cfg["shiny_label"] || "★ Shinies"
      parts << (label == "★" ? "★ #{shinies}" : "#{label}: #{shinies}")
    end

    if get_bool_setting("show_fusions_count", true)
      fusions = current_fusion_count(cfg)
      label = cfg["fusion_label"] || "Fusions"
      parts << "#{label}: #{fusions}"
    end

    if get_bool_setting("show_challenge_in_state", false)
      ch_tags = current_challenge_tags
      parts << ch_tags.join("/") if ch_tags && !ch_tags.empty?
    end

    if get_bool_setting("show_nuzlocke_tracker", false)
      nz_text = format_nuzlocke_status
      parts << nz_text if nz_text && !nz_text.empty?
    end

    if get_bool_setting("show_level_cap", false)
      cap_text = format_level_cap_status
      parts << cap_text if cap_text && !cap_text.empty?
    end

    if get_bool_setting("show_coop_in_state", false)
      p_summary = format_coop_leader_inline(current_coop_leader_info)
      parts << p_summary if p_summary && !p_summary.empty?
    end

    if get_bool_setting("show_money", false) && defined?($Trainer) && $Trainer && $Trainer.respond_to?(:money)
      parts << format_money($Trainer.money)
    end

    if get_bool_setting("show_party_leader_in_state", false)
      leader_info = current_party_leader_info
      parts << leader_info if leader_info && !leader_info.empty?
    end

    parts.join(sep)
  rescue StandardError
    ""
  end

  KANTO_REDRAWN_ROOT     = "https://raw.githubusercontent.com/Retro-Redrawn/KantoRedrawn/main/img".freeze
  KANTO_REDRAWN_BASE     = "#{KANTO_REDRAWN_ROOT}/kanto/new".freeze
  INTERIOR_REDRAWN_BASE  = "#{KANTO_REDRAWN_ROOT}/interior/new".freeze
  SEVII_REDRAWN_BASE     = "#{KANTO_REDRAWN_ROOT}/sevii/new".freeze
  DEFAULT_FALLBACK_IMAGE = "#{KANTO_REDRAWN_BASE}/pallet_town.png".freeze

  INTERIOR_IMAGE_MAP = [
    ["pewter gym",             "pewter_gym.png"],
    ["cerulean gym",           "cerulean_gym.png"],
    ["vermilion gym",          "vermilion_gym.png"],
    ["celadon gym",            "celadon_gym.png"],
    ["fuchsia gym",            "fuchsia_gym.png"],
    ["saffron gym",            "saffron_gym.png"],
    ["cinnabar gym",           "cinnabar_gym.png"],
    ["viridian gym",           "viridian_gym.png"],
    ["arene d'argenta",        "pewter_gym.png"],
    ["arene de jadielle",      "viridian_gym.png"],
    ["arene d'azuria",         "cerulean_gym.png"],
    ["arene de carmin",        "vermilion_gym.png"],
    ["arene de celadopole",    "celadon_gym.png"],
    ["arene de parmanie",      "fuchsia_gym.png"],
    ["arene de safrania",      "saffron_gym.png"],
    ["arene de cramois",       "cinnabar_gym.png"],
    ["fighting dojo",          "dojo.png"],
    ["dojo de combat",         "dojo.png"],
    ["dojo",                   "dojo.png"],
    ["oak's lab",              "oaks_lab.png"],
    ["oaks lab",               "oaks_lab.png"],
    ["prof. oak",              "oaks_lab.png"],
    ["elm's lab",              "oaks_lab.png"],
    ["labo chen",              "oaks_lab.png"],
    ["laboratoire chen",       "oaks_lab.png"],
    ["prof. chen",             "oaks_lab.png"],
    ["labo orme",              "oaks_lab.png"],
    ["house 2f",               "players_house_2f.png"],
    ["chambre",                "players_house_2f.png"],
    ["'s house",               "players_house_1f.png"],
    ["player's house",         "players_house_1f.png"],
    ["maison",                 "players_house_1f.png"],
    ["pokémon center",         "pokecenter.png"],
    ["pokemon center",         "pokecenter.png"],
    ["centre pokemon",         "pokecenter.png"],
    ["poké center",            "pokecenter.png"],
    ["pokecenter",             "pokecenter.png"],
    ["poké mart",              "pokemart.png"],
    ["pokemart",               "pokemart.png"],
    ["poke mart",              "pokemart.png"],
    ["boutique pokemon",       "pokemart.png"],
    ["trade center",           "trade_center.png"],
    ["centre commercial",      "celadon_dept_1f.png"],
    ["department store",       "celadon_dept_1f.png"],
    ["celadon dept",           "celadon_dept_1f.png"],
    ["goldenrod dept",         "celadon_dept_1f.png"],
    ["celadon mansion",        "celadon_condos_1f.png"],
    ["celadon condos",         "celadon_condos_1f.png"],
    ["game freak",             "celadon_condos_gamefreak.png"],
    ["restaurant",             "celadon_restaurant.png"],
    ["game corner",            "game_corner.png"],
    ["casino",                 "game_corner.png"],
    ["rocket hideout",         "rocket_hideout_b1f.png"],
    ["repaire rocket",         "rocket_hideout_b1f.png"],
    ["silph co",               "silph_lobby.png"],
    ["sylphe sarl",            "silph_lobby.png"],
    ["silph sarl",             "silph_lobby.png"],
    ["radio tower",            "silph_lobby.png"],
    ["tour radio",             "silph_lobby.png"],
    ["s.s. anne",              "ss_anne_deck.png"],
    ["ss anne",                "ss_anne_deck.png"],
    ["s.s. aqua",              "ss_anne_deck.png"],
    ["oceane",                 "ss_anne_deck.png"],
    ["pokémon tower",          "pkmn_tower_1f.png"],
    ["pokemon tower",          "pkmn_tower_1f.png"],
    ["tour pokemon",           "pkmn_tower_1f.png"],
    ["sprout tower",           "pkmn_tower_1f.png"],
    ["tour chetiflor",         "pkmn_tower_1f.png"],
    ["bell tower",             "pkmn_tower_1f.png"],
    ["tin tower",              "pkmn_tower_1f.png"],
    ["tour ferraille",         "pkmn_tower_1f.png"],
    ["burned tower",           "mansion_1f.png"],
    ["tour cendree",           "mansion_1f.png"],
    ["fuji's house",           "fujis_place.png"],
    ["pokémon mansion",        "mansion_1f.png"],
    ["pokemon mansion",        "mansion_1f.png"],
    ["manoir pokemon",         "mansion_1f.png"],
    ["cinnabar mansion",       "mansion_1f.png"],
    ["cinnabar lab",           "cinnabar_lab_1.png"],
    ["pokémon lab",            "cinnabar_lab_1.png"],
    ["laboratoire de cramois", "cinnabar_lab_1.png"],
    ["labo de cramois",        "cinnabar_lab_1.png"],
    ["cerulean cave",          "cerulean_cave_1f.png"],
    ["caverne azuree",         "cerulean_cave_1f.png"],
    ["grotte azuree",          "cerulean_cave_1f.png"],
    ["mt. silver",             "cerulean_cave_1f.png"],
    ["mont argente",           "cerulean_cave_1f.png"],
    ["diglett's cave",         "digletts_cave.png"],
    ["digletts cave",          "digletts_cave.png"],
    ["cave taupiqueur",        "digletts_cave.png"],
    ["rock tunnel",            "rock_tunnel_1f.png"],
    ["grotte sombre",          "rock_tunnel_1f.png"],
    ["dark cave",              "rock_tunnel_1f.png"],
    ["antre noir",             "rock_tunnel_1f.png"],
    ["union cave",             "mt_moon_1f.png"],
    ["caves jumelles",         "mt_moon_1f.png"],
    ["slowpoke well",          "mt_moon_b1f.png"],
    ["puits ramoloss",         "mt_moon_b1f.png"],
    ["seafoam",                "seafoam_1f.png"],
    ["iles ecume",             "seafoam_1f.png"],
    ["whirl islands",          "seafoam_1f.png"],
    ["iles tourbillon",        "seafoam_1f.png"],
    ["ice path",               "seafoam_1f.png"],
    ["route de glace",         "seafoam_1f.png"],
    ["victory road",           "victory_road_1f.png"],
    ["route victoire",         "victory_road_1f.png"],
    ["mt. moon b2f",           "mt_moon_b2f.png"],
    ["mt. moon b1f",           "mt_moon_b1f.png"],
    ["mt. moon 1f",            "mt_moon_1f.png"],
    ["mont selenite",          "mt_moon_1f.png"],
    ["bike shop",              "bike_shop.png"],
    ["magasin de velo",        "bike_shop.png"],
    ["museum",                 "museum_1f.png"],
    ["musee",                  "museum_1f.png"],
    ["fan club",               "pokemon_fanclub.png"],
    ["trainer house",          "trainer_house_1f.png"],
    ["maison des dresseurs",   "trainer_house_1f.png"],
    ["train station",          "train_station.png"],
    ["magnet train",           "train_station.png"],
    ["gare",                   "train_station.png"],
    ["train magnetique",       "train_station.png"],
    ["copycat",                "copycat.png"],
    ["copieuse",               "copycat.png"],
    ["warden",                 "safari_zone_warden.png"],
    ["underground",            "underground_ns.png"],
    ["souterrain",             "underground_ns.png"],
    ["hall of fame",           "hall_of_fame.png"],
    ["salle des celebrites",   "hall_of_fame.png"],
    ["pantheon",               "hall_of_fame.png"],
    ["champion",               "elite_four_champ.png"],
    ["elite four",             "elite_four_1.png"],
    ["conseil des 4",          "elite_four_1.png"],
    ["conseil 4",              "elite_four_1.png"],
    ["ligue pokemon",          "indigo_plateau.png"],
    ["lorelei",                "elite_four_1.png"],
    ["bruno",                  "elite_four_2.png"],
    ["agatha",                 "elite_four_3.png"],
    ["lance",                  "elite_four_4.png"]
  ].freeze

  SEVII_IMAGE_MAP = [
    ["mt. ember",              "One-Island-Mt-Ember.png"],
    ["mt ember",               "One-Island-Mt-Ember.png"],
    ["mont braise",            "One-Island-Mt-Ember.png"],
    ["kindle road",            "One-Island-Kindle-Road.png"],
    ["route tison",            "One-Island-Kindle-Road.png"],
    ["treasure beach",         "One-Island-Treasure-Beach.png"],
    ["plage tresor",           "One-Island-Treasure-Beach.png"],
    ["one island",             "One-Island-Town.png"],
    ["knot island",            "One-Island-Town.png"],
    ["ile 1",                  "One-Island-Town.png"],
    ["cape brink",             "Two-Island-Cape-Brink.png"],
    ["cap falaise",            "Two-Island-Cape-Brink.png"],
    ["two island",             "Two-Island-Town.png"],
    ["boon island",            "Two-Island-Town.png"],
    ["ile 2",                  "Two-Island-Town.png"],
    ["bond bridge",            "Three-Island-Bond-Bridge.png"],
    ["pont du lien",           "Three-Island-Bond-Bridge.png"],
    ["berry forest",           "Three-Island-Bond-Bridge.png"],
    ["bois baies",             "Three-Island-Bond-Bridge.png"],
    ["three island",           "Three-Island-Town.png"],
    ["kin island",             "Three-Island-Town.png"],
    ["ile 3",                  "Three-Island-Town.png"],
    ["four island",            "Four-Island-Town.png"],
    ["ile 4",                  "Four-Island-Town.png"],
    ["icefall cave",           "Four-Island-Town.png"],
    ["grotte cascade",         "Four-Island-Town.png"],
    ["grotte de glace",        "Four-Island-Town.png"],
    ["memorial pillar",        "Five-Island-Memorial-Pillar.png"],
    ["pilier souvenir",        "Five-Island-Memorial-Pillar.png"],
    ["resort gorgeous",        "Five-Island-Resort-Gorgeous.png"],
    ["camp de vacances",       "Five-Island-Resort-Gorgeous.png"],
    ["lost cave",              "Five-Island-Resort-Gorgeous.png"],
    ["grotte perdue",          "Five-Island-Resort-Gorgeous.png"],
    ["water labyrinth",        "Five-Island-Water-Labyrinth.png"],
    ["labyrinthe d'eau",       "Five-Island-Water-Labyrinth.png"],
    ["lake of rage",           "Five-Island-Water-Labyrinth.png"],
    ["lac colere",             "Five-Island-Water-Labyrinth.png"],
    ["five island",            "Five-Island-Town-Meadow.png"],
    ["chron island",           "Five-Island-Town-Meadow.png"],
    ["ile 5",                  "Five-Island-Town-Meadow.png"],
    ["pre ile 5",              "Five-Island-Town-Meadow.png"],
    ["green path",             "Six-Island-Green-Path.png"],
    ["chemin vert",            "Six-Island-Green-Path.png"],
    ["pattern bush",           "Six-Island-Green-Path.png"],
    ["foret romantique",       "Six-Island-Green-Path.png"],
    ["outcast island",         "Six-Island-Outcast-Island.png"],
    ["ile du lointain",        "Six-Island-Outcast-Island.png"],
    ["altering cave",          "Six-Island-Outcast-Island.png"],
    ["ruin valley",            "Six-Island-Ruin-Valley.png"],
    ["vallee ruine",           "Six-Island-Ruin-Valley.png"],
    ["dotted hole",            "Six-Island-Ruin-Valley.png"],
    ["trou perce",             "Six-Island-Ruin-Valley.png"],
    ["ruins of alph",          "Six-Island-Ruin-Valley.png"],
    ["ruines d'alpha",         "Six-Island-Ruin-Valley.png"],
    ["six island",             "Six-Island-Town.png"],
    ["fortune island",         "Six-Island-Town.png"],
    ["ile 6",                  "Six-Island-Town.png"],
    ["seavault canyon",        "Seven-Island-Seavault-Canyon-North.png"],
    ["canyon sevault",         "Seven-Island-Seavault-Canyon-North.png"],
    ["tanoby",                 "Seven-Island-Tanoby-Ruins.png"],
    ["ruines tanoby",          "Seven-Island-Tanoby-Ruins.png"],
    ["trainer tower",          "Seven-Island-Town-Trainer-Tower.png"],
    ["tour dresseurs",         "Seven-Island-Town-Trainer-Tower.png"],
    ["battle tower",           "Seven-Island-Town-Trainer-Tower.png"],
    ["tour de combat",         "Seven-Island-Town-Trainer-Tower.png"],
    ["battle factory",         "Seven-Island-Town-Trainer-Tower.png"],
    ["usine de combat",        "Seven-Island-Town-Trainer-Tower.png"],
    ["seven island",           "Seven-Island-Town-Trainer-Tower.png"],
    ["quest island",           "Seven-Island-Town-Trainer-Tower.png"],
    ["ile 7",                  "Seven-Island-Town-Trainer-Tower.png"],
    ["birth island",           "Sevii-Islands-Birth-Island.png"],
    ["ile aurore",             "Sevii-Islands-Birth-Island.png"],
    ["navel rock",             "Sevii-Islands-Navel-Rock.png"],
    ["roc nombri",             "Sevii-Islands-Navel-Rock.png"],
    ["sevii",                  "One-Island-Town.png"],
    ["iles sevii",             "One-Island-Town.png"]
  ].freeze

  LOCATION_IMAGE_MAP = {
    "pallet town"         => "#{KANTO_REDRAWN_BASE}/pallet_town.png",
    "bourg palette"       => "#{KANTO_REDRAWN_BASE}/pallet_town.png",
    "new bark town"       => "#{KANTO_REDRAWN_BASE}/pallet_town.png",
    "bourg geon"          => "#{KANTO_REDRAWN_BASE}/pallet_town.png",
    "viridian city"       => "#{KANTO_REDRAWN_BASE}/viridian_city.png",
    "jadielle"            => "#{KANTO_REDRAWN_BASE}/viridian_city.png",
    "cherrygrove city"    => "#{KANTO_REDRAWN_BASE}/viridian_city.png",
    "ville griotte"       => "#{KANTO_REDRAWN_BASE}/viridian_city.png",
    "pewter city"         => "#{KANTO_REDRAWN_BASE}/pewter_city.png",
    "argenta"             => "#{KANTO_REDRAWN_BASE}/pewter_city.png",
    "azalea town"         => "#{KANTO_REDRAWN_BASE}/pewter_city.png",
    "ecorcia"             => "#{KANTO_REDRAWN_BASE}/pewter_city.png",
    "cerulean city"       => "#{KANTO_REDRAWN_BASE}/cerulean_city.png",
    "azuria"              => "#{KANTO_REDRAWN_BASE}/cerulean_city.png",
    "blackthorn city"     => "#{KANTO_REDRAWN_BASE}/cerulean_city.png",
    "ebenelle"            => "#{KANTO_REDRAWN_BASE}/cerulean_city.png",
    "vermilion city"      => "#{KANTO_REDRAWN_BASE}/vermilion_city.png",
    "carmin sur mer"      => "#{KANTO_REDRAWN_BASE}/vermilion_city.png",
    "olivine city"        => "#{KANTO_REDRAWN_BASE}/vermilion_city.png",
    "oliville"            => "#{KANTO_REDRAWN_BASE}/vermilion_city.png",
    "cianwood city"       => "#{KANTO_REDRAWN_BASE}/vermilion_city.png",
    "irisia"              => "#{KANTO_REDRAWN_BASE}/vermilion_city.png",
    "lavender town"       => "#{KANTO_REDRAWN_BASE}/lavender_town.png",
    "lavanville"          => "#{KANTO_REDRAWN_BASE}/lavender_town.png",
    "ecruteak city"       => "#{KANTO_REDRAWN_BASE}/lavender_town.png",
    "rosalia"             => "#{KANTO_REDRAWN_BASE}/lavender_town.png",
    "violet city"         => "#{KANTO_REDRAWN_BASE}/lavender_town.png",
    "mauville"            => "#{KANTO_REDRAWN_BASE}/lavender_town.png",
    "celadon city"        => "#{KANTO_REDRAWN_BASE}/celadon_city.png",
    "celadopole"          => "#{KANTO_REDRAWN_BASE}/celadon_city.png",
    "fuchsia city"        => "#{KANTO_REDRAWN_BASE}/fuchsia_city.png",
    "parmanie"            => "#{KANTO_REDRAWN_BASE}/fuchsia_city.png",
    "mahogany town"       => "#{KANTO_REDRAWN_BASE}/fuchsia_city.png",
    "acajou"              => "#{KANTO_REDRAWN_BASE}/fuchsia_city.png",
    "saffron city"        => "#{KANTO_REDRAWN_BASE}/saffron_city.png",
    "safrania"            => "#{KANTO_REDRAWN_BASE}/saffron_city.png",
    "goldenrod city"      => "#{KANTO_REDRAWN_BASE}/saffron_city.png",
    "doublonville"        => "#{KANTO_REDRAWN_BASE}/saffron_city.png",
    "cinnabar island"     => "#{KANTO_REDRAWN_BASE}/cinnabar_island.png",
    "cramois'ile"         => "#{KANTO_REDRAWN_BASE}/cinnabar_island.png",
    "cramoisile"          => "#{KANTO_REDRAWN_BASE}/cinnabar_island.png",
    "indigo plateau"      => "#{KANTO_REDRAWN_BASE}/indigo_plateau.png",
    "plateau indigo"      => "#{KANTO_REDRAWN_BASE}/indigo_plateau.png",
    "pokemon league"      => "#{KANTO_REDRAWN_BASE}/indigo_plateau.png",
    "pokémon league"      => "#{KANTO_REDRAWN_BASE}/indigo_plateau.png",
    "viridian forest"     => "#{KANTO_REDRAWN_BASE}/viridian_forest.png",
    "foret de jade"       => "#{KANTO_REDRAWN_BASE}/viridian_forest.png",
    "ilex forest"         => "#{KANTO_REDRAWN_BASE}/viridian_forest.png",
    "bois aux chenes"     => "#{KANTO_REDRAWN_BASE}/viridian_forest.png",
    "mt. moon"            => "#{KANTO_REDRAWN_BASE}/mt_moon_square.png",
    "mt moon"             => "#{KANTO_REDRAWN_BASE}/mt_moon_square.png",
    "mount moon"          => "#{KANTO_REDRAWN_BASE}/mt_moon_square.png",
    "mont selenite"       => "#{KANTO_REDRAWN_BASE}/mt_moon_square.png",
    "power plant"         => "#{KANTO_REDRAWN_BASE}/power_plant.png",
    "centrale"            => "#{KANTO_REDRAWN_BASE}/power_plant.png",
    "centrale electrique" => "#{KANTO_REDRAWN_BASE}/power_plant.png",
    "safari zone"         => "#{KANTO_REDRAWN_BASE}/safari_zone_central.png",
    "parc safari"         => "#{KANTO_REDRAWN_BASE}/safari_zone_central.png",
    "national park"       => "#{KANTO_REDRAWN_BASE}/safari_zone_central.png",
    "parc naturel"        => "#{KANTO_REDRAWN_BASE}/safari_zone_central.png",
    "bill's lighthouse"   => "#{KANTO_REDRAWN_BASE}/bills_lighthouse.png",
    "bills lighthouse"    => "#{KANTO_REDRAWN_BASE}/bills_lighthouse.png",
    "sea cottage"         => "#{KANTO_REDRAWN_BASE}/bills_lighthouse.png",
    "phare de leo"        => "#{KANTO_REDRAWN_BASE}/bills_lighthouse.png",
    "maison de leo"       => "#{KANTO_REDRAWN_BASE}/bills_lighthouse.png",
    "glitter lighthouse"  => "#{KANTO_REDRAWN_BASE}/bills_lighthouse.png",
    "phare scintillant"   => "#{KANTO_REDRAWN_BASE}/bills_lighthouse.png"
  }.freeze

  ROUTE_IMAGE_MAP = {
    1  => "route_1.png",
    2  => "route_2_north.png",
    3  => "route_3_east.png",
    4  => "route_4.png",
    5  => "route_5.png",
    6  => "route_6.png",
    7  => "route_7.png",
    8  => "route_8.png",
    9  => "route_9.png",
    10 => "route_10_north.png",
    11 => "route_11.png",
    12 => "route_12_north.png",
    13 => "route_13.png",
    14 => "route_14.png",
    15 => "route_15.png",
    16 => "route_16.png",
    17 => "route_17.png",
    18 => "route_18.png",
    19 => "route_19.png",
    20 => "route_20.png",
    21 => "route_21.png",
    22 => "route_22.png",
    23 => "route_23_1.png",
    24 => "route_24.png",
    25 => "route_25.png"
  }.freeze

  def self.build_assets(cfg)
    assets = {}

    primary = get_setting("primary_image", "leader").to_s.downcase
    style = get_setting("leader_sprite_style", "showdown").to_s

    sprite_url = nil
    if get_bool_setting("show_leader_sprite", true) && defined?($Trainer) && $Trainer
      sprite_url = current_leader_sprite_url(style)
    end

    location_url = nil
    if get_bool_setting("show_location_art", true) && defined?($Trainer) && $Trainer
      location_url = current_location_image_url(cfg)
    end
    location_url ||= DEFAULT_FALLBACK_IMAGE

    leader_tooltip = current_party_leader_tooltip
    location_tooltip = build_location_tooltip(cfg)

    case primary
    when "location"
      assets["large_image"] = location_url
      assets["large_text"] = location_tooltip[0, 128] if location_tooltip && !location_tooltip.empty?

      if sprite_url && !sprite_url.empty?
        assets["small_image"] = sprite_url
        assets["small_text"] = leader_tooltip[0, 128] if leader_tooltip && !leader_tooltip.empty?
      end

    else
      pinfo = current_coop_leader_info(style)
      show_partner_orb = get_bool_setting("show_coop_partner_orb", true)

      orb_url = nil
      orb_text = nil

      if pinfo && pinfo[:sprite_url] && show_partner_orb
        orb_url = pinfo[:sprite_url]
        orb_text = build_coop_partner_tooltip(pinfo)
      elsif location_url && !location_url.empty? && get_bool_setting("show_location_art", true)
        orb_url = location_url
        p_summary = format_coop_leader_inline(pinfo)
        orb_text = (p_summary && !p_summary.empty?) ? "#{p_summary} • #{location_tooltip}" : location_tooltip
      end

      if sprite_url && !sprite_url.empty?
        assets["large_image"] = sprite_url
        assets["large_text"] = leader_tooltip[0, 128] if leader_tooltip && !leader_tooltip.empty?
      else
        fallback_key = (cfg["large_image_key"] && !cfg["large_image_key"].to_s.empty?) ? cfg["large_image_key"].to_s : "icon"
        assets["large_image"] = fallback_key
        assets["large_text"] = (leader_tooltip && !leader_tooltip.empty?) ? leader_tooltip[0, 128] : "Kuray's Infinite Fusion"
      end

      if orb_url && !orb_url.empty?
        assets["small_image"] = orb_url
        assets["small_text"] = orb_text[0, 128] if orb_text && !orb_text.empty?
      end
    end

    assets
  rescue StandardError
    {}
  end

  def self.build_location_tooltip(cfg)
    tooltip_parts = []
    if get_bool_setting("show_game_mode", true) && defined?($Trainer) && $Trainer
      mode_line = current_mode_difficulty_and_challenges
      tooltip_parts << mode_line unless mode_line.empty?
    end
    if get_bool_setting("show_nuzlocke_tracker", false)
      nz_text = format_nuzlocke_status
      tooltip_parts << nz_text if nz_text && !nz_text.empty?
    end
    if get_bool_setting("show_level_cap", false)
      cap_text = format_level_cap_status
      tooltip_parts << cap_text if cap_text && !cap_text.empty?
    end
    if get_bool_setting("show_session_info", true) && defined?($Trainer) && $Trainer
      session_info = current_session_info
      tooltip_parts << session_info if session_info && !session_info.empty?
    end
    tooltip_parts.empty? ? (cfg["large_image_text"] || "Kuray's Infinite Fusion") : tooltip_parts.join(" • ")
  rescue StandardError
    "Kuray's Infinite Fusion"
  end

  def self.single_species_name
    if defined?(SingleSpeciesPlus) && SingleSpeciesPlus.respond_to?(:active?) && SingleSpeciesPlus.active?
      sp = (SingleSpeciesPlus.get_species_name rescue nil)
      return sp.to_s if sp && !sp.to_s.empty?
    end

    sw_single = defined?(SWITCH_SINGLE_POKEMON_MODE) ? SWITCH_SINGLE_POKEMON_MODE : 790
    var_single = defined?(VAR_SINGLE_POKEMON_MODE) ? VAR_SINGLE_POKEMON_MODE : (defined?(SINGLE_POKEMON_MODE_VAR) ? SINGLE_POKEMON_MODE_VAR : 251)

    if defined?($game_switches) && $game_switches && $game_switches[sw_single]
      if defined?($game_variables) && $game_variables
        sp_id = ($game_variables[var_single] rescue 0).to_i
        if sp_id > 0
          sp_name = localized_species_name(sp_id)
          return sp_name.to_s if sp_name && !sp_name.to_s.empty?
        end
      end
    end
    nil
  rescue StandardError
    nil
  end

  def self.current_challenge_tags
    tags = []
    is_fr = french_language?

    if defined?(KIF::SoulLink) && KIF::SoulLink.respond_to?(:on?) && (KIF::SoulLink.on? rescue false)
      tags << "Soul Link"
    elsif defined?(KIF::Nuzlocke) && KIF::Nuzlocke.respond_to?(:on?) && (KIF::Nuzlocke.on? rescue false)
      tags << "Nuzlocke"
    end

    if defined?($PokemonSystem) && $PokemonSystem
      metro = ($PokemonSystem.ch_metronome rescue 0).to_i
      if metro > 0
        tags << (metro == 2 ? (is_fr ? "Métronome (Difficile)" : "Metronome (Hard)") : (is_fr ? "Métronome" : "Metronome"))
      end

      letdown = ($PokemonSystem.ch_letdown rescue 0).to_i
      tags << (is_fr ? "Déception" : "Letdown") if letdown > 0

      berserk = ($PokemonSystem.ch_berserker rescue 0).to_i
      if berserk > 0
        case berserk
        when 1 then tags << (is_fr ? "Berserker (Facile)" : "Berserker (Easy)")
        when 2 then tags << "Berserker"
        when 3 then tags << (is_fr ? "Berserker (Difficile)" : "Berserker (Hard)")
        when 4 then tags << "Berserker (Chaos)"
        end
      end
    end

    tags
  rescue StandardError
    []
  end

  def self.current_mode_difficulty_and_challenges
    mode = current_game_mode
    diff = current_difficulty
    challenges = current_challenge_tags

    mode_str = (mode && diff) ? "#{mode} (#{diff})" : (mode || diff || "")
    parts = []
    parts << mode_str unless mode_str.empty?
    parts.concat(challenges) if challenges && !challenges.empty?
    parts.join(" • ")
  rescue StandardError
    ""
  end

  def self.nuzlocke_active?
    return true if defined?(KIF::Nuzlocke) && (KIF::Nuzlocke.on? rescue false)
    if defined?($PokemonSystem)
      return true if ($PokemonSystem.ch_nuzlocke.to_i > 0 rescue false)
    end
    if defined?(SWITCH_NUZLOCKE_MODE) && defined?($game_switches)
      return true if ($game_switches[SWITCH_NUZLOCKE_MODE] rescue false)
    end
    false
  rescue StandardError
    false
  end

  def self.nuzlocke_stats
    state = nil
    if defined?(KIF::Nuzlocke) && KIF::Nuzlocke.respond_to?(:state)
      state = (KIF::Nuzlocke.state rescue nil)
    end
    state ||= ($PokemonGlobal.kif_nuzlocke rescue nil) if defined?($PokemonGlobal) && $PokemonGlobal

    deaths = 0
    graveyard = 0
    failed = false

    if state.is_a?(Hash)
      deaths = (state[:deaths] || []).size rescue 0
      graveyard = (state[:graveyard] || []).size rescue 0
      failed = !!state[:failed]
    end

    { deaths: [deaths, graveyard].max, failed: failed }
  rescue StandardError
    { deaths: 0, failed: false }
  end

  def self.format_nuzlocke_status
    return nil unless nuzlocke_active?
    stats = nuzlocke_stats
    is_fr = french_language?

    if stats[:failed]
      return is_fr ? "💀 Échec" : "💀 Failed"
    end

    deaths = stats[:deaths]
    is_fr ? "💀 Morts : #{deaths}" : "💀 Deaths: #{deaths}"
  rescue StandardError
    nil
  end

  def self.current_level_cap
    if defined?(KIF::LevelCap) && KIF::LevelCap.respond_to?(:cap)
      cap = (KIF::LevelCap.cap rescue nil)
      return cap.to_i if cap && cap.to_i > 0
    end
    if defined?(getCurrentLevelCap)
      is_cap_on = false
      if defined?($PokemonSystem) && $PokemonSystem
        is_cap_on = true if ($PokemonSystem.kuraylevelcap.to_i > 0 rescue false)
        is_cap_on = true if ($PokemonSystem.respond_to?(:level_caps) && $PokemonSystem.level_caps.to_i > 0 rescue false)
      end
      if is_cap_on
        cap = (getCurrentLevelCap rescue nil)
        return cap.to_i if cap && cap.to_i > 0
      end
    end
    nil
  rescue StandardError
    nil
  end

  def self.format_level_cap_status
    cap = current_level_cap
    return nil unless cap && cap > 0
    is_fr = french_language?
    is_fr ? "Cap : Niv. #{cap}" : "Cap: Lv. #{cap}"
  rescue StandardError
    nil
  end

  def self.build_coop_partner_tooltip(pinfo)
    return nil unless pinfo && pinfo[:species_name]
    is_fr = french_language?
    coop_lbl = is_fr ? "Co-op : " : "Co-op: "
    shiny_star = pinfo[:is_shiny] ? "★ " : ""
    lvl_prefix = is_fr ? "Niv. " : "Lv. "

    str = +"#{coop_lbl}#{shiny_star}#{pinfo[:species_name]}"
    str << " (#{lvl_prefix}#{pinfo[:level]})" if pinfo[:level] && pinfo[:level].to_i > 0
    str << " • #{pinfo[:fusion_text]}" if pinfo[:fusion_text] && !pinfo[:fusion_text].empty?
    str
  rescue StandardError
    nil
  end

  def self.format_coop_leader_inline(pinfo)
    return nil unless pinfo && pinfo[:species_name]
    is_fr = french_language?
    coop_lbl = is_fr ? "Co-op : " : "Co-op: "
    shiny_star = pinfo[:is_shiny] ? "★ " : ""

    if pinfo[:fusion_text] && !pinfo[:fusion_text].empty?
      "#{coop_lbl}#{shiny_star}#{pinfo[:species_name]} (#{pinfo[:fusion_text]})"
    elsif pinfo[:level] && pinfo[:level].to_i > 0
      lvl_prefix = is_fr ? "Niv. " : "Lv. "
      "#{coop_lbl}#{shiny_star}#{pinfo[:species_name]} (#{lvl_prefix}#{pinfo[:level]})"
    else
      "#{coop_lbl}#{shiny_star}#{pinfo[:species_name]}"
    end
  rescue StandardError
    nil
  end

  def self.current_coop_leader_info(style = "showdown")
    session = nil
    if defined?(KIF::Net) && KIF::Net.respond_to?(:session)
      s = KIF::Net.session
      session = s if s && s.respond_to?(:connected?) && s.connected?
    end

    coop_on = defined?(KIF::Coop) && KIF::Coop.respond_to?(:on?) && (KIF::Coop.on? rescue false)
    sl_on = defined?(KIF::SoulLink) && KIF::SoulLink.respond_to?(:connected?) && (KIF::SoulLink.connected? rescue false)
    has_partner_trainer = defined?($PokemonGlobal) && $PokemonGlobal && $PokemonGlobal.respond_to?(:partner) && $PokemonGlobal.partner

    unless session || coop_on || sl_on || has_partner_trainer
      @last_known_partner_data = nil
      return nil
    end

    pkmn = nil
    if has_partner_trainer && $PokemonGlobal.partner.is_a?(Array) && $PokemonGlobal.partner[3].is_a?(Array)
      pkmn = $PokemonGlobal.partner[3].find { |p| p && (!p.respond_to?(:egg?) || !p.egg?) }
    end

    if pkmn.nil? && defined?(KIF::Coop)
      h = (KIF::Coop.instance_variable_get(:@battle_host) rescue nil)
      if h && h.respond_to?(:guest_party)
        gp = (h.guest_party rescue nil)
        pkmn = gp.find { |p| p && (!p.respond_to?(:egg?) || !p.egg?) } if gp && gp.is_a?(Array)
      end
      if pkmn.nil?
        g = (KIF::Coop.instance_variable_get(:@guest) rescue nil)
        if g && g.respond_to?(:instance_variable_get)
          b = (g.instance_variable_get(:@battle) rescue nil)
          if b && b.respond_to?(:pbParty)
            hp = (b.pbParty(0) rescue nil)
            pkmn = hp.find { |p| p && (!p.respond_to?(:egg?) || !p.egg?) } if hp && hp.is_a?(Array)
          end
        end
      end
    end

    if pkmn
      is_shiny = pokemon_shiny?(pkmn)
      is_fus = pokemon_fusion?(pkmn)
      head_id = (pkmn.head_id rescue nil)
      body_id = (pkmn.body_id rescue nil)
      level = (pkmn.level rescue nil)
      pk_name = localized_species_name(pkmn, true) || (pkmn.name rescue "Pokémon")
      fusion_text = nil
      sprite_url = nil

      if is_fus && head_id && body_id && head_id > 0 && body_id > 0
        fusion_text = fusion_breakdown_text(head_id, body_id)
        sprite_url = "https://bitbucket.org/infinitefusionsprites/customsprites/raw/main/CustomBattlers/#{head_id}.#{body_id}.png"
      else
        dex_num = pokemon_dex_number(pkmn)
        sprite_url = get_pokemon_sprite_url(dex_num, is_shiny, style) if dex_num
      end

      data = {
        species_name: pk_name,
        level: level,
        is_fusion: is_fus,
        fusion_text: fusion_text,
        sprite_url: sprite_url,
        is_shiny: is_shiny
      }
      @last_known_partner_data = data
      return data
    end

    if sl_on && defined?(KIF::SoulLink)
      st = (KIF::SoulLink.state rescue {}) || {}
      snap = st[:partner_party]
      if snap && snap.is_a?(Hash) && !snap.empty?
        entry = snap.values.first
        if entry && entry.is_a?(Array)
          spec = entry[0]
          level = entry[1]
          pk_name = spec.to_s
          fusion_text = nil
          sprite_url = nil
          is_fus = false
          if spec.to_s =~ /\AB(\d+)H(\d+)\z/i
            body_id = $1.to_i
            head_id = $2.to_i
            is_fus = true
            head_name = localized_species_name(head_id)
            body_name = localized_species_name(body_id)
            fusion_text = fusion_breakdown_text(head_id, body_id)
            sprite_url = "https://bitbucket.org/infinitefusionsprites/customsprites/raw/main/CustomBattlers/#{head_id}.#{body_id}.png"
            pk_name = localized_fusion_name(head_id, body_id) || (head_name && body_name ? "#{head_name}/#{body_name}" : spec.to_s)
          elsif defined?(GameData::Species)
            d = (GameData::Species.try_get(spec.to_s.to_sym) rescue nil)
            if d
              dex_num = d.id_number
              pk_name = localized_species_name(d)
              sprite_url = get_pokemon_sprite_url(dex_num, false, style) if dex_num && dex_num > 0
            end
          end

          data = {
            species_name: pk_name,
            level: level,
            is_fusion: is_fus,
            fusion_text: fusion_text,
            sprite_url: sprite_url,
            is_shiny: false
          }
          @last_known_partner_data = data
          return data
        end
      end
    end

    @last_known_partner_data
  rescue StandardError
    nil
  end

  def self.current_session_info
    is_fr = french_language?
    if defined?(KIF::Net) && KIF::Net.respond_to?(:session)
      s = KIF::Net.session
      if s
        if s.respond_to?(:connected?) && s.connected?
          peers = (s.peers rescue []) || []
          player_count = 1 + peers.length
          p_lbl = is_fr ? (player_count <= 1 ? "Joueur" : "Joueurs") : (player_count == 1 ? "Player" : "Players")
          return "Co-op (#{player_count} #{p_lbl})"
        elsif s.respond_to?(:hosting?) && s.hosting?
          return is_fr ? "Co-op (Hôte)" : "Co-op (Hosting)"
        end
      end
    end
    if current_coop_leader_info
      return "Co-op"
    end
    "Solo"
  rescue StandardError
    "Solo"
  end

  def self.format_money(amount)
    amt = amount.to_i
    if amt >= 1_000_000
      sprintf("$%.1fM", amt / 1_000_000.0).sub(".0M", "M")
    elsif amt >= 10_000
      sprintf("$%.1fK", amt / 1_000.0).sub(".0K", "K")
    else
      "$#{amt}"
    end
  rescue StandardError
    "$0"
  end

  def self.current_location_image_url(cfg = nil)
    loc_name = current_map_name
    eng_name = current_english_map_name

    candidates = []
    candidates << normalize_text(eng_name) if eng_name && !eng_name.empty?
    candidates << normalize_text(loc_name) if loc_name && !loc_name.empty?
    candidates.uniq!

    return nil if candidates.empty?

    custom_map = cfg && cfg["location_images"]
    if custom_map && custom_map.is_a?(Hash)
      candidates.each do |c|
        custom_map.each do |k, v|
          return v.to_s if c.include?(normalize_text(k))
        end
      end
    end

    candidates.each do |c|
      INTERIOR_IMAGE_MAP.each do |kw, file_name|
        return "#{INTERIOR_REDRAWN_BASE}/#{file_name}" if c.include?(kw)
      end
    end

    candidates.each do |c|
      SEVII_IMAGE_MAP.each do |kw, file_name|
        return "#{SEVII_REDRAWN_BASE}/#{file_name}" if c.include?(kw)
      end
    end

    candidates.each do |c|
      LOCATION_IMAGE_MAP.each do |k, url|
        return url if c.include?(k)
      end
    end

    candidates.each do |c|
      if c =~ /route\s*(\d+)/
        num = $1.to_i
        file_num = ((num - 1) % 25) + 1
        file_name = ROUTE_IMAGE_MAP[num] || ROUTE_IMAGE_MAP[file_num]
        return "#{KANTO_REDRAWN_BASE}/#{file_name}" if file_name
      end
    end

    town_keywords = [
      ["pallet",     "pallet_town.png"],
      ["viridian",   "viridian_city.png"],
      ["pewter",     "pewter_city.png"],
      ["cerulean",   "cerulean_city.png"],
      ["vermilion",  "vermilion_city.png"],
      ["lavender",   "lavender_town.png"],
      ["celadon",    "celadon_city.png"],
      ["fuchsia",    "fuchsia_city.png"],
      ["saffron",    "saffron_city.png"],
      ["cinnabar",   "cinnabar_island.png"],
      ["indigo",     "indigo_plateau.png"],
      ["safari",     "safari_zone_central.png"],
      ["moon",       "mt_moon_square.png"],
      ["palette",    "pallet_town.png"],
      ["jadielle",   "viridian_city.png"],
      ["argenta",    "pewter_city.png"],
      ["azuria",     "cerulean_city.png"],
      ["carmin",     "vermilion_city.png"],
      ["lavanville", "lavender_town.png"],
      ["celadopole", "celadon_city.png"],
      ["parmanie",   "fuchsia_city.png"],
      ["safrania",   "saffron_city.png"],
      ["cramois",    "cinnabar_island.png"],
      ["selenite",   "mt_moon_square.png"],
      ["goldenrod",  "saffron_city.png"],
      ["doublon",    "saffron_city.png"],
      ["ecruteak",   "lavender_town.png"],
      ["rosalia",    "lavender_town.png"],
      ["olivine",    "vermilion_city.png"],
      ["oliville",   "vermilion_city.png"],
      ["blackthorn", "cerulean_city.png"],
      ["ebenelle",   "cerulean_city.png"]
    ]
    candidates.each do |c|
      town_keywords.each do |kw, file_name|
        return "#{KANTO_REDRAWN_BASE}/#{file_name}" if c.include?(kw)
      end
    end

    DEFAULT_FALLBACK_IMAGE
  rescue StandardError
    DEFAULT_FALLBACK_IMAGE
  end

  def self.lead_party_pokemon
    return nil unless defined?($Trainer) && $Trainer
    party = ($Trainer.party rescue nil)
    return nil unless party && party.is_a?(Array)
    party.find { |p| p && (!p.respond_to?(:egg?) || !p.egg?) }
  rescue StandardError
    nil
  end

  def self.pokemon_dex_number(pkmn)
    return nil unless pkmn
    dex_num = (pkmn.head_id rescue nil)
    if (!dex_num || dex_num <= 0) && pkmn.respond_to?(:species_data) && pkmn.species_data.respond_to?(:id_number)
      dex_num = pkmn.species_data.id_number
    elsif (!dex_num || dex_num <= 0) && pkmn.respond_to?(:species) && defined?(GameData::Species)
      dex_num = (GameData::Species.get(pkmn.species).id_number rescue nil)
    end
    (dex_num && dex_num > 0) ? dex_num : nil
  rescue StandardError
    nil
  end

  def self.get_pokemon_sprite_url(dex_num, is_shiny = false, style = "showdown")
    return nil unless dex_num && dex_num > 0
    case (style || "showdown").to_s.downcase
    when "pixel"
      is_shiny ? "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/shiny/#{dex_num}.png" : "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/#{dex_num}.png"
    when "artwork"
      is_shiny ? "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/other/official-artwork/shiny/#{dex_num}.png" : "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/other/official-artwork/#{dex_num}.png"
    else
      is_shiny ? "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/other/showdown/shiny/#{dex_num}.gif" : "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/other/showdown/#{dex_num}.gif"
    end
  rescue StandardError
    nil
  end

  def self.current_leader_sprite_url(style = "showdown")
    leader = lead_party_pokemon
    return nil unless leader

    head_id = (leader.head_id rescue nil)
    body_id = (leader.body_id rescue nil)
    if pokemon_fusion?(leader) && head_id && body_id && head_id > 0 && body_id > 0
      return "https://bitbucket.org/infinitefusionsprites/customsprites/raw/main/CustomBattlers/#{head_id}.#{body_id}.png"
    end

    dex_num = pokemon_dex_number(leader)
    get_pokemon_sprite_url(dex_num, pokemon_shiny?(leader), style)
  rescue StandardError
    nil
  end

  def self.current_map_name
    return nil unless defined?($game_map) && $game_map
    name = $game_map.name if $game_map.respond_to?(:name)
    if (name.nil? || name.empty?) && $game_map.respond_to?(:map_id) && defined?(pbGetMapNameFromId)
      name = (pbGetMapNameFromId($game_map.map_id) rescue nil)
    end
    if name && !name.empty?
      player_name = (defined?($Trainer) && $Trainer && $Trainer.respond_to?(:name)) ? $Trainer.name.to_s : "Player"
      name = name.to_s.gsub(/\\PN/, player_name)
    else
      name = "Unknown Area"
    end
    name
  rescue StandardError
    nil
  end

  def self.normalize_text(str)
    return "" unless str
    str.to_s.downcase.strip
      .gsub(/[éèêë]/, "e")
      .gsub(/[àâä]/, "a")
      .gsub(/[îï]/, "i")
      .gsub(/[ôö]/, "o")
      .gsub(/[ùûü]/, "u")
      .gsub(/ç/, "c")
  rescue StandardError
    str.to_s.downcase.strip
  end

  def self.current_english_map_name
    return nil unless defined?($game_map) && $game_map
    map_id = ($game_map.map_id rescue nil)
    return nil unless map_id && map_id > 0

    eng_name = nil
    if defined?(MessageTypes) && MessageTypes.respond_to?(:getOriginal)
      type = defined?(MessageTypes::MapNames) ? MessageTypes::MapNames : 21
      eng_name = (MessageTypes.getOriginal(type, map_id) rescue nil)
    end

    if (eng_name.nil? || eng_name.empty?) && defined?(pbLoadRxData)
      map_infos = (defined?($KIF_MAP_INFOS) ? $KIF_MAP_INFOS : nil)
      unless map_infos
        map_infos = (pbLoadRxData("Data/MapInfos.rxdata") rescue nil)
        $KIF_MAP_INFOS = map_infos if map_infos
      end
      if map_infos && map_infos[map_id] && map_infos[map_id].respond_to?(:name)
        eng_name = (map_infos[map_id].name rescue nil)
      end
    end

    if eng_name && !eng_name.empty?
      player_name = (defined?($Trainer) && $Trainer && $Trainer.respond_to?(:name)) ? $Trainer.name.to_s : "Player"
      eng_name = eng_name.to_s.gsub(/\\PN/, player_name)
    end
    eng_name
  rescue StandardError
    nil
  end

  def self.current_pokedex_count
    return nil unless defined?($Trainer) && $Trainer
    return nil if $Trainer.respond_to?(:has_pokedex) && !$Trainer.has_pokedex

    if $Trainer.respond_to?(:pokedex) && $Trainer.pokedex.respond_to?(:owned_count)
      return $Trainer.pokedex.owned_count rescue nil
    elsif $Trainer.respond_to?(:pokedexOwned)
      return $Trainer.pokedexOwned rescue nil
    end
    nil
  rescue StandardError
    nil
  end

  def self.pokemon_shiny?(pkmn)
    return false unless pkmn
    return false if pkmn.respond_to?(:egg?) && pkmn.egg?
    return true if pkmn.respond_to?(:shiny?) && pkmn.shiny?
    return true if pkmn.respond_to?(:headShiny?) && pkmn.headShiny?
    return true if pkmn.respond_to?(:bodyShiny?) && pkmn.bodyShiny?
    return true if pkmn.respond_to?(:head_shiny) && pkmn.head_shiny
    return true if pkmn.respond_to?(:body_shiny) && pkmn.body_shiny
    return true if pkmn.respond_to?(:natural_shiny) && pkmn.natural_shiny
    return true if pkmn.respond_to?(:radar_shiny) && pkmn.radar_shiny
    false
  rescue StandardError
    false
  end

  def self.pokemon_fusion?(pkmn)
    return false unless pkmn
    return false if pkmn.respond_to?(:egg?) && pkmn.egg?
    return true if (pkmn.respond_to?(:isFusion?) && pkmn.isFusion?) || (pkmn.respond_to?(:isTripleFusion?) && pkmn.isTripleFusion?)
    head = (pkmn.head_id rescue nil)
    body = (pkmn.body_id rescue nil)
    return true if head && body && head > 0 && body > 0 && head != body
    if pkmn.respond_to?(:species_data) && pkmn.species_data.respond_to?(:id_number)
      id_num = pkmn.species_data.id_number
      return true if id_num && id_num > (defined?(Settings::NB_POKEMON) ? Settings::NB_POKEMON : 420)
    end
    false
  rescue StandardError
    false
  end

  def self.each_owned_pokemon
    return unless defined?($Trainer) && $Trainer
    if $Trainer.party.is_a?(Array)
      $Trainer.party.each { |p| yield p if p }
    end
    if defined?($PokemonStorage) && $PokemonStorage && $PokemonStorage.respond_to?(:boxes) && $PokemonStorage.boxes
      $PokemonStorage.boxes.each do |box|
        next unless box
        if box.respond_to?(:pokemon) && box.pokemon.is_a?(Array)
          box.pokemon.each { |p| yield p if p }
        elsif box.respond_to?(:length)
          (0...box.length).each do |i|
            p = (box[i] rescue nil)
            yield p if p
          end
        end
      end
    end
  end

  def self.count_caught_shinies
    now = Time.now.to_i
    return @cached_shiny_count if @cached_shiny_time && (now - @cached_shiny_time < 5)

    count = 0
    each_owned_pokemon { |p| count += 1 if pokemon_shiny?(p) }
    @cached_shiny_count = count
    @cached_shiny_time = now
    count
  rescue StandardError
    0
  end

  def self.current_fusion_count(cfg = nil)
    now = Time.now.to_i
    return @cached_fusion_count if @cached_fusion_time && (now - @cached_fusion_time < 5)

    source = (cfg && cfg["fusion_count_source"]) ? cfg["fusion_count_source"].to_s.downcase : "auto"
    dex_count = count_dex_fusions
    living_count = count_living_fusions
    stat_count = count_fusion_stats

    count = case source
    when "pokedex", "dex"
      dex_count || living_count || stat_count
    when "living", "boxes"
      living_count
    when "stats", "splicer"
      stat_count
    else
      [dex_count.to_i, living_count.to_i, stat_count.to_i].max
    end

    @cached_fusion_count = count
    @cached_fusion_time = now
    count
  rescue StandardError
    0
  end

  def self.count_dex_fusions
    return nil unless defined?($Trainer) && $Trainer && $Trainer.respond_to?(:pokedex) && $Trainer.pokedex
    dex = $Trainer.pokedex
    fused_list = (dex.instance_variable_get(:@owned_fusion) rescue nil)
    triples = (dex.instance_variable_get(:@owned_triple) rescue nil)
    count = 0
    if fused_list.is_a?(Array)
      fused_list.each do |sub|
        next unless sub.is_a?(Array)
        sub.each { |owned| count += 1 if owned }
      end
    end
    count += triples.size if triples.respond_to?(:size)
    count
  rescue StandardError
    nil
  end

  def self.count_living_fusions
    count = 0
    each_owned_pokemon { |p| count += 1 if pokemon_fusion?(p) }
    count
  rescue StandardError
    0
  end

  def self.count_fusion_stats
    return ($game_variables[126] rescue 0).to_i if defined?($game_variables) && $game_variables
    0
  rescue StandardError
    0
  end

  def self.current_party_leader_tooltip
    leader = lead_party_pokemon
    return nil unless leader

    species = localized_species_name(leader) || (leader.name rescue "Pokémon")
    str = +""
    str << "★ " if pokemon_shiny?(leader)
    str << species.to_s
    lvl_prefix = french_language? ? "Niv. " : "Lv. "
    str << " (#{lvl_prefix}#{leader.level})" if leader.respond_to?(:level) && leader.level

    if get_bool_setting("show_leader_details", true)
      extra = leader_extra_details(leader)
      str << " • #{extra}" if extra && !extra.empty?
    end

    str
  rescue StandardError
    nil
  end

  def self.leader_extra_details(leader)
    if pokemon_fusion?(leader)
      head_id = (leader.head_id rescue nil)
      body_id = (leader.body_id rescue nil)
      if head_id && body_id && head_id > 0 && body_id > 0
        breakdown = fusion_breakdown_text(head_id, body_id)
        return breakdown if breakdown && !breakdown.empty?
      end
      return "Triple Fusion" if (leader.respond_to?(:isTripleFusion?) && leader.isTripleFusion? rescue false)
    else
      type_str = nil
      if defined?(GameData::Type)
        t1 = (leader.type1 rescue nil)
        t2 = (leader.type2 rescue nil)
        if t1
          t1_obj = (GameData::Type.get(t1) rescue nil)
          t1_name = t1_obj ? (t1_obj.name rescue t1_obj.real_name) : t1.to_s.capitalize
          if t2 && t2 != t1
            t2_obj = (GameData::Type.get(t2) rescue nil)
            t2_name = t2_obj ? (t2_obj.name rescue t2_obj.real_name) : t2.to_s.capitalize
            type_str = "#{t1_name}/#{t2_name}"
          else
            type_str = t1_name.to_s
          end
        end
      end
      if leader.respond_to?(:nicknamed?) && leader.nicknamed?
        base_sp = localized_species_name(leader, true)
        if base_sp && !base_sp.empty?
          return type_str ? "#{base_sp} (#{type_str})" : base_sp
        end
      end
      return type_str
    end
    nil
  rescue StandardError
    nil
  end

  def self.current_party_leader_info
    leader = lead_party_pokemon
    return nil unless leader

    species = localized_species_name(leader) || (leader.name rescue "Pokémon")
    str = +""
    str << "★ " if pokemon_shiny?(leader)
    str << species.to_s
    lvl_prefix = french_language? ? "Niv. " : "Lv. "
    str << " (#{lvl_prefix}#{leader.level})" if leader.respond_to?(:level) && leader.level
    str
  rescue StandardError
    nil
  end

  def self.current_game_mode
    is_fr = french_language?
    sym = nil
    if defined?(getCurrentGameModeSymbol)
      sym = (getCurrentGameModeSymbol() rescue nil)
    elsif defined?($Trainer) && $Trainer && $Trainer.respond_to?(:game_mode)
      case $Trainer.game_mode
      when 0 then sym = :CLASSIC
      when 1 then sym = :RANDOMIZED
      when 2 then sym = :REMIX
      when 3 then sym = :EXPERT
      when 4 then sym = :SINGLE_SPECIES
      end
    end

    sw_single = defined?(SWITCH_SINGLE_POKEMON_MODE) ? SWITCH_SINGLE_POKEMON_MODE : 790
    sym = :SINGLE_SPECIES if defined?($game_switches) && $game_switches && $game_switches[sw_single]

    case sym
    when :SINGLE_SPECIES
      sp = single_species_name
      (sp && !sp.empty?) ? (is_fr ? "Espèce unique : #{sp}" : "Single Species: #{sp}") : (is_fr ? "Espèce unique" : "Single Species")
    when :CLASSIC then is_fr ? "Classique" : "Classic"
    when :REMIX then "Remix"
    when :EXPERT then "Expert"
    when :RANDOMIZED then is_fr ? "Aléatoire" : "Random"
    when :LEGENDARY then is_fr ? "Légendaire" : "Legendary"
    else
      is_fr ? "Classique" : "Classic"
    end
  rescue StandardError
    french_language? ? "Classique" : "Classic"
  end

  def self.current_difficulty
    is_fr = french_language?
    if defined?($Trainer) && $Trainer && $Trainer.respond_to?(:selected_difficulty) && $Trainer.selected_difficulty
      case $Trainer.selected_difficulty
      when 0 then is_fr ? "Facile" : "Easy"
      when 1 then "Normal"
      when 2 then is_fr ? "Difficile" : "Hard"
      end
    elsif defined?($game_switches) && $game_switches
      if defined?(SWITCH_GAME_DIFFICULTY_HARD) && $game_switches[SWITCH_GAME_DIFFICULTY_HARD]
        is_fr ? "Difficile" : "Hard"
      elsif defined?(SWITCH_GAME_DIFFICULTY_EASY) && $game_switches[SWITCH_GAME_DIFFICULTY_EASY]
        is_fr ? "Facile" : "Easy"
      else
        "Normal"
      end
    end
  rescue StandardError
    nil
  end
end

begin
  DiscordRichPresence.start
rescue StandardError
  nil
end
