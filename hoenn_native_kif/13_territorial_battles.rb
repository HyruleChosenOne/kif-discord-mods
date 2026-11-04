# Personal test: sometimes two wild Pokemon settle a turf dispute.
module HoennNativeKIFTerritorial
  CHECK_FRAMES = 30
  ATTACK_ROLL = 30  # Still uncommon when two Pokemon meet.
  SAME_SPECIES_ROLL = 40
  FIGHT_FRAMES = 100
  EVOLVE_ROLL = 1000      # The long-shot evolution roll.
  COOLDOWN = 900
  @fights = []
  @dust = []

  def self.valid?(ev)
    return false unless defined?(HoennNativeKIFSocial) && HoennNativeKIFSocial.event_ours?(ev)
    return false unless ev.respond_to?(:pokemon) && ev.pokemon
    return false unless $game_map.events[ev.id].equal?(ev)
    return false if ev.instance_variable_get(:@hno_radar_stationary)
    return false if ev.instance_variable_get(:@kif_fusion_pending) || ev.instance_variable_get(:@hno_turf_busy)
    return false if ev.instance_variable_get(:@terrain) == :Water
    return false if ev.respond_to?(:current_state) && ev.current_state != :ROAMING
    true
  end

  def self.fleeing?(ev)
    behavior = ev.respond_to?(:behavior_noticed) ? ev.behavior_noticed : nil
    [:flee, :flee_flying, :teleport_away].include?(behavior) ||
      [:SKITTY, :ABRA, :RALTS].include?(ev.species)
  end

  def self.aggressive?(ev)
    return false if fleeing?(ev)
    noticed = ev.respond_to?(:behavior_noticed) ? ev.behavior_noticed : nil
    return true if [:aggressive, :semi_aggressive].include?(noticed)
    HoennNativeKIFSocial.species_tendency(ev) == :competitive ||
      HoennNativeKIFSocial.personality(ev) == :competitive
  end

  def self.special?(ev)
    mon = ev.pokemon
    (mon.respond_to?(:shiny?) && mon.shiny?) ||
      (mon.respond_to?(:hasHiddenAbility?) && mon.hasHiddenAbility?) ||
      (mon.respond_to?(:alpha?) && mon.alpha?)
  end

  def self.winner_pair(a, b)
    # A rare Pokemon only loses to another rare Pokemon.
    a_special, b_special = special?(a), special?(b)
    return [a, b] if a_special && !b_special
    return [b, a] if b_special && !a_special
    weight = [[50 + (a.pokemon.level - b.pokemon.level) * 4, 20].max, 80].min
    rand(100) < weight ? [a, b] : [b, a]
  end

  def self.hide_fighter(ev)
    old = ev.instance_variable_get(:@transparent)
    ev.instance_variable_set(:@hno_turf_old_transparent, old)
    ev.instance_variable_set(:@transparent, true)
  end

  def self.show_fighter(ev)
    return unless ev
    old = ev.instance_variable_get(:@hno_turf_old_transparent)
    ev.instance_variable_set(:@transparent, old.nil? ? false : old)
    ev.remove_instance_variable(:@hno_turf_old_transparent) if ev.instance_variable_defined?(:@hno_turf_old_transparent)
  end

  def self.dispose_dust
    (@dust || []).each do |sp, *|
      next unless sp && !sp.disposed?
      sp.bitmap.dispose if sp.bitmap && !sp.bitmap.disposed?
      sp.dispose
    end
    @dust = []
  end

  def self.reset
    (@fights || []).each do |a, b, *|
      [a, b].each do |ev|
        show_fighter(ev)
        ev.instance_variable_set(:@hno_turf_busy, false) if ev
      end
    end
    @fights = []
    dispose_dust
  end

  def self.cloud(a, b, frame)
    # The dust hides the whole fight. Pokemon can keep their dignity.
    return unless defined?(Sprite) && defined?(Bitmap)
    sp = Sprite.new
    bmp = Bitmap.new(72, 64)
    dark = Color.new(139, 121, 100, 255)
    mid = Color.new(188, 170, 146, 255)
    light = Color.new(221, 208, 185, 255)
    # Opaque overlapping puffs, not see-through particles.
    [[12, 16, 48, 37], [5, 25, 62, 24], [21, 8, 30, 47]].each do |x,y,w,h|
      bmp.fill_rect(x, y, w, h, dark)
    end
    [[11, 20, 50, 30], [18, 12, 36, 39], [7, 29, 58, 15]].each do |x,y,w,h|
      bmp.fill_rect(x, y, w, h, mid)
    end
    [[16, 17, 23, 13], [34, 27, 24, 15], [15, 38, 30, 8]].each do |x,y,w,h|
      bmp.fill_rect(x, y, w, h, light)
    end
    sp.bitmap = bmp
    sp.ox = 36
    sp.oy = 48
    sp.z = 99999
    sp.opacity = 255
    @dust << [sp, a, frame]
  rescue StandardError => e
    sp.dispose if sp && !sp.disposed?
    bmp.dispose if bmp && !bmp.disposed?
    HoennNativeKIF.log("Turf dust: #{e.class}: #{e.message}")
  end

  def self.update_dust(frame)
    @dust.delete_if do |sp, anchor, born|
      age = frame - born
      gone = age >= FIGHT_FRAMES || !valid_map_event?(anchor)
      if gone
        unless sp.disposed?
          sp.bitmap.dispose if sp.bitmap && !sp.bitmap.disposed?
          sp.dispose
        end
      else
        # Stay on the attacker's tile until the winner is revealed.
        sp.x = anchor.screen_x + Math.sin(age * 0.31).round * 2
        sp.y = anchor.screen_y - 12 + Math.cos(age * 0.23).round * 2
        sp.zoom_x = 1.0 + Math.sin(age * 0.20).abs * 0.10
        sp.zoom_y = 1.0 + Math.cos(age * 0.17).abs * 0.10
        sp.opacity = 255
      end
      gone
    end
  end

  def self.valid_map_event?(ev)
    ev && $game_map && $game_map.events[ev.id].equal?(ev) &&
      !ev.instance_variable_get(:@erased)
  end

  def self.evolution_target(mon)
    return nil unless mon && mon.respond_to?(:species_data)
    return nil if mon.respond_to?(:egg?) && mon.egg?
    return nil if mon.respond_to?(:shadowPokemon?) && mon.shadowPokemon?
    return nil if mon.respond_to?(:hasItem?) && mon.hasItem?(:EVERSTONE)
    return nil if mon.respond_to?(:hasAbility?) && mon.hasAbility?(:BATTLEBOND)
    return nil if defined?(isSpeciesFusion) && isSpeciesFusion(mon.species)

    choices = mon.species_data.get_evolutions(true).reject { |evo| evo[3] }
    return nil if choices.empty?

    # If a level-up evolution is already earned, no dice roll needed.
    earned = choices.select do |species, method, parameter, _|
      rule = GameData::Evolution.try_get(method)
      rule && rule.level_up_proc && rule.call_level_up(mon, parameter)
    end
    return earned.sample[0] unless earned.empty?

    # Other methods (or not-yet-met levels) get one very lucky chance.
    return nil unless HoennNativeKIFSettings.territorial_evo_test? || rand(EVOLVE_ROLL) == 0
    choices.sample[0]
  end

  def self.evolve(winner, frame)
    mon = winner.pokemon
    evolved = evolution_target(mon)
    return unless evolved && GameData::Species.try_get(evolved)
    old = mon.species
    HoennNativeKIFSocial.fusion_glow(winner, frame, 28, true)
    mon.species = evolved
    winner.instance_variable_set(:@species, mon.species)
    winner.instance_variable_set(:@level, mon.level)
    winner.initialize_sprite(winner.instance_variable_get(:@terrain) || :Land,
                             GameData::Species.get(mon.species))
    HoennNativeKIF.log("Turf evolution: #{old} -> #{mon.species}")
  rescue StandardError => e
    HoennNativeKIF.log("Turf evolution: #{e.class}: #{e.message}")
  end

  def self.update_fights(frame)
    @fights.delete_if do |a, b, due, map_id|
      if frame < due && $game_map.object_id == map_id && valid_map_event?(a) && valid_map_event?(b)
        next false
      end
      begin
        if frame >= due && $game_map.object_id == map_id && valid_map_event?(a) && valid_map_event?(b)
          winner, loser = winner_pair(a, b)
          loser.despawn
          winner.instance_variable_set(:@kif_social_cooldown, frame + COOLDOWN)
          winner.instance_variable_set(:@hno_turf_cooldown, frame + COOLDOWN)
          evolve(winner, frame)
          # The survivor returns only after the dust clears.
          show_fighter(winner)
        end
      rescue StandardError => e
        HoennNativeKIF.log("Turf fight: #{e.class}: #{e.message}")
      ensure
        [a,b].each do |ev|
          show_fighter(ev) if valid_map_event?(ev)
          ev.instance_variable_set(:@hno_turf_busy, false)
        end
      end
      true
    end
  end

  def self.tick
    return if HoennNativeKIF.safari_map?
    return unless $game_map && $game_player && $scene && $scene.is_a?(Scene_Map)
    frame = Graphics.frame_count
    if @map != $game_map.object_id
      reset
      @map = $game_map.object_id
    end
    update_dust(frame)
    update_fights(frame)
    return unless frame % CHECK_FRAMES == 0
    return unless HoennNativeKIFSettings.enabled? && HoennNativeKIFSettings.social?
    return if $game_temp && ($game_temp.in_battle || $game_temp.in_menu || $game_temp.message_window_showing)
    return if defined?(HoennNativeKIFRadar) && HoennNativeKIFRadar.active?
    return if $game_map.respond_to?(:interpreter) && $game_map.interpreter && $game_map.interpreter.running?
    return unless (@fights || []).empty?  # One dust cloud at a time.
    events = $game_map.events.values.select { |ev| valid?(ev) }
    events.shuffle.each do |a|
      next if fleeing?(a)
      next if a.instance_variable_get(:@hno_turf_cooldown).to_i > frame
      next if ($game_player.x - a.x).abs + ($game_player.y - a.y).abs > 12
      b = events.find do |other|
        !other.equal?(a) && valid?(other) && !fleeing?(other) &&
          (aggressive?(a) || a.species == other.species) &&
          (a.x-other.x).abs + (a.y-other.y).abs == 1 &&
          other.instance_variable_get(:@hno_turf_cooldown).to_i <= frame
      end
      next unless b
      roll = aggressive?(a) ? ATTACK_ROLL : SAME_SPECIES_ROLL
      next unless HoennNativeKIFSettings.territorial_battle_test? || rand(roll) == 0
      a.instance_variable_set(:@hno_turf_busy, true)
      b.instance_variable_set(:@hno_turf_busy, true)
      # Turf and social encounters shouldn't keep each other on permanent cooldown.
      a.instance_variable_set(:@hno_turf_cooldown, frame + COOLDOWN)
      b.instance_variable_set(:@hno_turf_cooldown, frame + COOLDOWN)
      a.instance_variable_set(:@kif_social_cooldown, frame + COOLDOWN)
      b.instance_variable_set(:@kif_social_cooldown, frame + COOLDOWN)
      HoennNativeKIFSocial.face(a,b)
      HoennNativeKIFSocial.face(b,a)
      hide_fighter(a)
      hide_fighter(b)
      cloud(a,b,frame)
      @fights << [a,b,frame + FIGHT_FRAMES,$game_map.object_id]
      break
    end
  rescue StandardError => e
    HoennNativeKIF.log("Turf update: #{e.class}: #{e.message}")
  end
end
Events.onMapUpdate += proc { |_sender, _args| HoennNativeKIFTerritorial.tick }
