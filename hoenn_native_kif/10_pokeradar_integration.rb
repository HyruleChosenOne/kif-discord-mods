# Bag Poké Radar bridge: turn the game's existing shaking-grass selections into stationary Hoenn overworld Pokémon
module HoennNativeKIFRadar
  @map_identity = nil
  @session = nil
  @patches = nil
  @events = []
  @cleared_session = false
  @post_battle_frames = 0
  @pending_patches = nil

  def self.active?
    !!(defined?($PokemonTemp) && $PokemonTemp && $PokemonTemp.pokeradar)
  end

  def self.clear_non_shiny
    return unless $game_map && $game_map.events
    $game_map.events.values.dup.each do |event|
      next unless defined?(HoennNativeKIFSocial) && HoennNativeKIFSocial.event_ours?(event)
      next if event.instance_variable_get(:@hno_radar_stationary)
      next unless event.respond_to?(:pokemon) && event.pokemon
      next if event.pokemon.shiny?
      event.despawn
    end
    if defined?(HoennNativeKIFSocial)
      HoennNativeKIFSocial.clear_notes if HoennNativeKIFSocial.respond_to?(:clear_notes)
      HoennNativeKIFSocial.instance_variable_set(:@pending_fusions, [])
      HoennNativeKIFSocial.instance_variable_set(:@pending_actions, []) if HoennNativeKIFSocial.instance_variable_defined?(:@pending_actions)
    end
  end

  def self.remove_patch_events
    (@events || []).each do |ev|
      next unless ev && $game_map && $game_map.events[ev.id].equal?(ev)
      ev.despawn
      remove_sprite(ev)
    end
    @events = []
  end

  # Temporary event sprites are allocated manually by KIF
  def self.remove_sprite(ev)
    return unless ev && $scene && $scene.respond_to?(:spritesets)
    sets = $scene.spritesets
    return unless sets
    set = sets[$game_map.map_id]
    return unless set && set.respond_to?(:character_sprites)
    sprites = set.character_sprites
    sprites.delete_if do |sprite|
      character = sprite.instance_variable_get(:@character)
      next false unless character.equal?(ev)
      sprite.dispose unless sprite.disposed?
      true
    end
  rescue StandardError => e
    HoennNativeKIF.log("Radar sprite cleanup: #{e.class}: #{e.message}") if defined?(HoennNativeKIF)
  end

  def self.valid_event?(ev, x, y)
    return false unless ev && $game_map.events[ev.id].equal?(ev)
    return false unless ev.respond_to?(:pokemon) && ev.pokemon
    return false unless ev.x == x && ev.y == y
    true
  end

  def self.stationary!(ev)
    return unless ev && ev.is_a?(OverworldPokemonEvent)
    ev.instance_variable_set(:@hno_radar_stationary, true)
    # These fields are runtime Game_Event state; the RPG::Event template
    ev.instance_variable_set(:@through, false)
    ev.instance_variable_set(:@trigger, 0)
    ev.instance_variable_set(:@priority_type, 1) if ev.instance_variable_defined?(:@priority_type)
    ev.instance_variable_set(:@always_on_top, false)
    ev.instance_variable_set(:@erased, false)
    ev.behavior_roaming = :still
    ev.behavior_noticed = :still
    ev.detection_radius = 0 if ev.respond_to?(:detection_radius=)
    ev.current_state = :ROAMING
    ev.update_movement_type if ev.respond_to?(:update_movement_type)
    ev.instance_variable_set(:@move_type, MOVE_TYPE_FIXED)
    ev.instance_variable_set(:@move_route_forcing, false)
    ev.manual_ow_pokemon = true if ev.respond_to?(:manual_ow_pokemon=)
    ev.step_anime = true if ev.respond_to?(:step_anime=)
  end

  # Mirror the native Bag Radar's encounter-selection logic once per patch
  def self.choose_for_patch(patch, session)
    rarity = patch[3].to_i
    ring = patch[2].to_i
    chain = session[2].to_i
    if chain > 0
      if rarity == 2 || rand(100) < 86 + ring * 4 + (chain / 4).floor
        return [session[0], session[1]]
      end
      # Native chain-break roll: select a different species if possible
      100.times do
        choice = $PokemonEncounters.choose_wild_pokemon($PokemonEncounters.encounter_type)
        return choice if choice && choice[0] != session[0]
      end
      return nil
    end
    pbPokeRadarGetEncounter(rarity)
  end

  def self.spawn_patches(session)
    patches = session[3]
    return unless patches.is_a?(Array)
    patches.each do |patch|
      next unless patch.is_a?(Array) && patch.length >= 4
      x, y = patch[0].to_i, patch[1].to_i
      next unless x >= 0 && y >= 0 && x < $game_map.width && y < $game_map.height
      next if $game_map.events.values.any? { |e| e && e.x == x && e.y == y && !e.instance_variable_get(:@erased) }
      terrain = $game_map.terrain_tag(x, y)
      next unless terrain.land_wild_encounters && terrain.shows_grass_rustle
      wild = choose_for_patch(patch, session)
      next unless wild && wild[0] && wild[1]
      # Construct from the Radar choice, not the generic random-spawn pipeline
      event = create_overworld_pokemon_event(wild, [x,y], :Land, :still, :still)
      $PokemonTemp.overworld_pokemon_on_map ||= []
      $PokemonTemp.overworld_pokemon_on_map << event.id if event
      next unless event
      unless valid_event?(event, x, y)
        event.despawn if event.respond_to?(:despawn)
        remove_sprite(event)
        next
      end
      # Hoenn setup can reroll special species and shiny status
      if event.species != wild[0] || event.level != wild[1]
        event.species = wild[0]
        event.level = wild[1]
        event.pokemon = Pokemon.new(wild[0], wild[1])
        event.initialize_sprite(:Land, GameData::Species.get(wild[0]))
      end
      stationary!(event)
      event.instance_variable_set(:@hno_radar_patch, patch.dup)
      # The shiny patch is authoritative. Never re-roll its shiny status
      if patch[3].to_i == 2 && event.respond_to?(:make_shiny)
        event.make_shiny
      end
      event.instance_variable_set(:@hno_radar_patch_generation, patches.object_id)
      @events << event
    end
    HoennNativeKIF.log("Bag Radar: #{@events.length} stationary patch Pokémon") if defined?(HoennNativeKIF)
  end

  # Called on battle-end, before KIF finishes despawning battle participants
  def self.after_wild_battle
    return unless active?
    @post_battle_frames = 8
  end

  def self.battle_busy?
    return true unless $scene.is_a?(Scene_Map)
    return true if $PokemonTemp && $PokemonTemp.overworld_wild_battle_triggered
    return true if $PokemonTemp && $PokemonTemp.overworld_wild_battle_participants &&
                   !$PokemonTemp.overworld_wild_battle_participants.empty?
    false
  end

  def self.tick
    return if HoennNativeKIF.safari_map?
    return unless $game_map && $game_map.events
    map = $game_map.object_id
    if @map_identity != map
      @map_identity = map
      @session = nil
      @patches = nil
      @pending_patches = nil
      @events = []
      @cleared_session = false
      @post_battle_frames = 0
    end
    session = active? ? $PokemonTemp.pokeradar : nil
    unless session
      # Never despawn battle participants in the middle of battle cleanup
      remove_patch_events unless @events.empty? || battle_busy?
      @session = @patches = @pending_patches = nil
      @cleared_session = false
      @post_battle_frames = 0
      return
    end
    if !@cleared_session || !@session.equal?(session)
      return if battle_busy?
      remove_patch_events
      clear_non_shiny
      @cleared_session = true
      @session = session
      @patches = nil
      @pending_patches = nil
    end
    patches = session[3]
    # Patch arrays are replaced on every scan
    if patches && !@patches.equal?(patches)
      @pending_patches = patches
    end
    return if battle_busy?
    if @post_battle_frames.to_i > 0
      @post_battle_frames -= 1
      return
    end
    if @pending_patches && !@patches.equal?(@pending_patches)
      # Check that the queued generation still belongs to this Radar session
      return unless session[3].equal?(@pending_patches)
      remove_patch_events
      @patches = @pending_patches
      @pending_patches = nil
      spawn_patches(session)
    end
  rescue StandardError => e
    HoennNativeKIF.log("Bag Radar integration error: #{e.class}: #{e.message}") if defined?(HoennNativeKIF)
  end

