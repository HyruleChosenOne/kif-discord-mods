# Hoenn PokéNav — independent KIF mod.
# The original Pokenav data and UI are already part of the game.
class PokemonPauseMenu_Scene
  alias_method :hoenn_nav_original_commands, :pbShowCommands
  def pbShowCommands(commands)
    return hoenn_nav_original_commands(commands) unless $Trainer
    label = "  <icon=menuIcons/POKENAV>  " + _INTL("Hoenn PokéNav")
    # Bag is the third standard pause-menu entry on KIF builds.
    bag = commands.index { |command| command.to_s.match?(/\bBag\b/i) }
    insert_at = bag ? bag + 1 : [3, commands.length].min
    entries = commands.dup
    entries.insert(insert_at, label)
    loop do
      selected = hoenn_nav_original_commands(entries)
      return selected < insert_at ? selected : selected - 1 unless selected == insert_at
      pbPlayDecisionSE
      pbFadeOutIn {
        pbHideMenu
        HoennPokeNavScreen.new(PokemonPokegear_Scene.new).pbStartScreen
      }
    end
  end
end

class HoennPokeNavScreen
  def initialize(scene)
    @scene = scene
  end

  def update_commands
    commands = []
    installed = $Trainer.pokenav ? $Trainer.pokenav.installed_apps : []
    installed ||= []
    # Keep installed apps, but never leak progression-gated ones.
    (installed.map { |app| app.to_sym } +
     [:CONTACTS, :POKECHALLENGE, :JUKEBOX, :WEATHER, :BERRYDEX,
      :BOXLINK, :FUSIONQUIZ, :MAP, :POKERADAR]).uniq.each do |app|
      next unless HoennSuiteUnlocks.available?(app)
      commands << [app.to_s, Pokenav.app_name(app)]
    end
    commands
  end
  def pbStartScreen
    $Trainer.pokenav = Pokenav.new unless $Trainer.pokenav
    commands = update_commands
    @scene.pbStartScene(commands)
    loop do
      cmd = @scene.pbScene
      @app_order = @scene.commands.map { |entry| entry[0] }
      commands = update_commands  # Keep the new grid order
      break if cmd.nil? || cmd < 0
      next unless commands[cmd]
      chosen = commands[cmd][0].to_sym
      # Missing game dependencies should not take down the whole PokéNav.
      requirements = {
        :CONTACTS => [:ContactsAppScene, :ContactsAppScreen],
        :POKERADAR => [:PokeRadarAppScene, :PokeRadarAppScreen],
        :FUSIONQUIZ => [:FusionQuizAppScene, :FusionQuizAppScreen],
        :POKECHALLENGE => [:PokemonChallenges_Scene, :PokemonChallenges_Screen],
        :BOXLINK => [:PokemonStorageScene, :PokemonStorageScreen],
        :JUKEBOX => [:PokemonJukebox_Scene, :PokemonJukeboxScreen]
      }
      missing = (requirements[chosen] || []).reject { |name| Object.const_defined?(name) }
      unless missing.empty?
        pbMessage(_INTL("This app isn't available in this build yet."))
        next
      end
      if chosen == :MAP
        pbShowMap(-1, false)
      elsif chosen == :JUKEBOX
          pbFadeOutIn {
            scene = PokemonJukebox_Scene.new
            screen = PokemonJukeboxScreen.new(scene)
            screen.pbStartScreen
          }
      elsif chosen == :QUESTS
        pbQuestlog()
      elsif chosen == :CONTACTS
        openContactsApp
        next
      elsif chosen == :WEATHER
        pbWeatherMap
      elsif chosen == :POKECHALLENGE
        openChallengeApp
      elsif chosen == :POKERADAR
        openPokeRadarApp
      elsif chosen == :REARRANGE
        @scene.rearrange_order
      elsif chosen == :DAYNIGHT
        toggleDarkMode
      elsif chosen == :BOXLINK
        openBoxLinkApp
      elsif chosen == :FUSIONQUIZ
        openGuessThatFusionApp
      elsif chosen == :BERRYDEX
        pbBerryDex
        # elsif cmdPhone>=0 && cmd==cmdPhone
        #   pbFadeOutIn {
        #     PokemonPhoneScene.new.start
        #   }
      end
    end
    @scene.pbEndScene
  end

  def openBoxLinkApp
    blacklisted_maps = []
    if blacklisted_maps.include?($game_map.map_id)
      Kernel.pbMessage(_INTL("There doesn't seem to be any network coverage here..."))
    else
      pbFadeOutIn {
        scene = PokemonStorageScene.new
        screen = PokemonStorageScreen.new(scene, $PokemonStorage)
        screen.pbStartScreen(0) # Boot PC in organize mode
      }
    end
  end

  def openContactsApp
    pbFadeOutIn {
      scene = ContactsAppScene.new
      screen = ContactsAppScreen.new(scene)
      screen.pbStartScreen(@scene,screen)
    }
  end

  def openPokeRadarApp
      pbFadeOutIn {
        scene = PokeRadarAppScene.new
        screen = PokeRadarAppScreen.new(scene)
        screen.pbStartScreen(@scene)
      }
  end

  def openGuessThatFusionApp
    pbFadeOutIn {
      scene = FusionQuizAppScene.new
      screen = FusionQuizAppScreen.new(scene)
      screen.pbStartScreen(@scene,screen)
    }
  end

  def toggleDarkMode
    pbSEPlay("GUI storage show party panel")
    $Trainer.pokenav.darkMode = false if $Trainer.pokenav.darkMode.nil?
    $Trainer.pokenav.darkMode = !$Trainer.pokenav.darkMode
    @scene.reloadBackground
    buttons = @scene.instance_variable_get(:@sprites)
    if buttons
      buttons.each do |key, sprite|
        sprite.refresh if key.to_s.start_with?("button") && sprite.respond_to?(:refresh)
      end
    end
  end
