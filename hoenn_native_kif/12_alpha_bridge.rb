# Optional bridge for Loopy's Alpha Encounters (Raids.rb).
# All Alpha generation remains owned by Alpha Encounters.
module HoennNativeKIFAlphaBridge
  def self.available?
    defined?(ModSettingsMenu) && ModSettingsMenu.respond_to?(:get) &&
      Object.private_method_defined?(:make_alpha) &&
      defined?(Pokemon) && Pokemon.method_defined?(:alpha?)
  end

  def self.roll(event)
    return unless available? && event && event.pokemon
    return if HoennNativeKIF.safari_map? # No Alpha encounters in Safari.
    return if event.instance_variable_get(:@hno_alpha_rolled)
    event.instance_variable_set(:@hno_alpha_rolled, true)
    return if event.pokemon.alpha?
    chance = [[(ModSettingsMenu.get(:alpha_encounterchance) || 1).to_i, 0].max, 100].min
    divisor = 100
    if defined?(RelicSystem) && RelicSystem.respond_to?(:active?) && RelicSystem.active?(:ALPHA_RELIC)
      divisor = 150
    end
    return unless rand(divisor) < chance
    # Preserve the Alpha stats, moves, IVs and items.
    event.send(:make_alpha, event.pokemon)
    if divisor == 150 && event.pokemon.respond_to?(:shiny=)
      event.pokemon.shiny = true
    end
    event.level = event.pokemon.level if event.respond_to?(:level=)
    return unless event.pokemon.alpha?
    event.instance_variable_set(:@hno_alpha_spawned, true)
    # Radar patches must stay stationary or the chain becomes unusable.
    unless event.instance_variable_get(:@hno_radar_stationary)
      event.behavior_noticed = :aggressive
      event.behavior_roaming = :random
      event.detection_radius = [event.detection_radius.to_i, 6].max if event.respond_to?(:detection_radius=)
      event.update_movement_type if event.respond_to?(:update_movement_type)
    end
  rescue StandardError => e
    HoennNativeKIF.log("Alpha bridge roll: #{e.class}: #{e.message}") if defined?(HoennNativeKIF)
  end
end

module HoennNativeKIFAlphaEvent
  def setup_pokemon(*args)
    result = super
    HoennNativeKIFAlphaBridge.roll(self)
    result
  end

  def pokemon=(pkmn)
    @hno_alpha_rolled = false
    super
  end

  def should_start_battle?
    if @pokemon && @pokemon.respond_to?(:alpha?) && @pokemon.alpha? &&
       !instance_variable_get(:@hno_radar_stationary)
      return true if player_near_event?(1) &&
                     $PokemonTemp && $PokemonTemp.overworld_wild_battle_participants
    end
    super
  end
end
OverworldPokemonEvent.prepend(HoennNativeKIFAlphaEvent)

# Red outline for overworld alpha
module HoennNativeKIFAlphaOutline
  def hno_alpha_outline_dispose
    (@hno_alpha_outlines || []).each { |s| s.dispose unless s.disposed? }
    @hno_alpha_outlines = nil
  end

  def update(*args)
    result = super
    event = @character
    alpha = event.is_a?(OverworldPokemonEvent) && event.respond_to?(:pokemon) &&
            event.pokemon && event.pokemon.respond_to?(:alpha?) && event.pokemon.alpha?
    unless alpha && bitmap && !disposed? && visible && opacity > 0
      hno_alpha_outline_dispose if @hno_alpha_outlines
      return result
    end
    if !@hno_alpha_outlines || @hno_alpha_outlines.any? { |s| s.disposed? }
      hno_alpha_outline_dispose
      @hno_alpha_outlines = Array.new(4) { Sprite.new(viewport) }
    end
    [[-2,0],[2,0],[0,-2],[0,2]].each_with_index do |offset, i|
      sp = @hno_alpha_outlines[i]
      sp.bitmap = bitmap
      sp.src_rect.set(src_rect.x, src_rect.y, src_rect.width, src_rect.height)
      sp.ox, sp.oy = ox, oy
      sp.x, sp.y = x + offset[0], y + offset[1]
      sp.z = z - 1
      sp.zoom_x, sp.zoom_y = zoom_x, zoom_y
      sp.mirror = mirror
      sp.opacity = opacity
      sp.visible = visible
      sp.color = Color.new(255, 0, 0, 255)
      sp.tone = Tone.new(0, 0, 0, 0)
    end
    result
  end

  def dispose(*args)
    hno_alpha_outline_dispose
    super
  end
end
Sprite_Character.prepend(HoennNativeKIFAlphaOutline)


# Suppress alpha roll at battle start
# hopefully this will only effect wild
module HoennNativeKIFAlphaChanceGate
  def get(key, *args)
    if key == :alpha_encounterchance &&
       HoennNativeKIFAlphaBridge.overworld_battle_active?
      return 0
    end
    super
  end
end

module HoennNativeKIFAlphaBattleScope
  def overworldPokemonBattle(*args)
    HoennNativeKIFAlphaBridge.begin_overworld_battle
    begin
      super
    ensure
      HoennNativeKIFAlphaBridge.end_overworld_battle
    end
  end
end

module HoennNativeKIFAlphaBridge
  @overworld_battle_depth = 0

  def self.overworld_battle_active?
    @overworld_battle_depth.to_i > 0
  end

  def self.begin_overworld_battle
    @overworld_battle_depth = @overworld_battle_depth.to_i + 1
  end

  def self.end_overworld_battle
    @overworld_battle_depth = [@overworld_battle_depth.to_i - 1, 0].max
  end
end

if defined?(ModSettingsMenu) && ModSettingsMenu.respond_to?(:get)
  ModSettingsMenu.singleton_class.prepend(HoennNativeKIFAlphaChanceGate)
end
OverworldPokemonEvent.prepend(HoennNativeKIFAlphaBattleScope)
