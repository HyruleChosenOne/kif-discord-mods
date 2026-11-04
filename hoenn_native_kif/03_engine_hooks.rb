module HoennNativeKIFTempEventPatch
  def createTempEvent(template_id, map_id, position = [0,0], direction = nil, event_class = Game_Event, &block)
    unless event_class == DynamicOverworldPokemonEvent && template_id == TEMPLATE_EVENT_OW_POKEMON_NORMAL
      return super
    end
    return nil unless $scene.is_a?(Scene_Map)
    event = HoennNativeKIF.make_event(map_id, position, event_class)
    event.direction = direction if direction
    block.call(event) if block
    event.step_anime = true if event.respond_to?(:step_anime=)
    registerTempEvent(map_id, event)
    $game_map.events[event.id] = event
    $scene.spritesets[$game_map.map_id] = Spriteset_Map.new($game_map) unless $scene.spritesets[$game_map.map_id]
    sprite = Sprite_Character.new(Spriteset_Map.viewport, event)
    $scene.spritesets[$game_map.map_id].character_sprites.push(sprite)
    HoennNativeKIF.log("Spawned #{event.species} at #{event.x},#{event.y}")
    event
  end
end
PokemonTemp.prepend(HoennNativeKIFTempEventPatch)

# Keep all non-step battles intact, but do not convert grass steps to battles
module HoennNativeKIFStepBattlePatch
  def pbBattleOnStepTaken(*args)
    return nil if HoennNativeKIF.ready?
    super
  end
end
Object.prepend(HoennNativeKIFStepBattlePatch)
Events.onMapUpdate += proc { |_sender, _e| HoennNativeKIF.tick }
HoennNativeKIF.log('Loaded Compatibility Expansion v0.9')

# Native Hoenn events may be registered without the interpreter executing their RPG::Event command list
module HoennNativeKIFInteraction
  def start
    if is_a?(DynamicOverworldPokemonEvent) && respond_to?(:pokemon) && pokemon
      return HoennNativeKIFSafari.start_encounter(self) if HoennNativeKIF.safari_map?
      return HoennNativeKIFSurprise.start_battle(self)
    end
    super
  end
end
Game_Event.prepend(HoennNativeKIFInteraction)

# The original Hoenn roaming state intentionally disables step animation
module HoennNativeKIFIdleAnimation
  def set_roaming_movement
    super
    @step_anime = true if is_a?(DynamicOverworldPokemonEvent) && @setup_complete
  end
end
OverworldPokemonEvent.prepend(HoennNativeKIFIdleAnimation)

# KIF includes Hoenn's DynamicWeather_Utils.rb, but does not always initialize $game_weather
module HoennNativeKIFWeatherCompatibility
  WEATHER_CATEGORIES = {
    :isWeatherRain? => :Rain,
    :isWeatherSunny? => :Sunny,
    :isWeatherStorm? => :Storm,
    :isWeatherWind? => :Wind,
    :isWeatherFog? => :Fog,
    :isWeatherSnow? => :Snow
  }
  WEATHER_CATEGORIES.each do |method_name, category|
    define_method(method_name) do
      return super() if $game_weather && $game_weather.respond_to?(:get_map_weather_type)
      weather_type = $game_screen.weather_type if $game_screen
      return false unless weather_type
      weather_data = GameData::Weather.try_get(weather_type) if defined?(GameData::Weather)
      return weather_data.category == category if weather_data
      false
    end
  end
end
Object.prepend(HoennNativeKIFWeatherCompatibility)


# KIF's SpriteAnimation#initialize leaves @_animation_duration unset, but SpriteAnimation#effect? compares it to zero
module HoennNativeKIFSpriteAnimationInit
  def initialize(sprite)
    super
    @_animation_duration = 0 if @_animation_duration.nil?
  end

  def effect?
    @_animation_duration = 0 if @_animation_duration.nil?
    super
  end
end
SpriteAnimation.prepend(HoennNativeKIFSpriteAnimationInit) if defined?(SpriteAnimation)

# Hoenn already calls this callback ONLY when its two wild participants fuse
module HoennNativeKIFFusionAnnouncement
  def fuse_wild_pokemon_animation(battler1, battler2)
    pbMessage(_INTL("The two wild Pokémon suddenly fused together!"))
    HoennNativeKIFFusionFX.play(battler1, battler2)
    # Do not invoke the native animation here: KIF's missing/unsupported animation resource renders invisibly
  end
end
Object.prepend(HoennNativeKIFFusionAnnouncement)

# Self-contained screen-space fusion burst

# Safari Pokemon still roam, but the encounter uses Safari Balls, not a normal battle.
module HoennNativeKIFSafari
  def self.with_pokemon(pkmn)
    previous = @active_pokemon
    @active_pokemon = pkmn
    yield
  ensure
    @active_pokemon = previous
  end

  def self.active_pokemon
    @active_pokemon
  end

  def self.start_encounter(event)
    return unless event && event.respond_to?(:pokemon) && event.pokemon
    return if event.instance_variable_get(:@_hno_safari_busy)
    return if $PokemonTemp && $PokemonTemp.prevent_ow_battles
    event.instance_variable_set(:@_hno_safari_busy, true)
    begin
      pkmn = event.pokemon
      HoennNativeKIFSafari.with_pokemon(pkmn) do
        pbSafariBattle(pkmn.species, pkmn.level)
      end
      # A Safari encounter ends when the Pokemon is caught or runs away.
      event.erase
      $PokemonTemp.overworld_pokemon_on_map.delete(event.id) if $PokemonTemp && $PokemonTemp.overworld_pokemon_on_map
      $game_map.events.delete(event.id) if $game_map && $game_map.events
      if $PokemonTemp && $PokemonTemp.tempEvents
        $PokemonTemp.tempEvents.each_value { |events| events.delete_if { |e| e && e.id == event.id && e.map_id == event.map_id } }
      end
    ensure
      event.instance_variable_set(:@_hno_safari_busy, false)
    end
  end
end

# Aggressive Pokemon can also bump into the player inside Safari.
module HoennNativeKIFSafariBattlePatch
  def overworldPokemonBattle(*args)
    if is_a?(DynamicOverworldPokemonEvent) && HoennNativeKIF.safari_map?
      return HoennNativeKIFSafari.start_encounter(self)
    end
    super
  end
end
OverworldPokemonEvent.prepend(HoennNativeKIFSafariBattlePatch)

# Safari generates a new Pokemon by default. Use the one players actually saw.
module HoennNativeKIFSafariPokemonPatch
  def pbGenerateWildPokemon(species, level, *args)
    visible = HoennNativeKIFSafari.active_pokemon
    return visible if visible && visible.species == species && visible.level == level
    super
  end
end
Object.prepend(HoennNativeKIFSafariPokemonPatch)