end

# Some KIF builds don't initialize weather until later in the map lifecycle.
# Radar's weather rarity preview should still work without it.
class PokeRadarAppScene
  alias_method :hoenn_nav_weather_rarity, :calculate_weather_encounter_rareness
  def calculate_weather_encounter_rareness(encounter, base_rareness)
    return 0 unless $game_weather && $game_weather.respond_to?(:current_weather)
    hoenn_nav_weather_rarity(encounter, base_rareness)
  end
end

# The PokéRadar asks for weather encounters even in saves without weather.
# Guard that query rather than changing the game's encounter tables.
class PokemonEncounters
  alias_method :hoenn_nav_original_weather_encounters, :list_weather_encounters
  def list_weather_encounters(enctype)
    return [] unless $game_weather && $game_weather.respond_to?(:current_weather)
    weather = $game_weather.current_weather
    return [] unless weather && $game_map && weather[$game_map.map_id]
    hoenn_nav_original_weather_encounters(enctype)
  end
end

# Some apps expect a cursor graphic that isn't shipped with KIF.
# Draw a simple selection frame when the original asset is absent.
class PokeNavAppScene
  alias_method :hoenn_nav_original_create_cursor, :createCursor

  def createCursor
    path = cursor_path
    return unless path
    if pbResolveBitmap(path)
      hoenn_nav_original_create_cursor
      return
    end
    @sprites["cursor"] = Sprite.new(@viewport)
    @sprites["cursor"].bitmap = Bitmap.new(64, 48)
    bmp = @sprites["cursor"].bitmap
    white = Color.new(248, 248, 248)
    red = Color.new(184, 48, 48)
    bmp.fill_rect(0, 0, 64, 3, white)
    bmp.fill_rect(0, 45, 64, 3, white)
    bmp.fill_rect(0, 0, 3, 48, red)
    bmp.fill_rect(61, 0, 3, 48, red)
    @sprites["cursor"].z = 100000
  end
end

# An empty contacts list has no selectable trainer.
class ContactsAppScene
  alias_method :hoenn_nav_contacts_original_start, :pbStartScene

  def pbStartScene(screen)
    # Don't initialize a selection if the player has no contacts yet.
    contacts = screen.list_contacts
    if contacts.nil? || contacts.empty? ||
       contacts.values.all? { |trainers| trainers.nil? || trainers.empty? }
      @hoenn_nav_no_contacts = true
      PokeNavAppScene.instance_method(:pbStartScene).bind(self).call([])
      Kernel.pbDisplayText(_INTL("No trainer contacts yet."),
                           Graphics.width / 2, Graphics.height / 2)
      return
    end
    hoenn_nav_contacts_original_start(screen)
    # The first available entry may be a location header, not a trainer.
    if @buttons && !@buttons.empty? && (@index.nil? || !@buttons[@index])
      @index = 0
      layoutButtons
    end
  end

  alias_method :hoenn_nav_contacts_original_input, :updateInput
  def updateInput
    if @hoenn_nav_no_contacts
      if Input.trigger?(Input::BACK) || Input.trigger?(Input::USE)
        pbPlayCloseMenuSE
        @exiting = true
      end
      return
    end
    hoenn_nav_contacts_original_input
  end
end

# Avoid selecting a missing Radar target when there are no encounters.
class PokeRadarAppScene
  alias_method :hoenn_nav_radar_original_selected_info, :showSelectedPokemonInfo
  def showSelectedPokemonInfo
    if !@buttons || @buttons.empty?
      showEmpty
      return
    end
    hoenn_nav_radar_original_selected_info
  end
end


# Make the Radar selection sit around the Pokémon, not above it.
class PokeRadarAppScene
  def cursor_x_offset
    return 0
  end
  def cursor_y_offset
    return 11
  end
  alias_method :hoenn_nav_radar_original_initialize, :initialize
  def initialize
    hoenn_nav_radar_original_initialize
    @text_color_base = Color.new(248, 248, 248)
    @text_color_shadow = Color.new(35, 38, 80)
  end
  def createCursor
    return if $PokemonTemp.pokeradar
    @sprites["cursor"] = Sprite.new(@viewport)
    bmp = Bitmap.new(64, 56)
    white = Color.new(255, 250, 250)
    red = Color.new(170, 35, 57)
    bmp.fill_rect(0, 0, 64, 3, white)
    bmp.fill_rect(0, 53, 64, 3, white)
    bmp.fill_rect(0, 0, 4, 56, red)
    bmp.fill_rect(60, 0, 4, 56, red)
    @sprites["cursor"].bitmap = bmp
    @sprites["cursor"].z = 100000
  end
end

# Use the actual Hoenn quiz button and cursor art.
class FusionQuizMenuButton
  def background_image
    return "Mods/hoenn_essentials/Graphics/Pictures/Pokegear/FusionQuiz/icon_button"
  end
  def get_width
    return 150
  end
  def get_height
    return 52
  end
  def text_padding
    return 4
  end
  def text_alignment
    return 1
  end
  def initialize(id, icon = nil, text = nil, viewport = nil)
    super
    @text_color = Color.new(255, 255, 255)
    @shadow_color = Color.new(27, 42, 95)
    refresh
  end
end

class FusionQuizAppScene
  def start_x
    return Graphics.width - 200
  end
  def start_y
    return 80
  end
  def y_gap
    return 64
  end
  def cursor_x_offset
    return 0
  end
  def cursor_y_offset
    return 0
  end
  def createCursor
    @sprites["cursor"] = IconSprite.new(0, 0, @viewport)
    @sprites["cursor"].setBitmap("Mods/hoenn_essentials/Graphics/Pictures/Pokegear/FusionQuiz/cursor")
    # The original cursor artwork is wider than the button art.
    @sprites["cursor"].zoom_x = 150.0 / 180.0
    @sprites["cursor"].z = 100000
  end
  alias_method :hoenn_nav_fusion_original_initialize, :initialize
  def initialize
    hoenn_nav_fusion_original_initialize
    @text_color_base = Color.new(255, 255, 255)
    @text_color_shadow = Color.new(32, 36, 86)
  end
