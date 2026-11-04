module HoennNativeKIFSocial
  CHECK_FRAMES = 15
  COOLDOWN_FRAMES = 240
  FAILED_PAIR_COOLDOWN = 90
  MAX_PLAYER_DISTANCE = 14
  NEARBY_RADIUS = 1

  # Species tendencies shape reactions, but each spawned Pokemon also has a consistent individual temperament
  SPECIES_TENDENCIES = {
    :BIDOOF => :friendly, :SENTRET => :curious, :HOOTHOOT => :calm,
    :STUFFUL => :playful, :MACHOP => :competitive, :PUMPKABOO => :mischievous,
    :PIDGEY => :friendly, :RATTATA => :shy, :SKITTY => :playful,
    :MEOWTH => :curious, :MAREEP => :friendly, :WOOPER => :calm,
    :MANKEY => :competitive, :SPEAROW => :competitive
  }
  # Everybody gets a vibe, even if they missed the guest list above.
  TYPE_TENDENCIES = {
    :NORMAL => :friendly, :FIRE => :competitive, :WATER => :calm,
    :ELECTRIC => :playful, :GRASS => :friendly, :ICE => :calm,
    :FIGHTING => :competitive, :POISON => :mischievous,
    :GROUND => :calm, :FLYING => :curious, :PSYCHIC => :curious,
    :BUG => :playful, :ROCK => :calm, :GHOST => :mischievous,
    :DRAGON => :competitive, :DARK => :mischievous,
    :STEEL => :calm, :FAIRY => :playful
  }
  @species_profiles = {}
  TEMPERAMENTS = [:friendly, :playful, :curious, :calm, :shy, :competitive, :mischievous]
  REACTION_WEIGHTS = {
    :friendly => [[:greeting, 6], [:play, 3], [:curious, 1]],
    :playful => [[:play, 7], [:greeting, 2], [:curious, 1]],
    :curious => [[:curious, 6], [:greeting, 3], [:play, 1]],
    :calm => [[:greeting, 5], [:curious, 4], [:play, 1]],
    :shy => [[:curious, 6], [:greeting, 3], [:territorial, 1]],
    :competitive => [[:territorial, 6], [:play, 3], [:curious, 1]],
    :mischievous => [[:play, 5], [:curious, 3], [:territorial, 2]]
  }
  REACTIONS = [:greeting, :play, :curious, :territorial]
  @notes = []

  def self.personality(ev)
    existing = ev.instance_variable_get(:@kif_social_personality)
    return existing if existing
    temperament = TEMPERAMENTS[rand(TEMPERAMENTS.length)]
    ev.instance_variable_set(:@kif_social_personality, temperament)
    temperament
  end

  def self.species_tendency(ev)
    species = ev.species
    # Fusions can still mingle; we don't pretend they're just one parent.
    return :curious if defined?(isSpeciesFusion) && isSpeciesFusion(species)
    return SPECIES_TENDENCIES[species] if SPECIES_TENDENCIES.key?(species)
    @species_profiles ||= {}
    return @species_profiles[species] if @species_profiles.key?(species)

    data = GameData::Species.try_get(species)
    return :curious unless data
    types = data.types
    types = [data.type1, data.type2] unless types && !types.empty?
    choices = types.compact.uniq.map { |type| TYPE_TENDENCIES[type] }.compact
    choices = [:curious] if choices.empty?

    # Same species, same baseline temperament. No dice roll per encounter.
    name = data.id.to_s
    seed = name.bytes.inject(0) { |sum, byte| (sum * 31 + byte) & 0x7fffffff }
    tendency = choices[seed % choices.length]
    stats = data.base_stats
    if stats && stats.respond_to?(:[])
      attack = stats[:ATTACK].to_i + stats[:SPECIAL_ATTACK].to_i
      defense = stats[:DEFENSE].to_i + stats[:SPECIAL_DEFENSE].to_i
      speed = stats[:SPEED].to_i
      if attack > defense * 1.5 && attack > 130
        tendency = :competitive
      elsif defense > attack * 1.6 && defense > 150
        tendency = :calm
      elsif speed > 105 && tendency == :calm
        tendency = :curious
      end
    end
    @species_profiles[species] = tendency
  rescue StandardError
    :curious
  end

  def self.weighted_reaction(tendency)
    choices = REACTION_WEIGHTS[tendency] || REACTION_WEIGHTS[:curious]
    roll = rand(choices.inject(0) { |sum, item| sum + item[1] })
    choices.each do |name, weight|
      roll -= weight
      return name if roll < 0
    end
    :curious
  end

  def self.choose_reaction(a, b)
    roll = rand(100)
    if roll < 65
      # Shared species favor familiar greetings, while other pairings blend traits
      if a.species == b.species && rand(100) < 65
        return weighted_reaction(:friendly)
      end
      return weighted_reaction(rand(2) == 0 ? species_tendency(a) : species_tendency(b))
    elsif roll < 90
      return weighted_reaction(rand(2) == 0 ? personality(a) : personality(b))
    end
    REACTIONS[rand(REACTIONS.length)]
  end

  def self.emote(ev, id)
    return unless id && ev.respond_to?(:playAnimation)
    ev.playAnimation(id, ev.x, ev.y)
  rescue StandardError => e
    @last_error = "emote #{e.class}: #{e.message}"
  end

  # Smaller 1-pixel-resolution emotes with a soft shadow, highlight and restrained palette
  SOCIAL_EMOTE_PATTERNS = {
    :note => ["......aa.....", ".....abba....", ".....ab.a....", ".....ab..a...", ".....ab...a..", ".....ab......", ".....ab......", ".....ab......", "...aabb......", "..abbbb......", "..abbb.......", "...aa........"],
    :star => ["......a......", "......b......", ".....bcb.....", "aabbbcbbaa...", ".abccccba....", "..abcccba....", "...bcccba....", "...bcbcb.....", "..bba.abb....", ".bb....abb..."],
    :question => ["...abbbba....", "..abccccba...", "..bc....cb...", ".......cba...", "......cba....", ".....cba.....", ".....cb......", ".............", ".....cb......", ".....cb......"],
    :exclaim => ["....abba.....", "....bccb.....", "....bccb.....", "....bccb.....", "....bccb.....", "....abba.....", ".............", "....abba.....", "....abba....."],
    :heart => ["..abb..abb...", ".abccbabcba..", ".bcccccccba..", "..bccccccba..", "...bccccba...", "....bccba....", ".....bba....."]
  }

  def self.draw_social_emote(bitmap, kind, palette)
    pattern = SOCIAL_EMOTE_PATTERNS[kind] || SOCIAL_EMOTE_PATTERNS[:question]
    base = case palette
           when :blue then [Color.new(46, 93, 143), Color.new(75, 170, 214), Color.new(177, 239, 255)]
           when :pink then [Color.new(130, 59, 94), Color.new(231, 108, 158), Color.new(255, 199, 218)]
           else [Color.new(136, 95, 40), Color.new(247, 181, 65), Color.new(255, 239, 160)]
           end
    ox = (48 - pattern[0].length) / 2
    oy = (48 - pattern.length) / 2
    pattern.each_with_index do |line, y|
      line.each_char.with_index do |char, x|
        color = char == 'a' ? base[0] : (char == 'b' ? base[1] : (char == 'c' ? base[2] : nil))
        bitmap.fill_rect(ox + x, oy + y, 1, 1, color) if color
      end
    end
  end

  # Play a real Pokemon cry with a modest overworld volume
  CRY_VOLUME = 48
  CRY_GLOBAL_COOLDOWN = 72
  def self.schedule_cry(ev, frame)
    @cries ||= []
    @cries << [ev, frame]
  end

  def self.update_cries(frame)
    @cries ||= []
    @cries.delete_if do |ev, due|
      next false if frame < due
      if !ev.instance_variable_get(:@erased) &&
         $game_temp && !$game_temp.in_battle && !$game_temp.message_window_showing &&
         (!@last_cry_frame || frame - @last_cry_frame >= CRY_GLOBAL_COOLDOWN)
        begin
          pokemon = ev.respond_to?(:pokemon) ? ev.pokemon : nil
          if pokemon && defined?(GameData::Species) && GameData::Species.respond_to?(:play_cry)
            GameData::Species.play_cry(pokemon, CRY_VOLUME)
            @last_cry_frame = frame
          end
        rescue StandardError => e
          @last_error = "cry #{e.class}: #{e.message}"
        end
      end
      true
    end
  rescue StandardError => e
    @last_error = "cry update #{e.class}: #{e.message}"
    @cries = []
  end

  def self.effect(ev, frame, kind, count=1)
    return unless defined?(Sprite) && defined?(Bitmap) && ev.respond_to?(:screen_x)
    @notes ||= []
    count.times do |i|
      sprite = Sprite.new
      sprite.bitmap = Bitmap.new(48, 48)
      palette = kind == :note ? :blue : (kind == :heart ? :pink : :gold)
      draw_social_emote(sprite.bitmap, kind, palette)
      sprite.ox = 24
      sprite.oy = 24
      sprite.z = 99999
      sprite.visible = false
      offset = count == 1 ? 0 : (i.even? ? -10 : 10)
      @notes << [sprite, ev, frame, i * 9, offset, kind, i]
    end
  rescue StandardError => e
    @last_error = "effect #{e.class}: #{e.message}"
  end

  def self.note(ev, frame)
    effect(ev, frame, :note, 3)
  end

  def self.clear_notes
    (@notes || []).each do |entry|
      sprite = entry[0]
      next unless sprite && !sprite.disposed?
      sprite.bitmap.dispose if sprite.bitmap && !sprite.bitmap.disposed?
      sprite.dispose
    end
    @notes = []
    @actions = []
    @cries = []
    @last_cry_frame = nil
  rescue StandardError
    @notes = []
    @actions = []
    @cries = []
    @last_cry_frame = nil
  end

  def self.update_notes(frame)
    @notes ||= []
    @notes.delete_if do |entry|
      sprite, ev, born, delay, offset, kind, index = entry
      age = frame - born - delay
      expired = age >= 62 || ev.instance_variable_get(:@erased)
      if expired
        unless sprite.disposed?
          sprite.bitmap.dispose if sprite.bitmap && !sprite.bitmap.disposed?
          sprite.dispose
        end
      elsif age >= 0
        # Notes bounce and sway; stars burst sideways; alerts pop and wobble
        sprite.visible = true
        rise = kind == :star ? age * 0.35 : age * 0.55
        spread = kind == :star ? (index.even? ? -1 : 1) * age * 0.6 : 0
        wobble = Math.sin(age / 4.0 + index) * (kind == :exclaim ? 3 : 7)
        bounce = Math.sin(age / 3.3).abs * (kind == :note ? 10 : 5)
        sprite.x = ev.screen_x + offset + spread.to_i + wobble.round
        sprite.y = ev.screen_y - 51 - rise.round - bounce.round
        # Elastic pop-in, rhythmic bob, and a soft fade-out
        pop = age < 8 ? (0.4 + age * 0.11) : 1.0
        pulse = 1.0 + Math.sin(age / 5.0) * 0.13
        sprite.zoom_x = sprite.zoom_y = pop * pulse * 1.55
        sprite.opacity = age < 43 ? 255 : [255 - (age - 43) * 14, 0].max
      else
        sprite.visible = false
      end
      expired
    end
  rescue StandardError => e
    @last_error = "effect update #{e.class}: #{e.message}"
    clear_notes
  end

  # Delayed actions make play reactions visibly different, while never blocking
  def self.schedule(ev, frame, action, partner=nil)
    @actions ||= []
    @actions << [ev, frame, action, partner]
  end

  # Express emotion primarily through movement
  def self.social_step(ev, partner, away=false)
    return unless partner && !partner.instance_variable_get(:@erased)
    return unless ev.respond_to?(:move_straight) && ev.respond_to?(:passable?)
    return if ev.moving? || ev.jumping?
    return if ($game_player.x - ev.x).abs + ($game_player.y - ev.y).abs <= 2
    dx = partner.x - ev.x
    dy = partner.y - ev.y
    return if dx == 0 && dy == 0
    # Prefer the dominant axis, but do not force movement into another event
    dir = if dx.abs >= dy.abs && dx != 0
            dx > 0 ? 6 : 4
          else
            dy > 0 ? 2 : 8
          end
    dir = {2=>8, 8=>2, 4=>6, 6=>4}[dir] if away
    tx = ev.x + (dir == 6 ? 1 : (dir == 4 ? -1 : 0))
    ty = ev.y + (dir == 2 ? 1 : (dir == 8 ? -1 : 0))
    return if tx == partner.x && ty == partner.y
    return if tx == $game_player.x && ty == $game_player.y
    ev.move_straight(dir) if ev.passable?(ev.x, ev.y, dir)
  end

  def self.update_actions(frame)
    @actions ||= []
    @actions.delete_if do |ev, due, action, partner|
      next false if frame < due
      unless ev.instance_variable_get(:@erased) ||
             (ev.respond_to?(:current_state) && ev.current_state != :ROAMING)
        case action
        when :hop
          ev.jump(0, 0) unless ev.moving? || ev.jumping?
        when :turn_left
          ev.turn_left_90 unless ev.moving? || ev.jumping?
        when :turn_right
          ev.turn_right_90 unless ev.moving? || ev.jumping?
        when :face
          face(ev, partner) if partner && !ev.moving? && !ev.jumping?
        when :approach
          social_step(ev, partner, false)
        when :retreat
          social_step(ev, partner, true)
        when :turn_away
          if partner && !ev.moving? && !ev.jumping?
            face(ev, partner)
            ev.turn_180 if ev.respond_to?(:turn_180)
          end
        end
      end
      true
    end
  rescue StandardError => e
    @last_error = "social action #{e.class}: #{e.message}"
    @actions = []
  end

  def self.perform_reaction(a, b, frame)
    kind = choose_reaction(a, b)
    schedule_cry(a, frame + 2)
    schedule_cry(b, frame + 82)
    face(a, b)
    face(b, a)
    case kind
    when :greeting
      # The exchange of cries is the main cue; one small note is optional
      effect(a, frame, :note) if rand(100) < 25
      schedule(a, frame + 14, :face, b)
      schedule(b, frame + 35, :face, a)
      schedule(a, frame + 51, :hop) if rand(100) < 35
    when :play
      # A little approach/retreat dance with staggered hops
      schedule(a, frame + 4, :approach, b)
      schedule(b, frame + 10, :hop)
      schedule(a, frame + 22, :hop)
      schedule(b, frame + 34, :turn_right)
      schedule(a, frame + 44, :retreat, b)
      schedule(b, frame + 50, :turn_left)
      schedule(a, frame + 62, :face, b)
      effect(b, frame + 10, :heart) if rand(100) < 15
    when :territorial
      # Hold eye contact, warn, then deliberately disengage
      effect(a, frame, :exclaim) if rand(100) < 35
      schedule(a, frame + 12, :face, b)
      schedule(b, frame + 20, :face, a)
      schedule(a, frame + 40, :retreat, b)
      schedule(b, frame + 56, :turn_away, a)
    else
      # Inspect, tilt/turn, and sometimes step back cautiously
      effect(a, frame, :question) if rand(100) < 35
      schedule(a, frame + 12, :turn_left)
      schedule(a, frame + 28, :face, b)
      schedule(b, frame + 34, :turn_right)
      schedule(b, frame + 48, :face, a)
      schedule(a, frame + 57, :retreat, b) if rand(100) < 50
    end
  rescue StandardError => e
    @last_error = "reaction #{e.class}: #{e.message}"
  end

  # One in 20 eligible social reactions; independent of pre-fused spawn odds
  FUSION_ROLL = 20
  FUSION_DELAY = 105
  @pending_fusions = []
  @last_error = nil
  @last_map = nil

  def self.event_ours?(ev)
    return false unless ev && ev.is_a?(DynamicOverworldPokemonEvent)
    raw = ev.instance_variable_get(:@event)
    raw && raw.name == "HoennNativeWild" && !ev.instance_variable_get(:@erased)
  end

  def self.reason(ev, frame)
    return :not_ours unless event_ours?(ev) && !ev.instance_variable_get(:@hno_radar_stationary)
    return :fighting if ev.instance_variable_get(:@hno_turf_busy)
    return :no_pokemon unless ev.respond_to?(:pokemon) && ev.pokemon
    return :state unless !ev.respond_to?(:current_state) || ev.current_state == :ROAMING
    return :jumping if ev.respond_to?(:jumping?) && ev.jumping?
    return :cooldown if ev.instance_variable_get(:@kif_social_cooldown).to_i > frame
    return :water if ev.instance_variable_get(:@terrain) == :Water
    return :distance if ($game_player.x - ev.x).abs + ($game_player.y - ev.y).abs > MAX_PLAYER_DISTANCE
    :eligible
  end

  def self.face(a,b)
    dx = b.x - a.x
    dy = b.y - a.y
    if dx.abs > dy.abs
      dx > 0 ? a.turn_right : a.turn_left
    elsif dy != 0
      dy > 0 ? a.turn_down : a.turn_up
    end
  end

  def self.unfused_for_social_fusion?(ev)
    return false unless event_ours?(ev) && ev.respond_to?(:pokemon)
    mon = ev.pokemon
    return false unless mon && !mon.shiny?
    return false if isSpeciesFusion(mon.species)
    return false if ev.instance_variable_get(:@kif_fusion_pending)
    return false if ev.instance_variable_get(:@terrain) == :Water
    true
  rescue StandardError
    false
  end

  def self.maybe_queue_fusion(a, b, frame)
    unless unfused_for_social_fusion?(a) && unfused_for_social_fusion?(b)
      return
    end
    roll = FUSION_ROLL
    unless rand(roll) == 0
      return
    end
    fused = fusionOf(a.pokemon.species, b.pokemon.species)
    unless fused && isSpeciesFusion(fused)
      return
    end
    a.instance_variable_set(:@kif_fusion_pending, true)
    b.instance_variable_set(:@kif_fusion_pending, true)
    @pending_fusions ||= []
    # Clear social choreography so the pair can face one another before fusing
    @actions = (@actions || []).reject { |act| act[0].equal?(a) || act[0].equal?(b) }
    face(a, b)
    face(b, a)
    @pending_fusions << [a, b, fused, frame + FUSION_DELAY, $game_map.object_id]
  rescue StandardError => e
    @last_error = "fusion queue #{e.class}: #{e.message}"
  end

  # Localized fusion lighting: two small glowing overlays follow the parent sprites, with tiny sparkling points
  def self.fusion_glow(ev, frame, duration=24, strong=false)
    return unless ev && defined?(Sprite) && defined?(Bitmap)
    @fusion_fx ||= []
    glow = Sprite.new
    glow.bitmap = Bitmap.new(32, 36)
    glow.bitmap.fill_rect(5, 3, 22, 30, Color.new(225, 205, 255, strong ? 160 : 105))
    glow.bitmap.fill_rect(9, 6, 14, 24, Color.new(255, 255, 255, strong ? 95 : 55))
    glow.ox, glow.oy = 16, 31
    glow.z = 99998
    @fusion_fx << [glow, ev, frame, duration, :glow, 0]
    6.times do |i|
      sp = Sprite.new
      sp.bitmap = Bitmap.new(6, 6)
      sp.bitmap.fill_rect(2, 0, 2, 6, Color.new(255, 245, 195))
      sp.bitmap.fill_rect(0, 2, 6, 2, Color.new(255, 245, 195))
      sp.bitmap.fill_rect(2, 2, 2, 2, Color.new(255, 255, 255))
      sp.ox = sp.oy = 3
      sp.z = 99999
      @fusion_fx << [sp, ev, frame + (i % 3) * 4, duration, :spark, i]
    end
  rescue StandardError => e
    @last_error = "fusion fx #{e.class}: #{e.message}"
  end

  def self.clear_fusion_fx
    (@fusion_fx || []).each do |entry|
      sp = entry[0]
      next unless sp && !sp.disposed?
      sp.bitmap.dispose if sp.bitmap && !sp.bitmap.disposed?
      sp.dispose
    end
    @fusion_fx = []
  end

  def self.update_fusion_fx(frame)
    @fusion_fx ||= []
    @fusion_fx.delete_if do |sp, ev, born, duration, kind, i|
      age = frame - born
      expired = age >= duration || !ev || ev.instance_variable_get(:@erased)
      if expired
        unless sp.disposed?
          sp.bitmap.dispose if sp.bitmap && !sp.bitmap.disposed?
          sp.dispose
        end
      elsif age >= 0
        sp.visible = true
        if kind == :glow
          sp.x, sp.y = ev.screen_x, ev.screen_y
          sp.opacity = (155 * Math.sin(Math::PI * age / duration)).to_i
          sp.zoom_x = 1.0 + 0.12 * Math.sin(age * 0.5)
          sp.zoom_y = 1.0
        else
          angle = (i * Math::PI / 3.0) + age * 0.075
          radius = 7 + age * 0.48
          sp.x = ev.screen_x + (Math.cos(angle) * radius).round
          sp.y = ev.screen_y - 18 + (Math.sin(angle) * radius * 0.7).round - (age * 0.28).round
          sp.opacity = [255 - age * 8, 0].max
          sp.zoom_x = sp.zoom_y = 0.75 + 0.2 * Math.sin(age * 0.4).abs
        end
      else
        sp.visible = false
      end
      expired
    end
  rescue StandardError => e
    @last_error = "fusion fx update #{e.class}: #{e.message}"
    clear_fusion_fx
  end

  def self.update_fusions(frame)
    @pending_fusions ||= []
    @pending_fusions.delete_if do |a, b, fused, due, map_object_id|
      # Non-blocking three-beat sequence with localized parent glows and sparkles
      age = frame - (due - FUSION_DELAY)
      if frame < due
        if $game_map && $game_map.object_id == map_object_id &&
           !$game_temp.in_battle && !$game_temp.message_window_showing &&
           unfused_for_pending_fusion?(a) && unfused_for_pending_fusion?(b)
          if age == 30
            face(a, b) unless a.moving? || a.jumping?
            face(b, a) unless b.moving? || b.jumping?
          elsif age == 58
            fusion_glow(a, frame, 23)
            fusion_glow(b, frame, 23)
          elsif age == 83
            fusion_glow(a, frame, 19, true)
            fusion_glow(b, frame, 19, true)
          end
        end
        next false
      end
      begin
        valid = $game_map && $game_map.object_id == map_object_id &&
                $scene.is_a?(Scene_Map) &&
                !$game_temp.in_battle && !$game_temp.message_window_showing &&
                unfused_for_pending_fusion?(a) && unfused_for_pending_fusion?(b) &&
                (a.x-b.x).abs + (a.y-b.y).abs <= 2
        if valid
          # The survivor occupies the first participant's existing tile
          terrain = a.instance_variable_get(:@terrain) || :Land
          level = [(a.pokemon.level + b.pokemon.level) / 2, 1].max
          new_event = spawn_overworld_pokemon([fused, level], [a.x, a.y], terrain)
          if new_event
            fusion_glow(new_event, frame, 26, true)
            new_event.instance_variable_set(:@kif_social_cooldown, frame + 600)
            # Both original event objects are removed using Hoenn's own despawn cleanup, including temporary-event registration
            a.despawn
            b.despawn
            @actions = (@actions || []).reject { |act| act[0].equal?(a) || act[0].equal?(b) }
            @cries = (@cries || []).reject { |cry| cry[0].equal?(a) || cry[0].equal?(b) }
            HoennNativeKIF.log("Spontaneous fusion: #{a.pokemon.species} + #{b.pokemon.species} -> #{fused}")
          else
          end
        else
        end
      rescue StandardError => e
        @last_error = "fusion commit #{e.class}: #{e.message}"
        HoennNativeKIF.log(@last_error)
      ensure
        a.instance_variable_set(:@kif_fusion_pending, false) if a
        b.instance_variable_set(:@kif_fusion_pending, false) if b
      end
      true
    end
  end

  def self.unfused_for_pending_fusion?(ev)
    return false if ev.instance_variable_get(:@hno_radar_stationary)
    return false unless event_ours?(ev) && ev.pokemon && !ev.pokemon.shiny?
    return false if isSpeciesFusion(ev.pokemon.species)
    return false unless ev.current_state == :ROAMING
    $game_map.events[ev.id].equal?(ev)
  end

  def self.tick
    return if HoennNativeKIF.safari_map?
    return unless $game_map && $game_player && $scene && $scene.is_a?(Scene_Map)
    frame = Graphics.frame_count
    if @last_map != $game_map.object_id
      clear_notes
      clear_fusion_fx
      @pending_fusions = []
      @last_map = $game_map.object_id
      @last_error = nil
    end
    update_notes(frame)
    update_fusion_fx(frame)
    update_actions(frame)
    update_cries(frame)
    update_fusions(frame)
    return unless frame % CHECK_FRAMES == 0
    unless HoennNativeKIFSettings.enabled? && HoennNativeKIFSettings.social?
      clear_notes
      return
    end
    if $game_temp && ($game_temp.in_menu || $game_temp.message_window_showing || $game_temp.in_battle)
      return
    end
    # KIF 6.8.2 does not guarantee Game_Map#interpreter exists
    if $game_map.respond_to?(:interpreter) &&
       $game_map.interpreter && $game_map.interpreter.running?
      return
    end
    all = $game_map.events.values.select { |ev| event_ours?(ev) }
    events = []
    all.each do |ev|
      why = reason(ev, frame)
      if why == :eligible
        events << ev
      else
      end
    end
    if events.length >= 2
      used = {}
      events.each do |a|
        next if used[a.object_id] || reason(a,frame) != :eligible
        neighbors = events.select do |b|
          next false if b.equal?(a) || used[b.object_id] || reason(b,frame) != :eligible
          dx = (a.x - b.x).abs
          dy = (a.y - b.y).abs
          (dx + dy) == NEARBY_RADIUS # Exactly one cardinal tile; no diagonals
        end
        next if neighbors.empty?
        neighbors.sort_by! { |b| [(a.species == b.species ? 0 : 1), (a.x-b.x).abs + (a.y-b.y).abs] }
        b = neighbors.first
        used[a.object_id] = used[b.object_id] = true
        if rand(100) >= HoennNativeKIFSettings.social_chance
          a.instance_variable_set(:@kif_social_cooldown, frame + FAILED_PAIR_COOLDOWN)
          b.instance_variable_set(:@kif_social_cooldown, frame + FAILED_PAIR_COOLDOWN)
          next
        end
        a.instance_variable_set(:@kif_social_cooldown, frame + COOLDOWN_FRAMES)
        b.instance_variable_set(:@kif_social_cooldown, frame + COOLDOWN_FRAMES)
        perform_reaction(a, b, frame)
        maybe_queue_fusion(a, b, frame)
      end
    end
  rescue StandardError => e
    @last_error = "#{e.class}: #{e.message}"
    HoennNativeKIF.log("Social update error: #{@last_error}")
  end
end
Events.onMapUpdate += proc { |_sender, _args| HoennNativeKIFSocial.tick }