end

Events.onMapUpdate += proc { |_sender, _args| HoennNativeKIFRadar.tick }
# Set the barrier while KIF is still in the battle-end callback
Events.onWildBattleEnd += proc { |_sender, _args| HoennNativeKIFRadar.after_wild_battle }

# Bypass Hoenn's player-detection and movement AI entirely for Radar events
module HoennNativeKIFRadarStationary
  def update_behavior
    return if instance_variable_get(:@hno_radar_stationary)
    super
  end

  def update_movement_type
    if instance_variable_get(:@hno_radar_stationary)
      @move_type = MOVE_TYPE_FIXED # Native fixed movement constant
      @step_anime = true
      return
    end
    super
  end
end
OverworldPokemonEvent.prepend(HoennNativeKIFRadarStationary)

# The player battles the exact Pokemon already stored in the visible event
module HoennNativeKIFRadarBattle
  def overworldPokemonBattle(*args)
    if instance_variable_get(:@hno_radar_stationary) && $PokemonTemp && $PokemonTemp.pokeradar
      return if lock? || $PokemonTemp.prevent_ow_battles || instance_variable_get(:@_triggered) || $PokemonTemp.overworld_wild_battle_triggered
      session = $PokemonTemp.pokeradar
      if session[2].to_i == 0
        session[0] = pokemon.species
        session[1] = pokemon.level
      end
      $PokemonTemp.forceSingleBattle = true
      # Prevent native shaking-grass logic from rolling a second encounter
      instance_variable_set(:@hno_radar_battling, true)
    end
    super
  end