end

# Give every app title the same readable treatment.
class PokeNavAppScene
  def showHeaderName
    Kernel.pbDisplayText(header_name, Graphics.width / 2, HEADER_HEIGHT,
                         nil, Color.new(255, 255, 255), Color.new(26, 38, 86))
  end
end


# Original Hoenn icon grid, with assets kept inside this mod.
module HoennNavVisual
  ROOT = "Mods/hoenn_essentials/Graphics/Pictures/Pokegear/"
end

class PokegearButton
  alias_method :hoenn_visual_original_initialize, :initialize
  def initialize(command, x, y, viewport = nil)
    SpriteWrapper.instance_method(:initialize).bind(self).call(viewport)
    @image = command[0]
    @name = command[1]
    @selected = false
    @cursor = AnimatedBitmap.new(HoennNavVisual::ROOT + "icon_button")
    @contents = BitmapWrapper.new(@cursor.width, @cursor.height / 2)
    @held = false
    @base_x, @base_y = x, y
    @rearranging = false
    @wobble_phase = rand * Math::PI * 2
    self.bitmap = @contents
    self.x, self.y = x, y
    pbSetSystemFont(self.bitmap)
    refresh
  end

  def refresh
    self.bitmap.clear
    half = @cursor.height / 2
    self.bitmap.blt(0, 0, @cursor.bitmap,
                    Rect.new(0, @selected ? half : 0, @cursor.width, half))
    icon_path = HoennNavVisual::ROOT + "icon_" + @image.to_s
    if pbResolveBitmap(icon_path)
      pbDrawImagePositions(self.bitmap, [[icon_path, 0, 0]])
    end
    self.opacity = @held ? 200 : 255
    self.x = @base_x
    self.y = @base_y - (@held ? 6 : 0)
  end
end

class PokemonPokegear_Scene
  [:GRID_COLUMNS, :GRID_X_START, :GRID_Y_START, :GRID_X_GAP, :GRID_Y_GAP].each do |name|
    remove_const(name) if const_defined?(name, false)
  end
  GRID_COLUMNS = 4
  GRID_X_START = 72
  GRID_Y_START = 120
  GRID_X_GAP = 96
  GRID_Y_GAP = 72

  def pbStartScene(commands)
    @commands = commands
    @index = 0
    @held_index
    @rearranging = false

    if $game_temp.pokenav_last_index
      @index = [$game_temp.pokenav_last_index, commands.length - 1].min
    end
    $game_temp.pokenav_last_index = @index
    @viewport = Viewport.new(0,0,Graphics.width,Graphics.height)
    @viewport.z = 99999
    @sprites = {}
    @sprites["background"] = IconSprite.new(0,0,@viewport)

    reloadBackground
    @sprites["UI"] = IconSprite.new(0,0,@viewport)
    @sprites["UI"].setBitmap("Mods/hoenn_essentials/Graphics/Pictures/Pokegear/ui_mainMenu")

    for i in 0...@commands.length
      col = i % GRID_COLUMNS
      row = i / GRID_COLUMNS
      x = GRID_X_START + (col * GRID_X_GAP)
      y = GRID_Y_START + (row * GRID_Y_GAP)
      @sprites["button#{i}"] = PokegearButton.new(@commands[i], x, y, @viewport)
    end
    @sprites["appName"] = BitmapSprite.new(Graphics.width, 48, @viewport)
    @sprites["appName"].y = Graphics.height - 48
    pbSetSystemFont(@sprites["appName"].bitmap)


    @sprites["pokenavIcon"] = AnimatedSprite.new("Mods/hoenn_essentials/Graphics/Pictures/Pokegear/pokenav_icon", 8,32,32,4,@viewport)
    @sprites["pokenavIcon"].zoom_x = 2
    @sprites["pokenavIcon"].zoom_y = 2
    @sprites["pokenavIcon"].z = 10
    @sprites["pokenavIcon"].x = 400
    @sprites["pokenavIcon"].y = 16
    @sprites["pokenavIcon"].start

    pbFadeInAndShow(@sprites) { pbUpdate }
  end


  def reloadBackground
    @sprites["background"].setBitmap(
      HoennNavVisual::ROOT + (isDarkMode ? "bg_dark" : "bg"))
  end
end

# Preview apps aren't always registered as installed apps.
class PokemonPokegear_Scene
  attr_reader :commands
  def swap_apps
    if @held_index
      pbSEPlay("GUI storage put down")
      @commands[@index], @commands[@held_index] =
        @commands[@held_index], @commands[@index]
      refresh_buttons
      @held_index = nil
    else
      pbSEPlay("GUI storage pick up")
      @held_index = @index
    end
  end
  def refresh_buttons
    @commands.each_with_index do |cmd, i|
      button = @sprites["button#{i}"]
      button.set_command(cmd) if button
    end
  end
end
class HoennPokeNavScreen
  alias_method :hoenn_nav_original_update_commands, :update_commands
  def update_commands
    commands = hoenn_nav_original_update_commands
    if @app_order
      commands.sort_by! do |entry|
        idx = @app_order.index(entry[0])
        idx || @app_order.length
      end
    end
    commands
  end
end

# Use the original Hoenn layout and graphics, without synthetic cursor/battery art.
module HoennNavRadarMode
  def self.overworld?
    defined?(HoennNativeKIFSettings) && HoennNativeKIFSettings.enabled? &&
      defined?(HoennNativeKIFRadar) && defined?(OverworldPokemonEvent)
  end
