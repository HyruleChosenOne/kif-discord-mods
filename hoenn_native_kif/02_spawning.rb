module HoennNativeKIF
  ROUTE_ONE_ONLY = false
  TEST_MAP_ID = 78
  # Set to a list of map IDs to restrict testing, or nil for all maps
  MAP_ALLOWLIST = nil
  MAP_BLOCKLIST = []
  # Optional safety switch for maps with story cutscenes or unusual event logic
  PAUSE_DURING_EVENT = true
  SPAWN_EVERY_FRAMES = 180
  SPAWN_RADIUS = 15
  POPULATION_LIMIT = 6
  # Manhattan tile distance: protect 0-2 tiles; allow spawns from 3 onward.
  MIN_DISTANCE = 3
  NEAR_SPAWN_DISTANCE = 5
  NEAR_SPAWN_CHANCE_PERCENT = 50
  NATURAL_FUSION_PERCENT = 5
  # Living Towns settings (land wildlife only)
  TOWN_WILDLIFE_ENABLED = true
  TOWN_POPULATION_LIMIT = 3
  TOWN_SPAWN_CHANCE_PERCENT = 45  # checked every SPAWN_EVERY_FRAMES
  TOWN_MIN_DISTANCE = 3
  TOWN_LEVEL_RANGE = (3..7)
  # Overrides for maps whose names do not contain Town/City.
  TOWN_MAP_IDS = []
  TOWN_EXCLUDED_MAP_IDS = []
  # The bird pools are weighted by repeated entries. One or two day birds
  # and one night bird are chosen consistently for each town per game session
  DAY_BIRDS = [:PIDGEY, :TAILLOW, :STARLY, :PIDOVE, :FLETCHLING,
               :PIKIPEK, :ROOKIDEE, :SPEAROW]
  COAST_BIRDS = [:WINGULL, :WATTREL]
  NIGHT_BIRDS = [:HOOTHOOT, :MURKROW]
  # these are not birds
  TOWN_OTHER = [:MEOWTH, :MEOWTH, :SKITTY, :TRUBBISH, :TRUBBISH,
                :RATTATA, :ZIGZAGOON, :PURRLOIN, :LILLIPUP,
                :PACHIRISU, :ESPURR, :YAMPER]
  # Optional rarer urban encounters
  TOWN_RARE = [:KOFFING, :GROWLITHE, :PICHU]
  TOWN_RARE_PERCENT = 5
  # town water can host aquatic encounters even when the
  # player is on shore. If the town has no Water table, use a modest pool.
  WATER_ENABLED = true
  WATER_POPULATION_LIMIT = 2
  ROUTE_WATER_POPULATION_LIMIT = 3
  ROUTE_WATER_SPAWN_CHANCE_PERCENT = 55
  WATER_SPAWN_CHANCE_PERCENT = 55
  WATER_LEVEL_RANGE = (3..8)
  WATER_FALLBACK = [:MAGIKARP, :GOLDEEN, :PSYDUCK, :MARILL,
                    :WOOPER, :FINNEON, :TENTACOOL]
  WATER_COASTAL_FALLBACK = [:WINGULL, :TENTACOOL, :FRILLISH,
                            :FINNEON, :MAGIKARP]
  @town_bird_pools = {}
  @ticks = 0
  @last_map = nil
  @last_map_object_id = nil
  @logged_errors = {}

  def self.log(msg)
    echoln("[HoennNativeKIF] #{msg}") if defined?(echoln)
  end

  # Safari encounters belong to the game's Safari system.
  def self.safari_map?
    return false unless $game_map
    return true if defined?(pbInSafari?) && pbInSafari?
    meta = GameData::MapMetadata.try_get($game_map.map_id) if defined?(GameData::MapMetadata)
    return true if meta && meta.safari_map
    return true if defined?(is_hardcoded_safari_map) && is_hardcoded_safari_map($game_map.map_id)
    false
  end

  def self.ready?
    return false if defined?(HoennNativeKIFRadar) && HoennNativeKIFRadar.active?
    return false unless HoennNativeKIFSettings.enabled?
    return false unless $scene && $scene.is_a?(Scene_Map)
    return false unless $game_map && $game_player && $PokemonTemp && $PokemonEncounters && $PokemonGlobal
    return false if ROUTE_ONE_ONLY && $game_map.map_id != TEST_MAP_ID
    return false if MAP_ALLOWLIST && !MAP_ALLOWLIST.include?($game_map.map_id)
    return false if MAP_BLOCKLIST.include?($game_map.map_id)
    return false if indoor_map?
    return false unless spawn_habitat_available? || town_wildlife_map? || route_water_habitat_available?
    return false unless defined?(DynamicOverworldPokemonEvent)
    return false if $game_temp && ($game_temp.in_menu || $game_temp.message_window_showing)
    return false if $PokemonTemp.prevent_ow_encounters
    if PAUSE_DURING_EVENT
      return false if $game_map.respond_to?(:interpreter) &&
                      $game_map.interpreter && $game_map.interpreter.running?
      return false if $game_temp && $game_temp.respond_to?(:player_transferring) &&
                      $game_temp.player_transferring
    end
    return false unless $Trainer && $Trainer.able_pokemon_count > 0
    return false if defined?(isRepelActive) && isRepelActive()
    return true
  end

  # Indoor maps sometimes inherit encounter tables. No wildlife in the living room.
  def self.indoor_map?
    return false unless $game_map && defined?(GameData::MapMetadata)
    meta = GameData::MapMetadata.try_get($game_map.map_id)
    return false unless meta && !meta.outdoor_map
    return false if $PokemonEncounters && $PokemonEncounters.has_cave_encounters?
    true
  end

  def self.spawn_habitat_available?
    return false unless $PokemonEncounters
    return true if ($PokemonGlobal.surfing || $PokemonGlobal.boat) && $PokemonEncounters.has_water_encounters?
    return true if $PokemonEncounters.has_cave_encounters?
    return true if $PokemonEncounters.has_land_encounters?
    false
  end

  # Route water before Surf is unlocked
  def self.route_water_habitat_available?
    return false unless WATER_ENABLED && HoennNativeKIFSettings.water? && $game_map && $PokemonEncounters
    return false if town_wildlife_map?
    return false unless $PokemonEncounters.has_water_encounters?
    !!$PokemonEncounters.find_valid_encounter_type_for_time(:Water, pbGetTimeNow)
  end

  def self.population
    $PokemonTemp.overworld_pokemon_on_map ||= []
    $PokemonTemp.overworld_pokemon_on_map.select! { |id| $game_map.events[id].is_a?(DynamicOverworldPokemonEvent) }
    $PokemonTemp.overworld_pokemon_on_map.length
  end

  def self.tick
    return unless ready?
    # A loaded save may create a new Game_Map for the SAME map ID.
    # Treat it like a map entry so cached spawn state is not reused.
    map_identity = $game_map.object_id
    if @last_map != $game_map.map_id || @last_map_object_id != map_identity
      @last_map_object_id = map_identity
      @last_map = $game_map.map_id
      @ticks = 0
      # Clear only diagnostic state when moving to a different map instance;
      # never delete native events or modify persistent game save data.
      @water_empty_logged = {}
      log("Map #{$game_map.map_id} native overworld active")
    end
    @ticks += 1
    return unless @ticks >= HoennNativeKIFSettings.spawn_interval
    @ticks = 0
    # Water and land wildlife are independently capped in towns
    if town_wildlife_map?
      if WATER_ENABLED && HoennNativeKIFSettings.water? && water_population < HoennNativeKIFSettings.town_water_limit &&
         rand(100) < WATER_SPAWN_CHANCE_PERCENT
        spawn_town_water
      end
      if HoennNativeKIFSettings.towns? && town_population < TOWN_POPULATION_LIMIT &&
         rand(100) < TOWN_SPAWN_CHANCE_PERCENT
        spawn_town_wildlife
      end
      # Towns use their own wildlife pool. Don't run route spawning here too.
    else
      # Route water uses the proven town water tile search and native AI,
      # independently capped from grass/cave overworld encounters.
      if route_water_habitat_available? && water_population < HoennNativeKIFSettings.route_water_limit &&
         rand(100) < ROUTE_WATER_SPAWN_CHANCE_PERCENT
        spawn_town_water(false)
      end
      spawn_one if spawn_habitat_available? && population < HoennNativeKIFSettings.population_limit
    end
  rescue StandardError => e
    key = "#{e.class}:#{e.message}"
    unless @logged_errors[key]
      log("ERROR #{key}")
      log(e.backtrace.first(5).join(' | ')) if e.backtrace
      @logged_errors[key] = true
    end
  end

  def self.water_population
    $game_map.events.values.count do |ev|
      # On save load, a temporary event can survive while its custom
      # marker is absent. Count native Water events too, so the limit
      # applies before creating any new pond inhabitants.
      ev.is_a?(DynamicOverworldPokemonEvent) &&
        (ev.instance_variable_get(:@hoenn_native_town_water) ||
         ev.instance_variable_get(:@terrain) == :Water)
    end
  end

  def self.town_population
    # Count the Pokemon actually on the map, not just ones with our town tag.
    # Some events can lose their tag after a reload. Sneaky little things.
    $game_map.events.values.count do |ev|
      ev.is_a?(DynamicOverworldPokemonEvent) &&
        ev.instance_variable_get(:@terrain) != :Water &&
        !(ev.respond_to?(:erased?) && ev.erased?)
    end
  end

  # Figuring out how to keep them from spawning on
  # bridges and docks is killing me
  def self.open_water_tile?(x, y)
    return false unless $game_map.valid?(x, y)
    map_data = $game_map.data
    tags = $game_map.instance_variable_get(:@terrain_tags)
    return false unless map_data && tags
    water_layer = nil
    (0..2).each do |layer|
      tile_id = map_data[x, y, layer]
      next unless tile_id && tile_id > 0
      terrain = GameData::TerrainTag.try_get(tags[tile_id])
      return false if terrain && terrain.bridge
      if terrain && terrain.can_surf && !terrain.waterfall && !terrain.waterfall_crest
        water_layer = layer
      end
    end
    return false if water_layer.nil?
    # I actually hate this so much
    ((water_layer + 1)..2).each do |layer|
      tile_id = map_data[x, y, layer]
      next unless tile_id && tile_id > 0
      terrain = GameData::TerrainTag.try_get(tags[tile_id])
      return false unless terrain && terrain.can_surf
    end
    return false if $game_map.events.values.any? { |ev| ev && ev.x == x && ev.y == y }
    true
  rescue StandardError => e
    @water_check_error_logged ||= false
    unless @water_check_error_logged
      log("Water tile check failed: #{e.class}: #{e.message}")
      @water_check_error_logged = true
    end
    false
  end

  # Kill me
  WATER_BLOCKED_COORDINATES = {} unless const_defined?(:WATER_BLOCKED_COORDINATES)

  def self.water_position
    return nil unless $game_map && $game_player
    # I'm going insane why did I decide to do this?
    candidates = []
    x0 = [$game_player.x - SPAWN_RADIUS, 1].max
    x1 = [$game_player.x + SPAWN_RADIUS, $game_map.width - 2].min
    y0 = [$game_player.y - SPAWN_RADIUS, 1].max
    y1 = [$game_player.y + SPAWN_RADIUS, $game_map.height - 2].min
    (x0..x1).each do |x|
      (y0..y1).each do |y|
        next if (x - $game_player.x).abs + (y - $game_player.y).abs < 3
        next if (WATER_BLOCKED_COORDINATES[$game_map.map_id] || []).include?([x, y])
        next unless open_water_tile?(x, y)
        next if $game_map.events.values.any? { |ev| ev && ev.x == x && ev.y == y }
        candidates << [x, y]
      end
    end
    if candidates.empty?
      @water_empty_logged ||= {}
      unless @water_empty_logged[$game_map.map_id]
        log("No eligible open-water tile near player on map #{$game_map.map_id}; move nearer the pond or check its terrain tags")
        @water_empty_logged[$game_map.map_id] = true
      end
      return nil
    end
    candidates[rand(candidates.length)]
  end

  def self.spawn_town_water(allow_fallback = true)
    return unless HoennNativeKIFSettings.water?
    position = water_position
    return unless position
    # Water sucks
    wild = nil
    if $PokemonEncounters.has_water_encounters?
      kind = $PokemonEncounters.find_valid_encounter_type_for_time(:Water, pbGetTimeNow)
      wild = route_encounter(kind) if kind
    end
    unless wild
      return unless allow_fallback
      pool = town_coastal? ? WATER_COASTAL_FALLBACK : WATER_FALLBACK
      pool = pool.select { |sp| supported_town_species?(sp) }
      return if pool.empty?
      wild = [pool[rand(pool.length)], rand(WATER_LEVEL_RANGE)]
    end
    # We are almost done with the water
    diving_species = [:MAGIKARP, :GOLDEEN, :FINNEON, :TENTACOOL,
                      :FRILLISH, :WOOPER]
    roaming = diving_species.include?(wild[0]) ? :random_dive : :random
    event = spawn_overworld_pokemon(wild, position, :Water, roaming, nil)
    if event
      event.instance_variable_set(:@hoenn_native_town_water, true)
      log("#{allow_fallback ? 'Town' : 'Route'} water #{wild[0]} Lv#{wild[1]} on map #{$game_map.map_id}")
    end
  end

  def self.town_wildlife_map?
    return false unless TOWN_WILDLIFE_ENABLED && $game_map
    id = $game_map.map_id
    return false if TOWN_EXCLUDED_MAP_IDS.include?(id)

    # A town's name can carry into its buildings. The outdoor flag can't.
    return false unless defined?(GameData::MapMetadata)
    meta = GameData::MapMetadata.try_get(id)
    return false unless meta && meta.outdoor_map == true

    return true if TOWN_MAP_IDS.include?(id)
    name = ($game_map.name rescue '').to_s
    return false if name =~ /\b(interior|inside|house|mart|center|gym|gate|floor|room|building|basement|cave|tower|lab|ship)\b/i
    !!(name =~ /\b(town|city|village)\b/i || name =~ /\bCinnabar Island\b/i)
  end

  def self.town_coastal?
    name = ($game_map.name rescue '').to_s
    !!(name =~ /Cerulean|Vermilion|Fuchsia|Cinnabar|Pallet|Olivine|Cianwood|Cherrygrove/i)
  end

  def self.town_birds
    id = $game_map.map_id
    @town_bird_pools[id] ||= begin
      candidates = DAY_BIRDS.select { |sp| supported_town_species?(sp) }
      candidates += COAST_BIRDS.select { |sp| supported_town_species?(sp) } if town_coastal?
      candidates = candidates.sort_by { rand }
      nights = NIGHT_BIRDS.select { |sp| supported_town_species?(sp) }
      [candidates.first(2), nights.empty? ? nil : nights[rand(nights.length)]]
    end
  end

  def self.supported_town_species?(species)
    !!GameData::Species.try_get(species)
  rescue StandardError
    false
  end

  def self.town_night?
    hour = pbGetTimeNow.hour
    hour < 6 || hour >= 20
  end

  def self.town_species
    days, night = town_birds
    birds = town_night? ? [night].compact : days
    # Most town wildlife is birds, with occasional cats or Trubbish.
    if rand(100) < TOWN_RARE_PERCENT
      rare = TOWN_RARE.select { |sp| supported_town_species?(sp) }
      return rare[rand(rare.length)] unless rare.empty?
    end
    pool = birds * 5 + TOWN_OTHER.select { |sp| supported_town_species?(sp) }
    pool.empty? ? nil : pool[rand(pool.length)]
  end

  # A passable roof is still a roof. Only use ground connected to the player.
  def self.town_land_tile?(x, y, reachable = nil)
    return false unless $game_map.valid?(x, y)
    return false if $game_map.terrain_tag(x, y).can_surf
    directions = [2, 4, 6, 8]
    return false unless directions.all? { |dir| $game_map.OWPokemonPassable?(x, y, dir) }
    return false unless (reachable || town_reachable_tiles)[[x, y]]
    true
  end

  def self.town_reachable_tiles
    # Rebuild for each spawn search; map events can change between attempts.
    return [] unless $game_map && $game_player
    start = [$game_player.x, $game_player.y]
    return [] unless $game_map.valid?(*start)
    seen = {start => true}
    queue = [start]
    index = 0
    steps = [[2, 0, 1, 8], [4, -1, 0, 6], [6, 1, 0, 4], [8, 0, -1, 2]]
    while index < queue.length
      cx, cy = queue[index]
      index += 1
      steps.each do |dir, dx, dy, reverse|
        nx, ny = cx + dx, cy + dy
        pos = [nx, ny]
        next if seen[pos] || !$game_map.valid?(nx, ny)
        next if (nx - start[0]).abs > SPAWN_RADIUS + 5 || (ny - start[1]).abs > SPAWN_RADIUS + 5
        next unless $game_map.passable?(cx, cy, dir)
        next unless $game_map.passable?(nx, ny, reverse)
        seen[pos] = true
        queue << pos
      end
    end
    seen
  end

  def self.town_position
    return nil unless $game_map && $game_player
    reachable = town_reachable_tiles
    30.times do
      x = $game_player.x + rand(-SPAWN_RADIUS..SPAWN_RADIUS)
      y = $game_player.y + rand(-SPAWN_RADIUS..SPAWN_RADIUS)
      next if x < 1 || y < 1 || x >= $game_map.width-1 || y >= $game_map.height-1
      next if (x-$game_player.x).abs + (y-$game_player.y).abs < TOWN_MIN_DISTANCE
      next unless reachable[[x, y]]
      next unless town_land_tile?(x, y, reachable)
      next if $game_map.events.values.any? { |ev| ev && ev.x == x && ev.y == y }
      return [x,y]
    end
    nil
  end

  def self.spawn_town_wildlife
    return unless town_wildlife_map?
    return unless HoennNativeKIFSettings.towns?
    return if town_population >= [TOWN_POPULATION_LIMIT, HoennNativeKIFSettings.population_limit].min
    species = town_species
    return unless species
    position = town_position
    return unless position
    level = rand(TOWN_LEVEL_RANGE)
    # Use native Hoenn behavior types. Flying birds perch, then fly off
    # permanently on detection. Skitty runs away and despawns. Murkrow,
    # cats and scavengers are curious.
    birds = DAY_BIRDS + COAST_BIRDS + NIGHT_BIRDS
    if birds.include?(species) && species != :MURKROW
      roaming, noticed = :still, :flee_flying
    elsif species == :SKITTY
      roaming, noticed = :still, :flee
    elsif species == :MURKROW
      roaming, noticed = :random, :curious
    else
      roaming, noticed = :random, :curious
    end
    event = spawn_overworld_pokemon([species,level], position, :Land,
                                    roaming, noticed)
    event.instance_variable_set(:@hoenn_native_town_wildlife, true) if event
    log("Town wildlife #{species} Lv#{level} on map #{$game_map.map_id}") if event
  end

  # Native near-player helpers only sample a rectangle's perimeter. Search
  # its interior ourselves; retain native terrain and passability checks.
  def self.route_position(habitat)
    return nil unless $game_map && $game_player
    nearby = []
    farther = []
    x0 = [$game_player.x - SPAWN_RADIUS, 0].max
    x1 = [$game_player.x + SPAWN_RADIUS, $game_map.width - 1].min
    y0 = [$game_player.y - SPAWN_RADIUS, 0].max
    y1 = [$game_player.y + SPAWN_RADIUS, $game_map.height - 1].min
    (x0..x1).each do |x|
      (y0..y1).each do |y|
        distance = (x - $game_player.x).abs + (y - $game_player.y).abs
        next if distance < MIN_DISTANCE
        (distance <= NEAR_SPAWN_DISTANCE ? nearby : farther) << [x, y]
      end
    end
    groups = rand(100) < NEAR_SPAWN_CHANCE_PERCENT ? [nearby, farther] : [farther, nearby]
    occupied = {}
    $game_map.events.each_value { |ev| occupied[[ev.x, ev.y]] = true if ev }
    groups.each do |group|
      group.shuffle.each do |x, y|
        next unless $game_map.valid?(x, y)
        next if occupied[[x, y]]
        terrain = habitat
        tag = $game_map.terrain_tag(x, y)
        if habitat == :Land
          next unless tag && tag.land_wild_encounters
          terrain = {:Grass_alt1 => :Land1, :Grass_alt2 => :Land2,
                     :Grass_alt3 => :Land3, :TallGrass => :TallGrass}[tag.id] || :Land
        elsif habitat == :Cave
          next unless $game_map.playerPassable?(x, y, $game_player.direction)
        elsif habitat == :Water
          next unless tag && tag.can_surf
        end
        next unless can_spawn_pokemon_there(x, y, terrain)
        next unless encounter_type_at([x, y], terrain)
        return [[x, y], terrain]
      end
    end
    nil
  end

  def self.spawn_one
    habitat = nil
    if ($PokemonGlobal.surfing || $PokemonGlobal.boat) && $PokemonEncounters.has_water_encounters?
      habitat = :Water
    elsif $PokemonEncounters.has_cave_encounters?
      habitat = :Cave
    elsif $PokemonEncounters.has_land_encounters?
      habitat = :Land
    end
    return unless habitat
    position, terrain = route_position(habitat)
    return unless position && terrain
    return if (position[0] - $game_player.x).abs + (position[1] - $game_player.y).abs < MIN_DISTANCE
    return unless can_spawn_pokemon_there(position[0], position[1], terrain)
    # KIF has several land encounter tables. Choose by the SPAWN tile
    encounter_type = encounter_type_at(position, terrain)
    return unless encounter_type
    wild = route_encounter(encounter_type)
    return unless wild && wild[0] && wild[1]
    wild = maybe_natural_fusion(wild, encounter_type)
    event = spawn_overworld_pokemon(wild, position, terrain)
    if event
      distance = (position[0] - $game_player.x).abs + (position[1] - $game_player.y).abs
      log("Close spawn v0.12.37: #{terrain} at #{position[0]},#{position[1]} distance=#{distance}")
    end
    event
  end

  # Create a fusion using two rolls from the currently active encounters
  def self.maybe_natural_fusion(wild, encounter_type)
    return wild unless rand(100) < HoennNativeKIFSettings.fusion_percent
    return wild if isSpeciesFusion(wild[0])
    partner = $PokemonEncounters.choose_wild_pokemon(encounter_type)
    return wild unless partner && partner[0] && partner[1]
    return wild if isSpeciesFusion(partner[0])
    fused = fusionOf(wild[0], partner[0])
    return wild unless fused && isSpeciesFusion(fused)
    log("Natural fusion: #{wild[0]} + #{partner[0]} -> #{fused} Lv#{wild[1]}")
    [fused, wild[1]]
  rescue StandardError => e
    log("Fusion roll skipped: #{e.class}: #{e.message}")
    wild
  end

  def self.encounter_type_at(position, terrain)
    base = terrain
    if terrain == :Land
      tag = $game_map.terrain_tag(position[0], position[1])
      base = :Land1 if tag == :Grass_alt1
      base = :Land2 if tag == :Grass_alt2
      base = :Land3 if tag == :Grass_alt3
      base = :TallGrass if tag == :TallGrass
    end
    time = pbGetTimeNow
    selected = $PokemonEncounters.find_valid_encounter_type_for_time(base, time)
    # Do not silently fall back to ordinary Land when a special grass tile
    # lacks a table: that can produce species from the wrong habitat.
    selected ||= $PokemonEncounters.find_valid_encounter_type_for_time(:Land, time) if terrain == :Land && base == :Land
    selected
  end

  def self.route_encounter(encounter_type)
    # Use the SAME active encounter tables and chooser as normal KIF
    unless $PokemonEncounters.has_encounter_type?(encounter_type)
      log("No active encounter type #{encounter_type} on map #{$game_map.map_id}")
      return nil
    end
    wild = $PokemonEncounters.choose_wild_pokemon(encounter_type)
    if wild
      mode = if $game_switches[SWITCH_RANDOM_WILD] && $game_switches[SWITCH_RANDOM_WILD_AREA]
               'Area Randomizer'
             elsif $game_switches[SWITCH_MODERN_MODE]
               'Modern'
             else
               'Classic'
             end
      log("Map #{$game_map.map_id} mode=#{mode} version=#{$PokemonGlobal.encounter_version} type=#{encounter_type} -> #{wild[0]} Lv#{wild[1]}")
    end
    wild
  end

  # GhostNPC Wandering Trainers 1.0.1 owns these IDs. Its orphan sweeper
  # deletes any untracked event in them, and its spawner writes them directly.
  # Reserve them even before GhostNPC loads or creates its first trainer.
  def self.next_event_id
    id = ($game_map.events.keys.max || 0) + 1
    id = 7016 if id >= 7000 && id <= 7015
    id = 8016 if id >= 8000 && id <= 8015
    id
  end

  # I forgot to catch pokemon off guard LMAO
  def self.make_event(map_id, position, event_class)
    id = next_event_id
    raw = RPG::Event.new(position[0], position[1])
    raw.id = id
    raw.name = "HoennNativeWild"
    page = raw.pages[0]
    page.trigger = 0 # Player action button; direct start hook below
    page.through = false
    page.move_type = 0
    page.list = [RPG::EventCommand.new(355, 0, ['overworldPokemonCatchOffGuard']), RPG::EventCommand.new(0, 0, [])]
    event = event_class.new(map_id, raw, $game_map)
    event.moveto(position[0], position[1])
    event
  end
end