end
OverworldPokemonEvent.prepend(HoennNativeKIFRadarBattle)

# Radar encounters are not surprise battles
module HoennNativeKIFRadarNoSurprise
  def start_battle(event)
    return event.overworldPokemonBattle if event.instance_variable_get(:@hno_radar_stationary)
    super
  end
end
HoennNativeKIFSurprise.singleton_class.prepend(HoennNativeKIFRadarNoSurprise)


# The native roaming setter applies weather movement AFTER choosing :still
module HoennNativeKIFRadarMovement
  def set_roaming_movement(*args)
    if instance_variable_get(:@hno_radar_stationary)
      @move_type = MOVE_TYPE_FIXED
      @move_route_forcing = false
      @step_anime = true
      return
    end
    super
  end

  def set_noticed_movement(*args)
    if instance_variable_get(:@hno_radar_stationary)
      @move_type = MOVE_TYPE_FIXED
      return
    end
    super
  end

  def update(*args)
    if instance_variable_get(:@hno_radar_stationary)
      @move_type = MOVE_TYPE_FIXED
      @move_route_forcing = false
    end
    super
  end
end
OverworldPokemonEvent.prepend(HoennNativeKIFRadarMovement)

# No tile-triggered encounters while Radar patches are represented by interactive overworld events
module HoennNativeKIFRadarStepSuppression
  def encounter_triggered?(*args)
    return false if HoennNativeKIFRadar.active?
    super
  end
end
PokemonEncounters.prepend(HoennNativeKIFRadarStepSuppression)

# Native event interaction is the single entry point
module HoennNativeKIFRadarInteraction
  def start(*args)
    if instance_variable_get(:@hno_radar_stationary)
      return if instance_variable_get(:@hno_radar_battling)
      return overworldPokemonBattle
    end
    super
  end
end
DynamicOverworldPokemonEvent.prepend(HoennNativeKIFRadarInteraction)

# Dispose the manually allocated Sprite_Character whenever a Radar event
module HoennNativeKIFRadarDespawn
  def despawn(*args)
    radar = instance_variable_get(:@hno_radar_stationary)
    result = super
    HoennNativeKIFRadar.remove_sprite(self) if radar
    result
  end
end
OverworldPokemonEvent.prepend(HoennNativeKIFRadarDespawn)