end

class PokeRadarAppScene
  def columns; 6; end
  def start_x; 40; end
  def x_gap; 75; end
  def start_y; 80; end
  def cursor_x_offset; 0; end
  def cursor_y_offset; 0; end
  def cursor_path; "Mods/hoenn_essentials/Graphics/Pictures/Pokeradar/icon_button"; end
  def header_path; "Mods/hoenn_essentials/Graphics/Pictures/Pokeradar/bg_header"; end

  def createCursor
    return if $PokemonTemp.pokeradar
    @sprites["cursor"] = IconSprite.new(0, 0, @viewport)
    @sprites["cursor"].setBitmap(cursor_path)
    @sprites["cursor"].z = 100000
  end

  def showBattery
    return unless $PokemonGlobal
    HoennNavBattery.restore
    capacity = Settings::POKERADAR_BATTERY_STEPS
    capacity = 1000 if capacity.to_i <= 0
    $PokemonGlobal.pokeradarBattery = capacity if $PokemonGlobal.pokeradarBattery.nil?
    charge = [[capacity - $PokemonGlobal.pokeradarBattery, 0].max, capacity].min
    # The original counter sits to the right of the built-in battery image.
    Kernel.pbDisplayText(_INTL("{1}/{2}", charge, capacity), 446,
                         HEADER_HEIGHT, nil, @text_color_base, @text_color_shadow)
  end

  def showHeaderInfo
    showBattery
    showHeaderName
    showAreaName
    showWeatherIcon
  end
end

if Settings::POKERADAR_BATTERY_STEPS <= 0
  Settings.send(:remove_const, :POKERADAR_BATTERY_STEPS)
  Settings.const_set(:POKERADAR_BATTERY_STEPS, 1000)
end

class PokeRadarAppScene
  alias_method :hoenn_nav_radar_visual_initialize, :initialize
  def initialize
    hoenn_nav_radar_visual_initialize
    @text_color_base = Color.new(164, 167, 174)
    @text_color_shadow = Color.new(57, 61, 73)
  end
end



# Pick the radar behavior from the actual overworld-spawning setting.
module HoennNavTargetRadar
  def self.overworld?
    defined?(HoennNativeKIFSettings) &&
      HoennNativeKIFSettings.respond_to?(:enabled?) &&
      HoennNativeKIFSettings.enabled? &&
      defined?(HoennNativeKIFRadar) && defined?(OverworldPokemonEvent)
  end

  def self.target
    return nil unless $PokemonTemp && !overworld?
    $PokemonTemp.instance_variable_get(:@hoenn_nav_radar_target)
  end

  def self.clear_target
    $PokemonTemp.instance_variable_set(:@hoenn_nav_radar_target, nil) if $PokemonTemp
  end

  def self.hoenn_session?
    return false unless $PokemonTemp && $PokemonTemp.pokeradar
    $PokemonTemp.instance_variable_get(:@hoenn_nav_hoenn_session) == $PokemonTemp.pokeradar.object_id
  end

  def self.start(species, level)
    return false unless $PokemonTemp && $game_map && $game_player
    return false unless $scene.is_a?(Scene_Map)
    clear_target
    if overworld?
      # Hoenn's PokéNav uses one selected tile and one overworld Pokémon.
      tiles = HoennNavTargetRadar.connected_grass_tiles
      position = HoennNavTargetRadar.scan_tiles.sample
      return false unless position
      set_pokeradar_data(species, level, position)
      $PokemonTemp.instance_variable_set(:@hoenn_nav_hoenn_session, $PokemonTemp.pokeradar.object_id)
      before = $game_map.events.values.select { |ev| ev.is_a?(OverworldPokemonEvent) }.map(&:object_id)
      spawned_event = spawn_pokeradar_pokemon(species, level)
      spawned = spawned_event && $game_map.events.values.any? do |ev|
        ev.is_a?(OverworldPokemonEvent) && !before.include?(ev.object_id) &&
          ev.respond_to?(:pokemon) && ev.pokemon && ev.pokemon.species == species
      end
      unless spawned
        pbPokeRadarCancel if $PokemonTemp.pokeradar
        return false
      end
      $game_map.events.values.each do |ev|
        next unless ev.is_a?(OverworldPokemonEvent) && !before.include?(ev.object_id)
        next unless ev.respond_to?(:pokemon) && ev.pokemon && ev.pokemon.species == species
        ev.instance_variable_set(:@hoenn_nav_grass_region, tiles.each_with_object({}) { |xy, h| h[xy] = true })
        ev.instance_variable_set(:@hoenn_nav_grass_map, $game_map.map_id)
      end
      return true
    end
    # Without overworld spawning, use the classic shaking-grass radar.
    $PokemonTemp.instance_variable_set(:@hoenn_nav_hoenn_session, nil)
    $PokemonTemp.pokeradar = [species, level, 0, []]
    $PokemonTemp.instance_variable_set(:@hoenn_nav_radar_target, species)
    pbPokeRadarHighlightGrass
    unless $PokemonTemp.pokeradar
      clear_target
      return false
    end
    if $PokemonGlobal && $PokemonGlobal.respond_to?(:repel) &&
       $PokemonGlobal.repel.to_i <= 0
      $PokemonGlobal.repel = 10
      $PokemonGlobal.tempRepel = true
    end
    true
  end
end

# Keep the classic encounter target on the chosen Pokémon.
module HoennNavRadarEncounterPatch
  def pbPokeRadarGetEncounter(rarity = 0)
    selected = HoennNavTargetRadar.target
    if selected && $PokemonTemp && $PokemonTemp.pokeradar
      return [selected, $PokemonTemp.pokeradar[1]]
    end
    super
  end
end
Object.prepend(HoennNavRadarEncounterPatch) unless Object.ancestors.include?(HoennNavRadarEncounterPatch)

# RC3's Bag Radar bridge expects a list of grass patches. Hoenn's PokéNav
# stores one tile instead; don't let the bridge erase Hoenn's encounter.
if defined?(HoennNativeKIFRadar)
  module HoennNavRadarBridgeGuard
    def tick
      return unless HoennNavTargetRadar.overworld?
      return if HoennNavTargetRadar.hoenn_session?
      super
    end
  end
  HoennNativeKIFRadar.singleton_class.prepend(HoennNavRadarBridgeGuard) unless
    HoennNativeKIFRadar.singleton_class.ancestors.include?(HoennNavRadarBridgeGuard)
end

class PokeRadarAppScene
  def click_seen(species)
    options = [_INTL("Scan"), _INTL("Cancel")]
    Kernel.pbClearText
    showHeaderInfo
    chosen = pbMessage(_INTL("What would you like to do?"), options, options.length)
    unless chosen == 0
      showSelectedPokemonInfo
      return
    end
    HoennNavBattery.restore
    needed = get_energy_for_scan(species)
    capacity = Settings::POKERADAR_BATTERY_STEPS
    $PokemonGlobal.pokeradarBattery = capacity if $PokemonGlobal.pokeradarBattery.nil?
    if capacity - $PokemonGlobal.pokeradarBattery < needed
      pbMessage(_INTL("The battery is not charged enough for this scan!"))
      showSelectedPokemonInfo
      return
    end
    encounter = get_encounter(species)
    unless encounter && encounter[2] && encounter[3]
      pbMessage(_INTL("No encounter data is available for this Pokémon."))
      showSelectedPokemonInfo
      return
    end
    level = rand(encounter[2]..encounter[3])
    @exiting = true
    pbEndScene
    @pokenav_main_menu_scene.exiting = true
    @pokenav_main_menu_scene.pbEndScene
    pbWait(16)
    pbMessage(_INTL("Scanning for {1}...\\wtnp[5]", GameData::Species.get(species).name))
    if HoennNavTargetRadar.start(species, level)
      $PokemonGlobal.pokeradarBattery += needed
      HoennNavBattery.store
    else
      pbMessage(_INTL("The PokéRadar scan failed. Try again in suitable grass."))
    end
  end
end

module HoennNavRadarCancelPatch
  def pbPokeRadarCancel(*args)
    HoennNavTargetRadar.clear_target
    $PokemonTemp.instance_variable_set(:@hoenn_nav_hoenn_session, nil) if $PokemonTemp
    super
  end
end
Object.prepend(HoennNavRadarCancelPatch) unless Object.ancestors.include?(HoennNavRadarCancelPatch)

# Only scan the connected patch of grass the player is standing in.
module HoennNavTargetRadar
  def self.connected_grass_tiles
    return [] unless $game_map && $game_player
    x, y = $game_player.x, $game_player.y
    return [] unless radar_grass?(x, y)
    visited = { [x, y] => true }
    queue = [[x, y]]
    index = 0
    while index < queue.length
      cx, cy = queue[index]
      index += 1
      [[cx + 1, cy], [cx - 1, cy], [cx, cy + 1], [cx, cy - 1]].each do |nx, ny|
        next if visited[[nx, ny]]
        next unless radar_grass?(nx, ny)
        visited[[nx, ny]] = true
        queue << [nx, ny]
      end
    end
    queue
  end

  def self.radar_grass?(x, y)
    return false unless x >= 0 && y >= 0 && x < $game_map.width && y < $game_map.height
    tag = $game_map.terrain_tag(x, y)
    tag && tag.land_wild_encounters && tag.shows_grass_rustle
  end
end

# Hoenn's radar methods are global, not PokeRadarAppScene methods.
module HoennNavRadarGlobalPatch
  def spawn_pokeradar_pokemon(species, level)
    return super unless HoennNavTargetRadar.overworld? && HoennNavTargetRadar.hoenn_session?
    session = $PokemonTemp.pokeradar
    patch = session[3]
    return false unless patch.is_a?(Array) && patch.length >= 4
    x, y = patch[0], patch[1]
    allowed = HoennNavTargetRadar.connected_grass_tiles
    return false unless allowed.include?([x, y])
    return false unless HoennNavTargetRadar.valid_spawn_tile?(x, y)

    pbWait(20)
    playAnimation(Settings::POKERADAR_LIGHT_ANIMATION_RED_ID, $game_player.x, $game_player.y)
    pbWait(10)
    event = spawn_overworld_pokemon([species, level], [x, y], :Land)
    if !event || event.x != x || event.y != y
      event.despawn if event && event.respond_to?(:despawn)
      return false
    end
    event.instance_variable_set(:@hoenn_nav_grass_region, allowed.each_with_object({}) { |xy, h| h[xy] = true })
    event.instance_variable_set(:@hoenn_nav_grass_map, $game_map.map_id)
    event.instance_variable_set(:@hoenn_nav_radar_target_event, true)
    event.instance_variable_set(:@hoenn_nav_radar_species, species)
    event.instance_variable_set(:@hoenn_nav_radar_level, level)
    event.instance_variable_set(:@hoenn_nav_radar_count, session[2].to_i)
    event.instance_variable_set(:@hoenn_nav_radar_map, $game_map.map_id)
    if patch[3] == 2
      pbSEPlay("shiny", 60)
      playAnimation(Settings::SPARKLE_SHORT_ANIMATION_ID, event.x, event.y)
      event.make_shiny
    end
    event.behavior_roaming = :look_around_player
    event.behavior_noticed = event.pokemon.shiny? ? :curious : :flee
    event.update_movement_type
    event.turn_away_from_player
    playAnimation(Settings::POKERADAR_LIGHT_ANIMATION_RED_ID, event.x, event.y)
    update_pokeradar_overworld_ui
    event
  end

  def continue_pokeradar_app_chain(*args)
    return super unless HoennNavTargetRadar.overworld? && HoennNavTargetRadar.hoenn_session?
    return unless $PokemonTemp && $PokemonTemp.pokeradar
    pbWait(12)
    session = $PokemonTemp.pokeradar
    species, level = session[0], session[1]
    position = HoennNavTargetRadar.scan_tiles.sample
    unless position
      pbPokeRadarCancel
      pbMessage(_INTL("The PokéRadar scan failed... Try again somewhere else"))
      return
    end
    set_pokeradar_data(species, level, position)
    # set_pokeradar_data preserves the same session array in Hoenn.
    $PokemonTemp.instance_variable_set(:@hoenn_nav_hoenn_session, $PokemonTemp.pokeradar.object_id)
    unless spawn_pokeradar_pokemon(species, level)
      pbPokeRadarCancel
      pbMessage(_INTL("The PokéRadar scan failed... Try again somewhere else"))
    end
  end
end
Object.prepend(HoennNavRadarGlobalPatch) unless Object.ancestors.include?(HoennNavRadarGlobalPatch)

module HoennNavTargetRadar
  def self.valid_spawn_tile?(x, y)
    return false unless radar_grass?(x, y)
    return false unless can_spawn_pokemon_there(x, y, :Land)
    return false if x == $game_player.x && y == $game_player.y
    !$game_map.events.values.any? { |ev| ev && ev.x == x && ev.y == y && !ev.instance_variable_get(:@erased) }
  end

  def self.scan_tiles
    connected_grass_tiles.select do |x, y|
      (x - $game_player.x).abs <= 3 && (y - $game_player.y).abs <= 3 && valid_spawn_tile?(x, y)
    end
  end
end


# Keep encounter identity on the event: native cleanup may cancel the session.
module HoennNavChainLifecycle
  @pending = nil
  @battle = nil
  @handled = false

  def self.begin_battle(event)
    return unless event && event.instance_variable_get(:@hoenn_nav_radar_target_event)
    return unless HoennNavTargetRadar.overworld?
    return if @battle && @battle[:event_id] == event.object_id
    species = event.instance_variable_get(:@hoenn_nav_radar_species) || event.pokemon.species
    level = event.instance_variable_get(:@hoenn_nav_radar_level) || event.pokemon.level
    count = event.instance_variable_get(:@hoenn_nav_radar_count).to_i
    map_id = event.instance_variable_get(:@hoenn_nav_radar_map) || $game_map.map_id
    @battle = { :event_id => event.object_id, :species => species,
                :level => level, :count => count, :map_id => map_id }
    @handled = false
  end

  def self.finish_battle(species, level, decision)
    return unless @battle && !@handled
    return unless species == @battle[:species]
    @handled = true
    if (decision == 1 || decision == 4) && @battle[:map_id] == $game_map.map_id
      @pending = [@battle[:species], @battle[:level], @battle[:count] + 1, @battle[:map_id]]
    else
      @pending = nil
    end
    @battle = nil
  end

  def self.tick
    return unless @pending && $scene.is_a?(Scene_Map) && $PokemonTemp
    return if $PokemonTemp.overworld_wild_battle_triggered
    participants = $PokemonTemp.overworld_wild_battle_participants
    return if participants && !participants.empty?
    species, level, count, map_id = @pending
    return unless $game_map.map_id == map_id && HoennNavTargetRadar.overworld?
    position = HoennNavTargetRadar.scan_tiles.sample
    return unless position # Keep the chain queued while this patch has no free tile.
    @pending = nil
    set_pokeradar_data(species, level, position)
    $PokemonTemp.pokeradar[2] = count
    $PokemonTemp.instance_variable_set(:@hoenn_nav_hoenn_session, $PokemonTemp.pokeradar.object_id)
    unless spawn_pokeradar_pokemon(species, level)
      @pending = [species, level, count, map_id]
    end
  end
end

module HoennNavTargetBattlePatch
  def overworldPokemonBattle(*args)
    HoennNavChainLifecycle.begin_battle(self)
    super
  end
end
OverworldPokemonEvent.prepend(HoennNavTargetBattlePatch) unless
  OverworldPokemonEvent.ancestors.include?(HoennNavTargetBattlePatch)

Events.onWildBattleEnd += proc { |_sender, e|
  HoennNavChainLifecycle.finish_battle(e[0], e[1], e[2])
}
Events.onMapUpdate += proc { |_sender, _args| HoennNavChainLifecycle.tick }

# Mirror the counter in the trainer's saved PokéNav object.
module HoennNavBattery
  def self.restore
    return unless $Trainer && $Trainer.pokenav && $PokemonGlobal
    capacity = Settings::POKERADAR_BATTERY_STEPS
    saved = $Trainer.pokenav.instance_variable_get(:@hoenn_nav_battery_used)
    if saved.is_a?(Numeric)
      $PokemonGlobal.pokeradarBattery = [[saved.to_i, 0].max, capacity].min
    else
      store
    end
  end

  def self.store
    return unless $Trainer && $Trainer.pokenav && $PokemonGlobal
    value = $PokemonGlobal.pokeradarBattery
    return unless value.is_a?(Numeric)
    $Trainer.pokenav.instance_variable_set(:@hoenn_nav_battery_used, value.to_i)
  end
end

# Walking charges the battery; update the saved mirror after the game does.
Events.onStepTaken += proc { |_sender, _args|
  HoennNavBattery.store
}



# Show the full BerryDex, including undiscovered berries.
class PokemonBerrydex_Scene
  def pbRefreshDexList(index = 0)
    @dexlist = pbGetDexList.sort_by { |entry| entry[2] }
    window = @sprites["berrydex"]
    window.commands = @dexlist
    window.index = [[index.to_i, 0].max, [@dexlist.length - 1, 0].max].min
    window.refresh
    @sprites["background"].setBitmap("Graphics/Pictures/Berrydex/bg_list")
    pbRefresh
  end
end


# Keep Hoenn's real Contacts scenes. Only the data source is different in KIF.
module HoennContactsData
  class Trainer
    attr_reader :entry
    def initialize(entry)
      @entry = entry
    end
    def id; [@entry[:map_id].to_i, @entry[:event_id].to_i]; end
    def trainerType; @entry[:trainer_type].to_sym; end
    def trainerName; @entry[:trainer_name].to_s; end
    def currentTeam; @entry[:team] || []; end
    def location_map_id; @entry[:map_id].to_i; end
    def location
      pbGetMessage(MessageTypes::MapNames, location_map_id) || "Unknown"
    rescue StandardError
      "Unknown"
    end
    def favorite; !!@entry[:favorite]; end
    def can_trade?; @entry[:affinity].to_i >= 50; end
    def friendship_level; [[@entry[:affinity].to_i / 20, 0].max, 5].min; end
    def favorite_type
      team = currentTeam
      types = team.flat_map { |p| p.respond_to?(:types) ? p.types : [] }
      types.group_by { |t| t }.max_by { |_, values| values.length }&.first
    end
    def overworld_sprite
      # A remote trainer need not have a live Game_Event. Read their home
      # map's RPG::Event pages without setting up or changing the player's map.
      if $game_map && $game_map.map_id == location_map_id
        ev = $game_map.events[id[1]]
        name = ev.character_name if ev && ev.respond_to?(:character_name)
        return name if name && !name.empty?
      end
      map = load_data(sprintf("Data/Map%03d.rxdata", location_map_id))
      ev = map.events[id[1]] if map && map.respond_to?(:events)
      if ev && ev.respond_to?(:pages)
        ev.pages.reverse_each do |page|
          name = page.graphic.character_name if page && page.graphic
          return name if name && !name.empty?
        end
      end
      "000"
    rescue StandardError
      "000"
    end
  end
  def self.entries
    return [] unless defined?(HoennTrainerRematches)
    HoennTrainerRematches.all_contacts.select { |e| e.is_a?(Hash) }.map { |e| Trainer.new(e) }
  end
  def self.find(id)
    entries.find { |trainer| trainer.id == id }
  end
end

module HoennContactsListBridge
  def can_be_listed(trainer)
    # Registration is the authority for Hoenn contacts, wherever the player is.
    # Leave the native rules available for any non-Hoenn contact objects.
    return true if trainer.is_a?(HoennContactsData::Trainer)
    super
  end

  def list_contacts
    grouped = {}
    HoennContactsData.entries.each do |trainer|
      name = trainer.location
      grouped[name] ||= []
      grouped[name] << trainer
    end
    grouped.each_value { |items| items.sort_by! { |trainer| trainer.trainerName } }
    grouped
  end

  def view_trainer_page(trainer_id, trainers_list)
    trainer = HoennContactsData.find(trainer_id)
    return unless trainer
    pbFadeOutIn {
      scene = ContactsAppInfoPageScene.new
      screen = ContactsAppInfoPageScreen.new
      screen.pbStartScreen(scene, trainer, trainers_list)
    }
  end

  def view_trainer_team(trainer_id)
    trainer = HoennContactsData.find(trainer_id)
    return unless trainer
    pbFadeOutIn {
      scene = PokemonSummary_Scene.new
      screen = PokemonSummaryScreen.new(scene)
      screen.pbStartScreen(trainer.currentTeam.map { |p| p.clone }, 0, false)
    }
  end
end

module HoennContactsProfileScreenBridge
  def change_trainer(delta)
    @index = (@index + delta) % @trainers_list.length
    @scene.trainer = HoennContactsData.find(@trainers_list[@index])
    updateStatus
  end
  def updateStatus
    return unless $Trainer && $Trainer.pokenav
    $Trainer.pokenav.viewed_trainers ||= []
    id = @trainers_list[@index]
    $Trainer.pokenav.viewed_trainers << id unless $Trainer.pokenav.viewed_trainers.include?(id)
  end
  def view_trainer_team(id)
    trainer = HoennContactsData.find(id)
    return unless trainer
    pbFadeOutIn {
      scene = PokemonSummary_Scene.new
      screen = PokemonSummaryScreen.new(scene)
      screen.pbStartScreen(trainer.currentTeam.map { |p| p.clone }, 0, false)
    }
  end
end

module HoennContactsProfileSceneBridge
  def showTrainerSprite
    trainerFile = GameData::TrainerType.front_sprite_filename(@trainer.trainerType)
    @sprites["trainer"] = IconSprite.new(0, 0, @viewport)
    @sprites["trainer"].setBitmap(trainerFile)
    sprite = @sprites["trainer"]
    if sprite.bitmap.width > sprite.bitmap.height * 2
      sprite.src_rect.x = 0
      sprite.src_rect.width = sprite.bitmap.width / 5
    end
    sprite.ox = sprite.src_rect.width / 2
    sprite.oy = sprite.bitmap.height
    sprite.z = 50
    sprite.x = self.class::SPRITE_POSITION_X
    sprite.y = self.class::SPRITE_POSITION_Y
  end

  def showTrainerInfo
    Kernel.pbClearText
    showHeaderName
    entry = @trainer.entry
    type = GameData::TrainerType.get(@trainer.trainerType).name
    title = _INTL("{1} {2}", type, @trainer.trainerName)
    team = @trainer.currentTeam
    average = team.empty? ? _INTL("N/A") : (team.inject(0) { |sum, p| sum + p.level } / team.length).to_s
    favorite = GameData::Type.try_get(@trainer.favorite_type)
    favorite_name = favorite ? favorite.name : _INTL("Unknown")
    Kernel.pbDisplayText(title, self.class::TITLE_TEXT_X, self.class::TITLE_TEXT_Y,
                         999999, @text_color_base, @text_color_shadow)
    y = self.class::INFO_TEXT_START_Y
    [[_INTL("Location:"), @trainer.location],
     [_INTL("Average team level:"), average],
     [_INTL("Favorite type:"), favorite_name]].each do |header, value|
      displayText(header, self.class::INFO_HEADER_X, y)
      y += self.class::INFO_HEADER_GAP
      displayValue(value, self.class::INFO_TEXT_X, y)
      y += self.class::INFO_TEXT_GAP
    end
    quote = HoennContactsProfileQuotes.for(entry)
    quote ||= _INTL("We've had {1} rematches together.", entry[:rematches].to_i)
    # The original info-page renderer owns the text wrapping and pagination.
    record = Struct.new(:infoText).new(quote)
    displayInfoText(y + 10, record)
  end
end

if defined?(ContactsAppScreen)
  ContactsAppScreen.prepend(HoennContactsListBridge) unless ContactsAppScreen.ancestors.include?(HoennContactsListBridge)
end
if defined?(ContactsAppInfoPageScreen)
  ContactsAppInfoPageScreen.prepend(HoennContactsProfileScreenBridge) unless ContactsAppInfoPageScreen.ancestors.include?(HoennContactsProfileScreenBridge)
end
if defined?(ContactsAppInfoPageScene)
  ContactsAppInfoPageScene.prepend(HoennContactsProfileSceneBridge) unless ContactsAppInfoPageScene.ancestors.include?(HoennContactsProfileSceneBridge)
end

# Draw one standing frame, not a slice of the whole walking sheet.
module HoennContactsStandingSprites
  def create_image_sprite
    return unless @image_path && self.viewport
    @image_sprite.dispose if @image_sprite && !@image_sprite.disposed?
    @image_sprite = IconSprite.new(0, 0, self.viewport)
    if @id == BATTLED_TRAINER_RIVAL_KEY
      rival = AnimatedBitmap.new(getBaseOverworldSpriteFilename())
      rival.bitmap = generateNPCClothedBitmapStatic($Trainer.rival_appearance)
      @image_sprite.setBitmapDirectly(rival)
    else
      @image_sprite.setBitmap("Graphics/Characters/#{@image_path}")
    end
    bitmap = @image_sprite.bitmap
    return unless bitmap
    frame_w = [bitmap.width / 4, 1].max
    frame_h = [bitmap.height / 4, 1].max
    # Most KIF character sheets are 4 columns by 4 rows.
    # Select the center-facing frame without crossing frame boundaries.
    rect = @image_sprite.src_rect
    rect.x = frame_w
    rect.y = 0
    rect.width = frame_w
    rect.height = frame_h
    max_w = 46.0
    max_h = 46.0
    scale = [max_w / frame_w, max_h / frame_h, 1.0].min
    @image_sprite.zoom_x = scale
    @image_sprite.zoom_y = scale
    @image_sprite.z = self.z + 1
    place_standing_sprite
  rescue StandardError
    @image_sprite.visible = false if @image_sprite
  end

  def place_standing_sprite
    return unless @image_sprite && @image_sprite.bitmap
    return unless self.x.is_a?(Numeric) && self.y.is_a?(Numeric)
    return unless get_height.is_a?(Numeric)
    width = @image_sprite.src_rect.width * @image_sprite.zoom_x
    height = @image_sprite.src_rect.height * @image_sprite.zoom_y
    offset = self.class.const_defined?(:IMAGE_X_OFFSET) ? self.class::IMAGE_X_OFFSET : 0
    @image_sprite.x = self.x + offset + (46 - width) / 2
    @image_sprite.y = self.y + (get_height - height) / 2
  end

  def x=(value)
    super
    place_standing_sprite if value.is_a?(Numeric)
  end

  def y=(value)
    super
    place_standing_sprite if value.is_a?(Numeric)
  end
end

if defined?(ContactsAppTrainerButton)
  ContactsAppTrainerButton.prepend(HoennContactsStandingSprites) unless ContactsAppTrainerButton.ancestors.include?(HoennContactsStandingSprites)
end

# The PokéNav can show the last team update without consuming its conversation.
module HoennContactsProfileQuotes
  EVENT_FIELDS = {
    :CATCH => 'caught', :EVOLVE => 'evolved', :FUSE => 'fused',
    :UNFUSE => 'unfused', :REVERSE => 'reversed', :GIFT => 'gift'
  }

  def self.for(entry)
    return nil unless defined?(HoennTrainerRematches)
    data, = HoennTrainerRematches.hoenn_dialogue_for(entry)
    return nil unless data
    field = EVENT_FIELDS[entry[:last_team_event]]
    if field && entry[:team_event_serial].to_i > 0
      template = data[field]
      if template && !template.empty?
        names = entry[:team_event_names].is_a?(Hash) ? entry[:team_event_names] : {}
        # Do not show raw <POKEMON> tokens if an older save lacks names.
        line = template.gsub(/<([A-Z_]*POKEMON)>/) { |token| names[$1] || token }
        return clean(line) unless line.match?(/<[A-Z_]*POKEMON>/)
      end
    end
    clean(data['infoText'] || data['info'])
  rescue StandardError
    nil
  end

  def self.clean(line)
    return nil unless line && !line.empty?
    line.to_s.gsub(/<br\s*\/?\s*>/i, ' ').gsub('<PLAYER_NAME>',
      ($Trainer ? $Trainer.name.to_s : 'Trainer')).gsub(/\s+/, ' ').strip
  end
end
