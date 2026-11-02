# Hoenn-style contacts, kept separate from KIF's original scripts.
class PokemonGlobalMetadata
  attr_accessor :hoenn_trainer_contacts
  attr_accessor :hoenn_rematch_partner_key
end

module HoennTrainerRematches
  VERSION = '1.9.3'
  MAX_AFFINITY = 100
  REMATCH_COOLDOWN = 0
  TRADE_AFFINITY = 50
  TRADE_AFFINITY_COST = 20
  PARTNER_AFFINITY = 100
  GIFT_AFFINITY = 5
  GIFT_BASE_CHANCE = 30
  CHAT_COOLDOWN = 10 * 60

  def self.contacts
    return {} unless $PokemonGlobal
    $PokemonGlobal.hoenn_trainer_contacts ||= {}
  end

  def self.contact(map_id, event_id)
    return nil unless map_id && event_id
    contacts[[map_id.to_i, event_id.to_i]]
  end

  def self.all_contacts
    contacts.values
  end

  def self.register(trainer_type, trainer_name, version, map_id, event_id)
    return nil unless map_id && event_id && $PokemonGlobal
    key = [map_id.to_i, event_id.to_i]
    return contacts[key] if contacts[key]
    data = pbLoadTrainer(trainer_type, trainer_name, version)
    return nil unless data
    party = data.respond_to?(:party) ? data.party : (data.is_a?(Array) ? data[2] : nil)
    team = (party || []).map { |pkmn| pkmn.clone }
    contacts[key] = {
      :map_id => map_id.to_i, :event_id => event_id.to_i,
      :trainer_type => trainer_type, :trainer_name => trainer_name,
      :trainer_version => version, :affinity => 0, :rematches => 0,
      :last_rematch => 0, :last_chat => 0, :gift_claimed => false, :team => team, :status => :IDLE
    }
  rescue StandardError => e
    log("Registration failed: #{e.class}: #{e.message}")
    nil
  end

  def self.increase_affinity(entry, points)
    return unless entry
    entry[:affinity] = [[entry[:affinity].to_i + points.to_i, 0].max, MAX_AFFINITY].min
  end

  def self.rematch_ready?(entry)
    return false unless entry
    Time.now.to_i - entry[:last_rematch].to_i >= REMATCH_COOLDOWN
  end

  def self.record_rematch(entry, player_won)
    return unless entry
    entry[:rematches] = entry[:rematches].to_i + 1
    entry[:last_rematch] = Time.now.to_i
    increase_affinity(entry, player_won ? 8 : 3)
    # A won rematch counts for the PokéNav challenge, too.
    if player_won && $Trainer && $Trainer.respond_to?(:complete_challenge)
      $Trainer.complete_challenge(:rematch_trainer)
    end
    try_post_battle_gift(entry) if player_won
    # Hoenn trainers improve every time, even if they lost the battle.
    grow_team(entry, player_won ? 2 : 1)
    entry[:team_growth] = entry[:rematches].to_i
    event = dynamic_team_event(entry)
    event ||= :EVOLVE if entry.delete(:pending_evolution)
    # Save the exact change, not just its category.
    if event
      entry[:last_team_event] = event
      entry[:team_event_serial] = entry[:team_event_serial].to_i + 1
    end
  end

  def self.dynamic_team_event(entry)
    team = entry[:team]
    return nil unless team.is_a?(Array) && !team.empty?
    return nil unless $game_map && $game_map.map_id == entry[:map_id]
    # Hoenn's probabilities favor catching for small parties and fusing for larger ones.
    count = team.length
    weights = {
      :CATCH => [100, 40, 30, 20, 10, 5, 0][[count, 6].min],
      :FUSE => [0, 0, 40, 60, 65, 75, 85][[count, 6].min],
      :REVERSE => 10,
      :UNFUSE => [0, 10, 10, 5, 5, 0, 0][[count, 6].min]
    }
    candidates = weights.flat_map { |kind, weight| [kind] * weight }
    return nil if candidates.empty?
    # Try each distinct kind once, falling back when a fusion API isn't available.
    first = candidates.sample
    ([first] + (weights.keys - [first]).shuffle).each do |kind|
      changed = case kind
                when :CATCH then trainer_catch(entry)
                when :FUSE then trainer_fuse(entry)
                when :REVERSE then trainer_reverse(entry)
                when :UNFUSE then trainer_unfuse(entry)
                end
      return kind if changed
    end
    nil
  rescue StandardError => e
    report(e)
    nil
  end

  # New catches and fusion results belong to the trainer, not the player.
  def self.assign_trainer_owner(pkmn, entry, source = nil)
    return pkmn unless pkmn
    if source && source.respond_to?(:owner) && pkmn.respond_to?(:owner=)
      pkmn.owner = source.owner.clone
    elsif pkmn.respond_to?(:owner) && pkmn.owner
      # Keep the generated owner ID, but never inherit the player's name.
      pkmn.owner.name = entry[:trainer_name].to_s if pkmn.owner.respond_to?(:name=)
    end
    if pkmn.respond_to?(:owner) && pkmn.owner && pkmn.owner.respond_to?(:name=)
      pkmn.owner.name = entry[:trainer_name].to_s
    end
    pkmn
  rescue StandardError => e
    report(e)
    pkmn
  end

  def self.trainer_catch(entry)
    team = entry[:team]
    return false if team.length >= 6 || !$PokemonEncounters
    methods = []
    methods << :Land if $PokemonEncounters.respond_to?(:has_land_encounters?) && $PokemonEncounters.has_land_encounters?
    methods << :Cave if $PokemonEncounters.respond_to?(:has_cave_encounters?) && $PokemonEncounters.has_cave_encounters?
    methods << :Water if $PokemonEncounters.respond_to?(:has_water_encounters?) && $PokemonEncounters.has_water_encounters?
    return false if methods.empty? || !$PokemonEncounters.respond_to?(:choose_wild_pokemon)
    method = methods.sample
    method = $PokemonEncounters.find_valid_encounter_type_for_time(method, Time.now) if $PokemonEncounters.respond_to?(:find_valid_encounter_type_for_time)
    return false unless method
    result = $PokemonEncounters.choose_wild_pokemon(method)
    return false unless result.is_a?(Array) && result[0]
    species = result[0]
    level = result[1].to_i
    return false unless level > 0 && defined?(Pokemon)
    pkmn = Pokemon.new(species, level)
    assign_trainer_owner(pkmn, entry, team.first)
    team << pkmn
    entry[:team_event_names] = { "CAUGHT_POKEMON" => pkmn.name.to_s }
    true
  rescue StandardError => e
    report(e)
    false
  end

  def self.trainer_fuse(entry)
    team = entry[:team]
    return false unless defined?(getFusedPokemonIdFromSymbols)
    return false unless respond_to?(:getFusedPokemonIdFromSymbols, true) || Object.private_method_defined?(:getFusedPokemonIdFromSymbols)
    eligible = team.select { |p| p.respond_to?(:species) && !(p.respond_to?(:isFusion?) && p.isFusion?) }
    return false if eligible.length < 2
    body, head = eligible.sample(2)
    fused = getFusedPokemonIdFromSymbols(body.species, head.species)
    return false unless fused
    pokemon = Pokemon.new(fused, [body.level, head.level].max)
    assign_trainer_owner(pokemon, entry, body)
    team.delete(body)
    team.delete(head)
    team << pokemon
    entry[:team_event_names] = {
      "HEAD_POKEMON" => head.name.to_s, "BODY_POKEMON" => body.name.to_s,
      "FUSED_POKEMON" => pokemon.name.to_s
    }
    true
  rescue StandardError => e
    report(e)
    false
  end

  def self.trainer_reverse(entry)
    return false unless defined?(get_body_species_from_symbol) && defined?(get_head_species_from_symbol) && defined?(getFusedPokemonIdFromSymbols)
    pokemon = entry[:team].find { |p| p.respond_to?(:isFusion?) && p.isFusion? }
    return false unless pokemon
    body = get_body_species_from_symbol(pokemon.species)
    head = get_head_species_from_symbol(pokemon.species)
    reversed = getFusedPokemonIdFromSymbols(head, body)
    return false unless reversed
    old_name = pokemon.name.to_s
    pokemon.species = reversed
    entry[:team_event_names] = { "UNREVERSED_POKEMON" => old_name, "REVERSED_POKEMON" => pokemon.name.to_s }
    pokemon.calc_stats if pokemon.respond_to?(:calc_stats)
    true
  rescue StandardError => e
    report(e)
    false
  end

  def self.trainer_unfuse(entry)
    return false unless defined?(get_body_species_from_symbol) && defined?(get_head_species_from_symbol)
    team = entry[:team]
    return false if team.length >= 6
    pokemon = team.find { |p| p.respond_to?(:isFusion?) && p.isFusion? }
    return false unless pokemon
    body = get_body_species_from_symbol(pokemon.species)
    head = get_head_species_from_symbol(pokemon.species)
    return false unless body && head
    parts = [Pokemon.new(body, pokemon.level), Pokemon.new(head, pokemon.level)]
    parts.each { |part| assign_trainer_owner(part, entry, pokemon) }
    entry[:team_event_names] = {
      "UNFUSED_POKEMON" => pokemon.name.to_s,
      "BODY_POKEMON" => parts[0].name.to_s, "HEAD_POKEMON" => parts[1].name.to_s
    }
    team.delete(pokemon)
    team.concat(parts)
    true
  rescue StandardError => e
    report(e)
    false
  end

  # Only standard level evolutions. No stones, trades, or surprise fusions.
  def self.evolve_trainer_pokemon(pkmn)
    return unless pkmn.respond_to?(:species) && pkmn.respond_to?(:species=)
    return unless defined?(GameData::Species)
    data = GameData::Species.get(pkmn.species)
    return unless data.respond_to?(:get_evolutions)
    evolutions = data.get_evolutions
    return unless evolutions.respond_to?(:each)
    evolutions.each do |evolution|
      next unless evolution.is_a?(Array) && evolution.length >= 3
      target, method, requirement = evolution
      next unless method.to_s == "Level"
      next unless requirement.is_a?(Numeric) && pkmn.level >= requirement
      next unless GameData::Species.exists?(target)
      pkmn.species = target
      pkmn.calc_stats if pkmn.respond_to?(:calc_stats)
      break
    end
  rescue StandardError => e
    report(e)
  end

  def self.learn_trainer_moves(pkmn, new_level)
    return unless defined?(GameData::Species) && pkmn.respond_to?(:species)
    data = GameData::Species.get(pkmn.species)
    return unless data.respond_to?(:moves) && pkmn.respond_to?(:learn_move)
    data.moves.each do |learn_level, move|
      next unless learn_level.to_i == new_level
      pkmn.learn_move(move)
    end
  rescue StandardError => e
    report(e)
  end

  def self.grow_team(entry, levels = 1)
    team = entry[:team]
    return unless team.is_a?(Array)
    team.each do |pkmn|
      next unless pkmn.respond_to?(:level) && pkmn.respond_to?(:level=)
      next if pkmn.level >= 100
      # Keep growth tied to the player's progress, not unlimited grinding.
      player_level = ($Trainer && $Trainer.respond_to?(:party)) ? $Trainer.party.compact.map(&:level).max : nil
      ceiling = player_level ? [player_level + 3, 100].min : 100
      previous_level = pkmn.level
      pkmn.level = [pkmn.level + levels, ceiling].min
      next if pkmn.level <= previous_level
      ((previous_level + 1)..pkmn.level).each { |lv| learn_trainer_moves(pkmn, lv) }
      old_name = pkmn.name.to_s
      evolve_trainer_pokemon(pkmn)
      if pkmn.name.to_s != old_name
        entry[:pending_evolution] = true
        entry[:team_event_names] = {
          "UNEVOLVED_POKEMON" => old_name, "EVOLVED_POKEMON" => pkmn.name.to_s
        }
      end
      pkmn.calc_stats if pkmn.respond_to?(:calc_stats)
    end
  rescue StandardError => e
    report(e)
  end

  def self.team_summary(entry)
    team = entry[:team]
    return _INTL("Team information is unavailable.") unless team.is_a?(Array) && !team.empty?
    team.map do |pkmn|
      next pkmn.to_s unless pkmn.respond_to?(:name)
      level = pkmn.respond_to?(:level) ? pkmn.level : "?"
      "#{pkmn.name} Lv.#{level}"
    end.join("\\n")
  end

  # The summary gets copies; browsing someone else's team can't edit it.
  # Hoenn-style relationship card using the original PokeNav artwork.
  def self.relationship_profile(entry)
    viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
    viewport.z = 99999
    sprites = {}
    bg = "Graphics/Pictures/Pokegear/Trainers/bg_summary"
    sprites["background"] = IconSprite.new(0, 0, viewport)
    sprites["background"].setBitmap(bg)
    sprites["background"].zoom_x = Graphics.width.to_f / sprites["background"].bitmap.width
    sprites["background"].zoom_y = Graphics.height.to_f / sprites["background"].bitmap.height
    sprites["text"] = Sprite.new(viewport)
    sprites["text"].bitmap = Bitmap.new(Graphics.width, Graphics.height)
    bitmap = sprites["text"].bitmap
    pbSetSystemFont(bitmap)
    base = Color.new(40, 72, 104)
    shadow = Color.new(184, 208, 224)
    klass = entry[:trainer_type].to_s.gsub('_', ' ').split.map { |v| v.capitalize }.join(' ')
    name = entry[:trainer_name].to_s
    affinity = [[entry[:affinity].to_i, 0].max, 100].min
    party = entry[:team].is_a?(Array) ? entry[:team] : []
    avg = party.empty? ? '-' : (party.inject(0) { |n, p| n + p.level.to_i } / party.length).to_s
    pbDrawTextPositions(bitmap, [
      [_INTL('Trainers'), 38, 15, 0, base, shadow],
      ["#{klass} #{name}", 40, 65, 0, base, shadow],
      [_INTL('Friendship: {1}/100', affinity), 40, 125, 0, base, shadow],
      [_INTL('Rematches: {1}', entry[:rematches].to_i), 40, 170, 0, base, shadow],
      [_INTL('Team size: {1}', party.length), 40, 210, 0, base, shadow],
      [_INTL('Average level: {1}', avg), 40, 250, 0, base, shadow],
      [_INTL('Trade: {1}', affinity >= TRADE_AFFINITY ? 'Unlocked' : 'Locked'), 40, 290, 0, base, shadow],
      [_INTL('Partner: {1}', affinity >= PARTNER_AFFINITY ? 'Unlocked' : 'Locked'), 40, 330, 0, base, shadow]
    ])
    begin
      icon_path = "Graphics/Pictures/Pokegear/Trainers/friendship"
      icon = Bitmap.new(icon_path)
      # Five badges, each representing twenty friendship points.
      (affinity / 20).times { |i| bitmap.blt(40 + i * 21, 103, icon, Rect.new(0, 0, 16, 16)) }
      icon.dispose
    rescue StandardError
    end
    begin
      trainer_file = GameData::TrainerType.front_sprite_filename(entry[:trainer_type])
      if trainer_file
        sprites["trainer"] = IconSprite.new(0, 0, viewport)
        sprites["trainer"].setBitmap(trainer_file)
        sprites["trainer"].x = Graphics.width - 100
        sprites["trainer"].y = Graphics.height - 120
        sprites["trainer"].ox = sprites["trainer"].bitmap.width / 2
        sprites["trainer"].oy = sprites["trainer"].bitmap.height
      end
    rescue StandardError
    end
    loop do
      Graphics.update
      Input.update
      break if Input.trigger?(Input::BACK) || Input.trigger?(Input::USE)
    end
    true
  rescue StandardError => e
    report(e)
    pbMessage(_INTL('Affinity: {1}/100. Rematches: {2}.', entry[:affinity], entry[:rematches]))
    true
  ensure
    pbDisposeSpriteHash(sprites) if sprites
    viewport.dispose if viewport && !viewport.disposed?
  end

  def self.view_team(entry)
    party = entry[:team]
    unless party.is_a?(Array) && !party.empty?
      pbMessage(_INTL("Team information is unavailable."))
      return true
    end
    if defined?(PokemonSummary_Scene) && defined?(PokemonSummaryScreen)
      begin
        preview = party.map { |pkmn| pkmn.clone }
        scene = PokemonSummary_Scene.new
        PokemonSummaryScreen.new(scene).pbStartScreen(preview, 0)
        return true
      rescue StandardError => e
        report(e)
      end
    end
    pbMessage(team_summary(entry))
    true
  end

  def self.with_rematch_team(entry)
    previous = @active_rematch
    @active_rematch = entry
    yield
  ensure
    @active_rematch = previous
  end

  def self.active_rematch
    @active_rematch
  end

  def self.current_event
    return nil unless defined?(pbMapInterpreterRunning?) && pbMapInterpreterRunning?
    return nil unless defined?(pbMapInterpreter)
    pbMapInterpreter.get_character(0)
  rescue StandardError
    nil
  end

  def self.after_battle(won, trainer_type, trainer_name, version, event_id, map_id)
    return unless won && $PokemonGlobal
    return if defined?($PokemonTemp) && $PokemonTemp && $PokemonTemp.waitingTrainer
    event = current_event
    event_id ||= event.id if event && event.respond_to?(:id)
    map_id ||= $game_map.map_id if $game_map
    return unless event_id && map_id
    return if contact(map_id, event_id)
    existing = defined?(pbFindPhoneTrainer) ? pbFindPhoneTrainer(trainer_type, trainer_name) : nil
    # Hoenn contacts are automatic after a trainer battle.
    entry = register(trainer_type, trainer_name, version, map_id, event_id)
    return unless entry
    # Keep the built-in phone list in sync for the existing PokéNav Contacts app.
    pbPhoneRegister(event, trainer_type, trainer_name) if event && defined?(pbPhoneRegister) && !existing
    pbMessage(_INTL('Registered {1}!', trainer_name))
  rescue StandardError => e
    echoln "Hoenn rematches: post-battle error: #{e.message}" if defined?(echoln)
  end
end

# Wrap the existing battle entry point; never replace its story logic.
module HoennTrainerRematchesBattleHook
  def pbTrainerBattle(trainerID, trainerName, endSpeech = nil,
                      doubleBattle = false, trainerPartyID = 0,
                      canLose = false, outcomeVar = 1,
                      name_override = nil, trainer_type_overide = nil,
                      event_id = nil, map_id = nil)
    map_id ||= $game_map.map_id if $game_map
    event = HoennTrainerRematches.current_event
    event_id ||= event.id if event && event.respond_to?(:id)
    won = super(trainerID, trainerName, endSpeech, doubleBattle,
                trainerPartyID, canLose, outcomeVar)
    # Registration is handled through the defeated trainer's event.
    won
  end
end

Object.prepend(HoennTrainerRematchesBattleHook) unless Object.ancestors.include?(HoennTrainerRematchesBattleHook)

# The old Pokégear trainer scripts still run, but their registration now feeds
# the Hoenn contact book. No map event edits needed.
module HoennTrainerPhoneBridge
  def pbPhoneRegisterBattle(message, event, trainer_type, trainer_name, max_battles)
    return super unless event && $PokemonGlobal
    return super unless trainer_type
    return super unless HoennTrainerRematches.eligible_event?(event)
    # No confirmation needed for a trainer you've battled.
    map_id = event.map.map_id
    entry = HoennTrainerRematches.register(trainer_type, trainer_name, 0, map_id, event.id)
    return super unless entry
    pbPhoneRegister(event, trainer_type, trainer_name) if defined?(pbPhoneRegister)
    pbMessage(_INTL('Registered {1} as a Hoenn trainer contact!', trainer_name))
    true
  rescue StandardError => e
    HoennTrainerRematches.report(e)
    super
  end
end
Object.prepend(HoennTrainerPhoneBridge) unless Object.ancestors.include?(HoennTrainerPhoneBridge)

module HoennTrainerRematches
  @handling_interaction = false
  def self.report(error)
    File.open('HoennTrainerRematches_debug.txt', 'a') { |f| f.puts("#{error.class}: #{error.message}") }
  rescue StandardError
  end

  def self.eligible_event?(event)
    return false unless event && $game_map && event.respond_to?(:id)
    return false unless event.respond_to?(:name)
    # Only explicit player interactions; never autorun or parallel events.
    trigger = event.respond_to?(:trigger) ? event.trigger : event.instance_variable_get(:@trigger)
    return false unless [0, 1].include?(trigger)
    # Never hijack gym leaders, bosses or scripted story encounters.
    name = event.name.to_s
    return false if name.match?(/gym|leader|rival|boss|rocket|elite|champion|legend|story/i)
    return false unless name.match?(/\ATrainer(?:\(|\b)/i)
    # Every ordinary trainer is eligible; automatic events stay off-limits.
    true
  end

  def self.existing_phone_contact(event)
    return nil unless $PokemonGlobal && $PokemonGlobal.respond_to?(:phoneNumbers)
    ($PokemonGlobal.phoneNumbers || []).find do |record|
      record.is_a?(Array) && record.length >= 8 && record[0] &&
        record[6].to_i == $game_map.map_id && record[7].to_i == event.id
    end
  end

  # KIF uses PBTrainers constants, not GameData trainer symbols.
  def self.trainer_identity(event)
    return nil unless event.respond_to?(:event) && event.event
    event.event.pages.each do |page|
      (page.list || []).each do |cmd|
        next unless cmd.parameters
        script = if cmd.code == 111 && cmd.parameters[0] == 12
          cmd.parameters[1].to_s
        elsif [355, 655].include?(cmd.code)
          cmd.parameters[0].to_s
        else
          next
        end
        match = script.match(/pbTrainerBattle\s*\(\s*PBTrainers::([A-Za-z_]\w*)\s*,\s*["']([^"']+)["']/)
        match ||= script.match(/pbTrainerBattle\s*\(\s*:([A-Za-z_]\w*)\s*,\s*["']([^"']+)["']/)
        next unless match
        type_name = match[1]
        type = if defined?(PBTrainers) && PBTrainers.const_defined?(type_name)
          PBTrainers.const_get(type_name)
        else
          type_name.to_sym
        end
        version = script[/pbTrainerBattle\s*\([^\n]*?,\s*(\d+)\s*,\s*(?:true|false)\s*\)/, 1].to_i
        return [type, match[2], version, page]
      end
    end
    nil
  rescue StandardError => e
    report(e)
    nil
  end

  def self.log(message)
    path = File.join('Mods', 'HoennTrainerRematches', 'trainer_debug.txt')
    File.open(path, 'a') { |f| f.puts(message) }
  rescue StandardError
  end

  # Record the real event commands once, rather than guessing KIF's format.
  @inspected_events = {}
  def self.diagnose_trainer_event(event)
    key = [$game_map.map_id, event.id]
    return if @inspected_events[key]
    @inspected_events[key] = true
    log("=== Trainer event map=#{key[0]} id=#{key[1]} name=#{event.name.inspect} ===")
    pages = event.event.pages
    active = event.respond_to?(:page) ? event.page : event.instance_variable_get(:@page)
    pages.each_with_index do |page, index|
      log("PAGE #{index} active=#{page.equal?(active)}")
      (page.list || []).each do |cmd|
        next unless [101, 102, 108, 111, 122, 301, 355, 401, 408, 655].include?(cmd.code)
        # Don't evaluate any event scripts; just inspect their command text.
        text = (cmd.parameters || []).inspect.gsub(/[\r\n]+/, ' ')[0, 400]
        log("  code=#{cmd.code} args=#{text}")
      end
    end
  rescue StandardError => e
    report(e)
  end

  def self.defeated?(event, battle_page)
    # Don't offer registration while the original trainer battle page is active.
    current = event.respond_to?(:page) ? event.page : event.instance_variable_get(:@page)
    return false unless current
    return false if current.equal?(battle_page)
    # Defeated trainers commonly use self-switch A.
    return true if $game_self_switches[[$game_map.map_id, event.id, "A"]]
    current != battle_page
  end

  # Only trainer-event trade scripts are gated. Ordinary NPC story trades stay intact.
  def self.trainer_trade_event?(event)
    return false unless event && event.respond_to?(:event) && event.event
    return false unless event.name.to_s.match?(/trainer/i)
    event.event.pages.any? do |page|
      (page.list || []).any? do |cmd|
        next false unless cmd.parameters
        next false unless [111, 355, 655].include?(cmd.code)
        text = cmd.parameters.map(&:to_s).join(" ")
        text.match?(/\b(?:pbStartTrade|pbTradePokemon|pbTrade|pbNPCTrade|pbStartPokemonTrade)\s*\(/i)
      end
    end
  rescue StandardError
    false
  end

  def self.trainer_says(event, message)
    # Match the bubble used by KIF's original trainer events.
    if event && defined?(pbCallBub)
      begin
        pbCallBub(2, event.id)
      rescue StandardError => e
        log("Bubble fallback: #{e.class}: #{e.message}")
      end
    end
    pbMessage(message)
  end

  # A trainer's class and friendship shape their voice, not just their greeting.
  TRAINER_VOICES = {
    :bug => {
      :new => ["The best Bug Pokemon hide where you'd least expect!", "Careful around the grass. There are tiny Pokemon everywhere!", "I'm learning which bugs work best together.", "Even little bugs can surprise a big opponent."],
      :friend => ["I've been searching for rare Bug Pokemon to strengthen my team!", "My bugs are getting tougher with every battle we have.", "I bet you've started noticing the little things in battle too!", "I've got a new strategy involving my Bug Pokemon."],
      :close => ["You know, you're one of the few people who really respects my bugs.", "Remember our first battle? My team has changed so much since then!", "If I find a rare Bug Pokemon, you'll be the first to hear about it.", "Battling with you makes me want to become a Bug expert!"],
      :fusion => ["A fused Bug Pokemon could have some amazing abilities!", "I've been studying how my fused Pokemon battles."],
      :large => ["My bug collection is growing! Choosing a team is getting tricky."],
      :trade => ["I'm taking good care of the Pokemon we exchanged!"],
      :rematch => ["My bugs know your battling style by now. Almost!"]
    },
    :youngster => {
      :new => ["My Pokemon and I are gonna be champions someday!", "I trained all morning. Wanna see how much stronger I got?", "I bet I can win our next battle!", "You won't catch me giving up that easily!"],
      :friend => ["Okay, you're pretty good. But I'm catching up!", "I've been practicing a new battle plan. It's gonna work this time!", "My Pokemon have gotten way stronger since we met.", "I told my friends about our last battle. They didn't believe me!"],
      :close => ["You're my biggest rival! Don't go easy on me, okay?", "When I finally beat you, we're both gonna celebrate!", "I've learned more battling you than anyone else.", "Someday we'll be the two strongest trainers around!"],
      :fusion => ["Check out my fusion! Bet you didn't see that coming!", "Two Pokemon in one? That's gotta make me stronger!"],
      :large => ["I've caught so many Pokemon, I can't pick my favorites!"],
      :trade => ["That Pokemon you traded me is doing awesome!"],
      :rematch => ["I've been keeping score. I'll turn it around next time!"]
    },
    :lass => {
      :new => ["My Pokemon and I have been practicing together.", "I love seeing all the different Pokemon around here!", "Every Pokemon has its own personality, don't you think?"],
      :friend => ["My team seems happier every time we train together.", "I tried a new strategy after our last battle!", "It's fun having someone familiar to battle again."],
      :close => ["It's so nice to see you again! My Pokemon missed you too.", "You've helped me become a much better trainer.", "Our Pokemon have grown up together, haven't they?"],
      :fusion => ["My fused Pokemon has such an interesting personality!"],
      :large => ["My team keeps growing. Everyone needs attention!"],
      :trade => ["The Pokemon we traded is settling in wonderfully."],
      :rematch => ["I always learn something when we battle."]
    },
    :hiker => {
      :new => ["These rocky trails make a trainer tough!", "Nothing beats a hike through the mountains!", "You've got to have sturdy footing to battle out here."],
      :friend => ["My Pokemon and I have climbed some tough paths lately.", "A good battle is like a steep climb. You earn every step!", "You've got the grit of a proper mountain trainer."],
      :close => ["I'd trust you to watch my back on any mountain trail!", "We've come a long way, haven't we?", "You're tougher than bedrock, my friend!"],
      :fusion => ["That fusion's built like a mountain!"],
      :large => ["A full team makes the climb a bit crowded!"],
      :trade => ["Your Pokemon's handling these mountain trails well!"],
      :rematch => ["Let's see whose training has paid off this time!"]
    },
    :fisher => {
      :new => ["Patience is the secret to both fishing and battling.", "The water's calm today. Wonder what's biting?", "You never know what you'll reel in out here."],
      :friend => ["I've found some promising fishing spots lately.", "Battling you is more exciting than waiting for a bite!", "My team is learning to ride out rough waters."],
      :close => ["You're always welcome to fish beside me, friend.", "We've shared more battles than I've caught fish today!", "If I hook something special, you'll hear about it first."],
      :fusion => ["Wonder if that fusion could swim against the current?"],
      :large => ["My catch has gotten bigger than my tackle box!"],
      :trade => ["That Pokemon you gave me is quite the catch!"],
      :rematch => ["Ready for another battle? Hope you're not the one that gets hooked!"]
    },
    :ace => {
      :new => ["A good trainer always studies their opponent.", "I refine my strategy after every match.", "Consistency matters more than a lucky victory."],
      :friend => ["Your tactics have become harder to predict.", "I've been experimenting with different team combinations.", "Our battles are excellent training."],
      :close => ["I consider you a worthy rival and a trusted friend.", "We've both improved tremendously since our first match.", "I look forward to testing our strongest teams again."],
      :fusion => ["This fusion opens up some interesting tactical possibilities."],
      :large => ["Team selection is as important as the battle itself."],
      :trade => ["Your former Pokemon has adapted well to my strategy."],
      :rematch => ["I've revised my approach since our last battle."]
    },
    :default => {
      :new => ["I've been exploring this area with my Pokemon.", "There's always something new to learn about battling.", "My team and I still have plenty to practice."],
      :friend => ["It's good to see a familiar trainer again.", "Our last battle gave me a few ideas to try.", "My Pokemon have been making real progress lately."],
      :close => ["We've been through quite a few battles together, haven't we?", "It's always a pleasure to see you, my friend.", "My team wouldn't be where it is without our battles."],
      :fusion => ["I'm learning what this fusion can do in battle."],
      :large => ["My team has really grown since we first met."],
      :trade => ["The Pokemon we exchanged is doing well!"],
      :rematch => ["I have a few new tricks for our next battle."]
    }
  }.freeze

  def self.trainer_voice(entry)
    type = entry[:trainer_type].to_s.upcase
    return :bug if type.include?("BUGCATCHER") || type.include?("BUG_CATCHER")
    return :youngster if type.include?("YOUNGSTER")
    return :lass if type.include?("LASS")
    return :hiker if type.include?("HIKER")
    return :fisher if type.include?("FISHERMAN") || type.include?("FISHER") || type.include?("SAILOR")
    return :ace if type.include?("ACE") || type.include?("COOLTRAINER") || type.include?("VETERAN")
    :default
  end

  # Use Hoenn's per-trainer dialogue fields when KIF has them.
  HOENN_EVENT_FIELDS = {
    :CATCH => :preRematch_text_caught,
    :EVOLVE => :preRematch_text_evolved,
    :FUSE => :preRematch_text_fused,
    :UNFUSE => :preRematch_text_unfused,
    :REVERSE => :preRematch_text_reversed,
    :GIFT => :preRematch_text_gift
  }.freeze

  # These are the actual dialogue fields extracted from Hoenn's trainer data.
  def self.hoenn_dialogue_records
    return @hoenn_dialogue_records if @hoenn_dialogue_records
    load File.join(File.dirname(__FILE__), 'hoenn_dialogue_data.rb') unless const_defined?(:HOENN_DIALOGUE_DATA)
    records = const_get(:HOENN_DIALOGUE_DATA)
    @hoenn_dialogue_records = {}
    records.each do |record|
      key = [record['type'].to_s.upcase, record['name'].to_s.downcase, record['version'].to_i]
      @hoenn_dialogue_records[key] = record
    end
    @hoenn_dialogue_records
  rescue StandardError => e
    report(e)
    {}
  end

  # Original lines for matching trainers; class-matched Hoenn event lines for everyone else.
  def self.hoenn_dialogue_for(entry)
    key = [entry[:trainer_type].to_s.upcase, entry[:trainer_name].to_s.downcase, entry[:trainer_version].to_i]
    records = hoenn_dialogue_records
    exact = records[key] || records[[key[0], key[1], 0]]
    return [exact, true] if exact
    voice = trainer_voice(entry)
    matching = records.values.select { |r| trainer_voice(:trainer_type => r['type']) == voice }
    return [nil, false] if matching.empty?
    # Stable donor per trainer; no random changes between game launches.
    seed = (key.join(':').bytes.inject(0) { |n, c| (n * 31 + c) % 2147483647 })
    [matching[seed % matching.length], false]
  end

  def self.hoenn_trainer_dialogue(entry)
    data, exact = hoenn_dialogue_for(entry)
    return nil unless data
    kind = entry[:last_team_event]
    field = { :CATCH => 'caught', :EVOLVE => 'evolved', :FUSE => 'fused',
              :UNFUSE => 'unfused', :REVERSE => 'reversed', :GIFT => 'gift' }[kind]
    serial = entry[:team_event_serial].to_i
    if field && serial > entry[:last_spoken_team_serial].to_i
      raw = data[field]
      names = entry[:team_event_names] || {}
      if raw && !raw.empty?
        raw = raw.gsub(/<([A-Z_]*POKEMON)>/) { |token| names[$1] || token }
        if !raw.match?(/<[A-Z_]*POKEMON>/)
          entry[:last_spoken_team_serial] = serial
          return raw.gsub('<PLAYER_NAME>', ($Trainer ? $Trainer.name.to_s : 'Trainer'))
        end
      end
    end
    # Exact Hoenn trainer greetings only once; other KIF trainers get class dialogue.
    if exact && entry[:hoenn_normal_chat_count].to_i == 0
      entry[:hoenn_normal_chat_count] = 1
      raw = data['default']
      return raw.gsub('<PLAYER_NAME>', ($Trainer ? $Trainer.name.to_s : 'Trainer')) if raw && !raw.empty?
    end
    nil
  rescue StandardError => e
    report(e)
    nil
  end

  def self.chat(entry, event = nil)
    hoenn_line = hoenn_trainer_dialogue(entry)
    if hoenn_line
      hoenn_line.split('<br>').each { |line| trainer_says(event, line) unless line.strip.empty? }
      now = Time.now.to_i
      if now - entry[:last_chat].to_i >= CHAT_COOLDOWN
        entry[:last_chat] = now
        increase_affinity(entry, 1)
      end
      return true
    end
    affinity = entry[:affinity].to_i
    voice = TRAINER_VOICES[trainer_voice(entry)]
    stage = affinity >= 75 ? :close : affinity >= 35 ? :friend : :new
    lines = voice[stage].dup
    team = entry[:team].is_a?(Array) ? entry[:team] : []
    extras = []
    extras.concat(voice[:fusion]) if team.any? { |pkmn| pkmn.respond_to?(:isFusion?) && pkmn.isFusion? }
    extras.concat(voice[:large]) if team.length >= 4
    extras.concat(voice[:trade]) if entry[:last_trade].to_i > 0
    extras.concat(voice[:rematch]) if entry[:rematches].to_i >= 3
    # Keep class-specific friendship dialogue prominent.
    lines << extras.sample unless extras.empty?
    previous = entry[:last_dialogue]
    available = lines.reject { |line| line == previous }
    available = lines if available.empty?
    line = available.sample
    entry[:last_dialogue] = line
    trainer_says(event, _INTL(line))
    now = Time.now.to_i
    if now - entry[:last_chat].to_i >= CHAT_COOLDOWN
      entry[:last_chat] = now
      increase_affinity(entry, 1)
    end
    true
  end

  # Hoenn-style gifts happen after battles, not through the contact menu.
  GIFT_POOLS = {
    "BUG" => [:ANTIDOTE, :HONEY, :POTION],
    "HIKER" => [:REPEL, :SUPERPOTION, :STARDUST],
    "FISHERMAN" => [:POKEBALL, :POTION, :PEARL],
    "SAILOR" => [:POKEBALL, :POTION, :PEARL],
    "PSYCHIC" => [:AWAKENING, :POTION, :FULLHEAL],
    "BLACKBELT" => [:XATTACK, :POTION, :SUPERPOTION],
    "YOUNGSTER" => [:POKEBALL, :POTION, :REPEL],
    "LASS" => [:POKEBALL, :POTION, :ANTIDOTE]
  }.freeze
  DEFAULT_GIFTS = [:POTION, :REPEL, :ANTIDOTE, :POKEBALL].freeze

  def self.try_post_battle_gift(entry)
    return false unless entry && entry[:affinity].to_i >= GIFT_AFFINITY
    chance = [GIFT_BASE_CHANCE + entry[:affinity].to_i / 10, 60].min
    return false unless rand(100) < chance
    return false unless defined?($PokemonBag) && $PokemonBag && $PokemonBag.respond_to?(:pbStoreItem)
    type = entry[:trainer_type].to_s.upcase
    pool = GIFT_POOLS.find { |key, _| type.include?(key) }
    candidates = pool ? pool[1] : DEFAULT_GIFTS
    candidates = candidates.select do |item|
      !defined?(GameData::Item) || GameData::Item.exists?(item)
    end
    return false if candidates.empty?
    item = candidates.sample
    return false unless $PokemonBag.pbStoreItem(item, 1)
    name = if defined?(GameData::Item)
      GameData::Item.get(item).name
    else
      item.to_s.capitalize
    end
    pbMessage(_INTL("{1} wanted to thank you for the battle!", entry[:trainer_name]))
    pbMessage(_INTL("Received {1}!", name))
    true
  rescue StandardError => e
    report(e)
    false
  end

  # Hoenn's trainer-class preferences, with the same species-value ingredients.
  TRAINER_CLASS_PICKINESS = {
    # TIER 1: Masters (2.4-3.0)
    CHAMPION_Steven: 3.0,
    ELITEFOUR_Drake: 2.8,
    ELITEFOUR_Glacia: 2.8,
    ELITEFOUR_Phoebe: 2.8,
    ELITEFOUR_Sidney: 2.8,
    TEAM_AQUA_BOSS: 2.8,
    TEAM_MAGMA_BOSS: 2.8,
    LEADER_Wallace: 2.7,
    LEADER_Juan: 2.7,
    LEADER_Roxanne: 2.6,
    LEADER_Brawly: 2.6,
    LEADER_Wattson: 2.6,
    LEADER_Flannery: 2.6,
    LEADER_Norman: 2.6,
    LEADER_Winona: 2.6,
    LEADER_Tate: 2.6,
    LEADER_Liza: 2.6,
    PROFESSOR: 2.5,
    EXPERT_M: 2.5,
    EXPERT_F: 2.5,
  
    # TIER 2: Professionals & wealthy (1.9 - 2.3)
    COOLTRAINER_M: 2.3,
    COOLTRAINER_F: 2.3,
    COOLTRAINER_M2: 2.3,
    COOLTRAINER_F2: 2.3,
    DRAGONTAMER: 2.3,
    LADY: 2.4,
    GENTLEMAN: 2.3,
    SOCIALITE: 2.3,
    RICHBOY: 2.3,
    COLLECTOR: 2.3,
    BEAUTY: 2.2,
    KIMONOGIRL: 2.2,
    SAGE: 2.1,
    COOLCOUPLE: 2.1,
    ENGINEER: 2.0,
    PAINTER: 2.0,
    SCIENTIST: 2.0,
    POKEMONRANGER_M: 2.0,
    POKEMONRANGER_F: 2.0,
    PSYCHIC_M: 2.0,
    PSYCHIC_F: 2.0,
    TEACHER: 2.0,
    NURSE: 2.0,
    POKEMONBREEDER_F: 1.9,
    POKEMONBREEDER_M: 1.9,
    SUPERNERD: 1.9,
  
    # TIER 3: Hobbyists (1.5 - 1.8)
    AROMALADY: 1.8,
    JUGGLER: 1.8,
    POLICE: 1.8,
    PARASOLLADY: 1.8,
    SECRETBASEEXPERT: 1.8,
    CHANNELER: 1.7,
    BLACKBELT: 1.7,
    HAUNTEDGIRL: 1.7,
    CRUSHKIN: 1.7,
    POKEMANIAC: 1.6,
    BUGMANIAC: 1.6,
    POKEFAN_M: 1.6,
    POKEFAN_F: 1.6,
    CRUSHGIRL: 1.6,
    YOUNGCOUPLE: 1.6,
    YOUNGCOUPLE_M: 1.6,
    YOUNGCOUPLE_F: 1.6,
    WORKER: 1.6,
    PYROMANIAC: 1.6,
    SKIER_F: 1.6,
    GAMBLER: 1.5,
    HIKER: 1.5,
    RUINMANIAC: 1.5,
    TAMER: 1.5,
    CLOWN: 1.5,
    FARMER: 1.5,
    REPORTER: 1.5,
    CAMERAMAN: 1.5,
    TRIATHLETE_BIKE_M: 1.5,
    TRIATHLETE_BIKE_F: 1.5,
    TRIATHLETE_SWIM_M: 1.5,
    TRIATHLETE_SWIM_F: 1.5,
    TRIATHLETE_RUN_M: 1.5,
    TRIATHLETE_RUN_F: 1.5,
  
    # TIER 4: Average joes (1.1 - 1.4)
    BIRDKEEPER: 1.4,
    FISHERMAN: 1.4,
    ROCKER: 1.4,
    ROUGHNECK: 1.4,
    SCHOOLMATE_SR: 1.4,
    BURGLAR: 1.3,
    CUEBALL: 1.3,
    SAILOR: 1.3,
    SISANDBRO: 1.3,
    DELIVERYMAN: 1.3,
    HAUNTEDGIRL_YOUNG: 1.3,
    SURFER: 1.3,
    DIVER_M: 1.3,
    DIVER_F: 1.3,
    SWIMMER_M: 1.3,
    SWIMMER_F: 1.3,
    SWIMMER2_M: 1.3,
    SWIMMER2_F: 1.3,
    BIKER: 1.2,
    CAMPER: 1.2,
    PICNICKER: 1.2,
    STREETTHUG: 1.2,
    DELINQUENT: 1.2,
    SCHOOLBOY: 1.2,
    SCHOOLGIRL: 1.2,
    NINJABOY: 1.2,
    BUGCATCHER: 1.1,
    BUGCATCHER_F: 1.1,
    SCHOOLMATE_JR: 1.1,
  
    # TIER 5: Novices & children
    LASS: 1.0,
    PLAYER: 1.0,
    TWINS: 1.0,
    TWIN_1: 1.0,
    TWIN_2: 1.0,
    YOUNGSTER: 0.9,
    TUBER_M: 0.8,
    TUBER_F: 0.8,
    TUBER2_M: 0.8,
    TUBER2_F: 0.8,
    PRESCHOOLER_M: 0.6,
    PRESCHOOLER_F: 0.6
  }
  TRAINER_CLASS_FAVORITE_TYPES =
      {
        RIVAL1: [:ANY],
        RIVAL2: [:ANY],
        AROMALADY:      [:GRASS, :FAIRY],
        BEAUTY:         [:FAIRY, :WATER, :NORMAL, :GRASS],
        BIKER:          [:POISON, :DARK],
        BIRDKEEPER:     [:FLYING],
        BUGCATCHER:     [:BUG],
        BURGLAR:        [:FIRE, :DARK],
        CHANNELER:      [:GHOST, :PSYCHIC],
        CUEBALL:        [:FIGHTING, :STEEL],
        ENGINEER:       [:ELECTRIC, :STEEL],
        FISHERMAN:      [:WATER],
        GAMBLER:        [:NORMAL, :PSYCHIC],
        GENTLEMAN:      [:NORMAL, :STEEL],
        HIKER:          [:ROCK, :GROUND],
        JUGGLER:        [:PSYCHIC, :GHOST, :NORMAL, :POISON],
        LADY:           [:FAIRY, :NORMAL],
        PAINTER:        [:NORMAL, :PSYCHIC, :GRASS],
        POKEMANIAC:     [:DRAGON, :GROUND],
        POKEMONBREEDER_F: [:NORMAL, :GRASS],
        PROFESSOR:      [:NORMAL, :PSYCHIC],
        ROCKER:         [:ELECTRIC, :FIRE],
        RUINMANIAC:     [:GROUND, :ROCK, :PSYCHIC],
        SAILOR:         [:WATER, :FIGHTING],
        SCIENTIST:      [:ELECTRIC, :STEEL, :POISON],
        SUPERNERD:      [:ELECTRIC, :PSYCHIC, :STEEL],
        TAMER:          [:NORMAL, :DARK],
        BLACKBELT:      [:FIGHTING],
        CRUSHGIRL:      [:FIGHTING],
        CAMPER:         [:BUG, :FIRE, :GRASS],
        PICNICKER:      [:GRASS, :NORMAL],
        COOLTRAINER_M:  [:DRAGON, :STEEL, :FIRE],
        COOLTRAINER_F:  [:ICE, :PSYCHIC, :FAIRY],
        YOUNGSTER:      [:NORMAL, :BUG, :GRASS, :FLYING],
        LASS:           [:NORMAL, :FAIRY, :GRASS, :FLYING],
        POKEMONRANGER_M: [:GRASS, :GROUND],
        POKEMONRANGER_F: [:GRASS, :WATER],
        PSYCHIC_M:      [:PSYCHIC, :GHOST],
        PSYCHIC_F:      [:PSYCHIC, :FAIRY],
        SWIMMER_M:      [:WATER, :ICE],
        SWIMMER_F:      [:WATER, :ICE],
        SWIMMER2_M:     [:WATER],
        SWIMMER2_F:     [:WATER],
        TUBER_M:        [:WATER],
        TUBER_F:        [:WATER],
        TUBER2_M:       [:WATER],
        TUBER2_F:       [:WATER],
        COOLCOUPLE:     [:FIRE, :ICE],
        CRUSHKIN:       [:FIGHTING],
        SISANDBRO:      [:WATER, :GROUND],
        TWINS:          [:FAIRY, :NORMAL],
        YOUNGCOUPLE:    [:NORMAL, :PSYCHIC],
        SOCIALITE:      [:FAIRY, :NORMAL],
        BUGCATCHER_F:   [:BUG],
        ROUGHNECK:      [:DARK, :FIGHTING],
        TEACHER:        [:PSYCHIC, :NORMAL],
        PRESCHOOLER_M:  [:NORMAL, :BUG],
        PRESCHOOLER_F:  [:FAIRY, :NORMAL],
        HAUNTEDGIRL_YOUNG:  [:GHOST],
        HAUNTEDGIRL:        [:GHOST, :DARK],
        CLOWN:          [:PSYCHIC, :FAIRY],
        NURSE:          [:NORMAL, :FAIRY],
        WORKER:         [:STEEL, :GROUND],
        COOLTRAINER_M2: [:FIGHTING, :STEEL],
        COOLTRAINER_F2: [:PSYCHIC, :ICE],
        FARMER:         [:GRASS, :GROUND, :NORMAL],
        PYROMANIAC:     [:FIRE],
        KIMONOGIRL:     [:FAIRY, :PSYCHIC, :GHOST],
        SAGE:           [:PSYCHIC, :GHOST],
        PLAYER:         [:ICE, :FIGHTING],
        POLICE:         [:DARK, :FIGHTING],
        SKIER_F:        [:ICE],
        DELIVERYMAN:  [:NORMAL],
  
        SCHOOLBOY:  [:BUG, :NORMAL, :GRASS],
        SCHOOLGIRL:  [:BUG, :NORMAL , :GRASS],
        TWIN_1:          [:FAIRY, :NORMAL, :FLYING],
        TWIN_2:          [:FAIRY, :NORMAL, :FLYING],
        POKEFAN_M:          [:WATER, :FIRE, :GRASS, :ELECTRIC],
        POKEFAN_F:          [:WATER, :FIRE, :GRASS, :ELECTRIC],
        RICHBOY:          [:NORMAL, :GRASS],
        POKEMONBREEDER_M:          [:NORMAL, :GRASS],
        STREETTHUG:          [:POISON, :DARK, :FIGHTING],
        DELINQUENT:          [:POISON, :DARK, :FIGHTING],
        BUGMANIAC:          [:BUG],
        EXPERT_M:          [:FIGHTING],
        EXPERT_F:          [:FIGHTING],
        COLLECTOR:          [:ROCK, :STEEL, :DRAGON, :FAIRY, :GHOST, :PSYCHIC],
        SURFER:          [:WATER, :FLYING],
        DIVER_M:          [:WATER],
        DIVER_F:          [:WATER],
        REPORTER:          [:NORMAL],
        CAMERAMAN:          [:ELECTRIC],
        NINJABOY:          [:BUG, :POISON],
        DRAGONTAMER:          [:DRAGON],
        TRIATHLETE_BIKE_M:          [:GROUND,:WATER, :FLYING],
        TRIATHLETE_BIKE_F:          [:GROUND,:WATER, :FLYING],
        TRIATHLETE_SWIM_M:          [:GROUND,:WATER, :FLYING],
        TRIATHLETE_SWIM_F:          [:GROUND,:WATER, :FLYING],
        TRIATHLETE_RUN_M:          [:GROUND,:WATER, :FLYING],
        TRIATHLETE_RUN_F:          [:GROUND,:WATER, :FLYING],
        YOUNGCOUPLE_M:          [:NORMAL, :PSYCHIC],
        YOUNGCOUPLE_F:          [:NORMAL, :PSYCHIC],
        PARASOLLADY:          [:WATER, :FLYING, :ELECTRIC],
        HEXMANIAC:          [:GHOST],
        SECRETBASEEXPERT:          [:NORMAL, :GROUND, :ROCK, :GRASS],
        SCHOOLMATE_SR:         [:FAIRY, :NORMAL, :GRASS],
        SCHOOLMATE_JR:         [:FAIRY, :NORMAL, :GRASS],
        LEADER_Roxanne:  [:ROCK],
        LEADER_Brawly:  [:FIGHTING],
        LEADER_Wattson:  [:ELECTRIC],
        LEADER_Flannery:  [:FIRE],
        LEADER_Norman:  [:NORMAL],
        LEADER_Winona:  [:FLYING],
        LEADER_Tate:  [:PSYCHIC],
        LEADER_Liza:  [:PSYCHIC],
        LEADER_Wallace:  [:WATER],
        LEADER_Juan:  [:WATER],
        ELITEFOUR_Sidney:  [:PSYCHIC],
        ELITEFOUR_Phoebe:  [:GHOST],
        ELITEFOUR_Glacia:  [:ICE],
        ELITEFOUR_Drake:  [:DRAGON],
        CHAMPION_Steven:  [:STEEL],
  
        TEAM_AQUA_BOSS:  [:WATER],
        TEAM_AQUA_EXEC_M:  [:WATER],
        TEAM_AQUA_EXEC_F:  [:WATER],
  
        TEAM_MAGMA_BOSS:  [:GROUND],
        TEAM_MAGMA_EXEC_M:  [:GROUND],
        TEAM_MAGMA_EXEC_F:  [:GROUND],
  
      }
  def self.trade_preferences(entry)
    kind = entry[:trainer_type].to_s.to_sym
    TRAINER_CLASS_FAVORITE_TYPES[kind] || [:ANY]
  end

  def self.trade_value(pkmn, compare_level = nil, preferred = nil)
    data = pkmn.respond_to?(:species_data) ? pkmn.species_data : nil
    return nil unless data
    level = pkmn.level.to_i
    stats = data.base_stats
    total_stats = stats.respond_to?(:values) ? stats.values.inject(0, :+) : 0
    ivs = pkmn.respond_to?(:iv) ? pkmn.iv : nil
    total_ivs = ivs.respond_to?(:values) ? ivs.values.inject(0, :+) : 0
    rate = data.respond_to?(:catch_rate) ? data.catch_rate.to_i : 255
    score = level * 2.0 + (compare_level ? [level - compare_level, 0].max * 1.5 : 0)
    score += total_stats / 10.0 + (255 - rate) / 5.0 + total_ivs / 4.0
    score += 50 if pkmn.respond_to?(:shiny?) && pkmn.shiny?
    score += 40 if pkmn.respond_to?(:isFusion?) && pkmn.isFusion?
    if preferred && preferred != :ANY && pkmn.respond_to?(:hasType?)
      score += 30 if pkmn.hasType?(preferred)
    end
    score
  rescue StandardError => e
    report(e)
    nil
  end

  def self.trade_offer(entry, offered)
    preferences = trade_preferences(entry)
    preferred = preferences.reject { |t| t == :ANY }.find { |t| GameData::Type.exists?(t) } if defined?(GameData::Type)
    kind = entry[:trainer_type].to_s.to_sym
    pickiness = TRAINER_CLASS_PICKINESS[kind] || 1.0
    offered_score = trade_value(offered, nil, preferred)
    return nil unless offered_score
    scores = entry[:team].each_with_index.map do |pkmn, index|
      next if !pkmn || (pkmn.respond_to?(:egg?) && pkmn.egg?)
      value = trade_value(pkmn, offered.level, preferred)
      value ? [index, value] : nil
    end.compact
    return nil if scores.empty?
    best = scores.max_by { |_, value| value }
    return best[0] if offered_score > best[1]
    tolerance = [offered_score, 100].min * pickiness
    acceptable = scores.select { |_, value| (value - offered_score).abs <= tolerance }
    return nil if acceptable.empty?
    acceptable.min_by { |_, value| (value - offered_score).abs }[0]
  end

  def self.trade_with_trainer(entry)
    team = entry[:team]
    return true unless team.is_a?(Array) && !team.empty?
    return true unless $Trainer && $Trainer.respond_to?(:party)
    preferences = trade_preferences(entry)
    types = preferences.reject { |t| t == :ANY }
    if types.empty?
      pbMessage(_INTL("{1} is interested in trading Pokémon.", entry[:trainer_name]))
    else
      pbMessage(_INTL("{1} is looking for Pokémon of these types: {2}.", entry[:trainer_name], types.join(', ')))
    end
    pbChoosePokemon(1, 2, proc { |p| p && !p.egg? && (types.empty? || types.any? { |t| p.respond_to?(:hasType?) && p.hasType?(t) }) })
    index = pbGet(1)
    return true unless index && index >= 0 && index < $Trainer.party.length
    offered = $Trainer.party[index]
    return true unless offered && !(offered.respond_to?(:egg?) && offered.egg?)
    choice = trade_offer(entry, offered)
    unless choice
      pbMessage(_INTL("{1} isn't interested in that trade right now.", entry[:trainer_name]))
      return true
    end
    received = team[choice]
    pbMessage(_INTL("{1} offers {2} (Lv. {3}) for your {4}.", entry[:trainer_name], received.name, received.level, offered.name))
    return true unless pbConfirmMessage(_INTL("Trade {1} for {2}?", offered.name, received.name))
    incoming = received.clone
    outgoing = offered.clone
    # Commit the NPC's team only after the game's trade completes.
    result = pbStartTrade(index, incoming, incoming.name, entry[:trainer_name])
    if result == false
      pbMessage(_INTL("The trade wasn't completed."))
      return true
    end
    team[choice] = outgoing
    entry[:affinity] = [[entry[:affinity].to_i - TRADE_AFFINITY_COST, 0].max, MAX_AFFINITY].min
    entry[:last_trade] = Time.now.to_i
    pbMessage(_INTL("{1} will use {2} in future rematches!", entry[:trainer_name], outgoing.name))
    true
  rescue StandardError => e
    report(e)
    pbMessage(_INTL("The trade couldn't be completed."))
    true
  end

  # Use KIF's own dependent-event follower and battle-partner systems.
  # No Hoenn common event ID is assumed to exist in KIF.
  def self.partner_key
    $PokemonGlobal && $PokemonGlobal.respond_to?(:hoenn_rematch_partner_key) ?
      $PokemonGlobal.hoenn_rematch_partner_key : nil
  end

  def self.original_partner_event?(event)
    key = partner_key
    key && $game_map && event &&
      key[0].to_i == $game_map.map_id && key[1].to_i == event.id
  end

  def self.hide_partner_original(event)
    return unless original_partner_event?(event)
    event.transparent = true if event.respond_to?(:transparent=)
    event.through = true if event.respond_to?(:through=)
  end

  def self.partner_follower_in_front?(player)
    key = partner_key
    return false unless key && $PokemonTemp && $game_map
    followers = $PokemonTemp.dependentEvents
    return false unless followers && followers.respond_to?(:getEventByName)
    name = "HoennPartner_#{key[0]}_#{key[1]}"
    follower = followers.getEventByName(name)
    return false unless follower
    follower_map = follower.respond_to?(:map) ? follower.map : nil
    return false if follower_map && follower_map.map_id != $game_map.map_id
    dx = player.direction == 6 ? 1 : player.direction == 4 ? -1 : 0
    dy = player.direction == 2 ? 1 : player.direction == 8 ? -1 : 0
    follower.x == player.x + dx && follower.y == player.y + dy
  rescue StandardError => e
    report(e)
    false
  end

  def self.partner_follower_menu
    key = partner_key
    return false unless key
    entry = contact(key[0], key[1])
    return false unless entry
    choice = HoennSuiteTrainerMenu.choose([_INTL('Keep following'), _INTL('Dismiss Partner')])
    dismiss_partner if choice == 1
    true
  end

  def self.recruit_partner(entry, event)
    return true unless entry && entry[:affinity].to_i == PARTNER_AFFINITY
    if !$PokemonGlobal || $PokemonGlobal.partner || partner_key
      pbMessage(_INTL("You already have a partner."))
      return true
    end
    if !defined?(pbAddDependency2) || !defined?(pbRemoveDependency2) ||
       !$PokemonTemp || !$PokemonTemp.respond_to?(:dependentEvents)
      pbMessage(_INTL("The follower system isn't available here."))
      return true
    end
    party = entry[:team]
    unless party.is_a?(Array) && party.any? { |p| p.respond_to?(:hp) && p.hp.to_i > 0 }
      pbMessage(_INTL("This trainer has no Pokémon ready to battle."))
      return true
    end
    follower_name = "HoennPartner_#{entry[:map_id]}_#{entry[:event_id]}"
    begin
      # The nil common event is intentional; KIF can follow without Hoenn's event 200.
      pbAddDependency2(event.id, follower_name, nil)
      unless $PokemonGlobal.dependentEvents.any? { |row| row && row[8] == follower_name }
        pbMessage(_INTL("Couldn't create the trainer follower."))
        return true
      end
      $PokemonGlobal.partner = [entry[:trainer_type], entry[:trainer_name],
                                entry[:trainer_version].to_i, party.map(&:clone)]
      $PokemonGlobal.hoenn_rematch_partner_key = [entry[:map_id], entry[:event_id]]
      hide_partner_original(event)
      pbMessage(_INTL("{1} joined you!", entry[:trainer_name]))
    rescue StandardError => e
      report(e)
      pbRemoveDependency2(follower_name) rescue nil
      $PokemonGlobal.partner = nil if $PokemonGlobal
      $PokemonGlobal.hoenn_rematch_partner_key = nil if $PokemonGlobal
      pbMessage(_INTL("Couldn't recruit this trainer here."))
    end
    true
  end

  def self.dismiss_partner
    key = partner_key
    return true unless key
    entry = contact(key[0], key[1])
    follower_name = "HoennPartner_#{key[0]}_#{key[1]}"
    pbRemoveDependency2(follower_name) if defined?(pbRemoveDependency2)
    $PokemonGlobal.partner = nil
    $PokemonGlobal.hoenn_rematch_partner_key = nil
    if $game_map && $game_map.map_id == key[0] && $game_map.events[key[1]]
      original = $game_map.events[key[1]]
      original.instance_variable_set(:@erased, false)
      original.transparent = false if original.respond_to?(:transparent=)
      original.through = false if original.respond_to?(:through=)
      original.refresh if original.respond_to?(:refresh)
    end
    pbMessage(_INTL("{1} headed home.", entry ? entry[:trainer_name] : _INTL("Your partner")))
    true
  rescue StandardError => e
    report(e)
    pbMessage(_INTL("Couldn't dismiss the partner safely."))
    true
  end

  def self.handle_event(event)
    # A recruited trainer's original map event must not duplicate the follower.
    return true if original_partner_event?(event)
    return false if @handling_interaction || !eligible_event?(event)
    map_id = $game_map.map_id
    entry = contact(map_id, event.id)
    identity = trainer_identity(event)
    record = existing_phone_contact(event)
    diagnose_trainer_event(event) if event.name.to_s.match?(/trainer/i)
    log("Trainer map=#{map_id} event=#{event.id} identity=#{identity ? identity[0,3].inspect : 'none'} defeated=#{identity ? defeated?(event, identity[3]) : false}") if event.name.to_s.match?(/trainer/i)
    if !entry && !identity && !record && trainer_trade_event?(event)
      # Unregistered trade trainers remain inaccessible until the bridge
      # can identify a real battle contact. Never fake a registration.
      pbMessage(_INTL("Let's get to know each other through battles before trading."))
      return true
    end
    return false unless entry || identity || record
    if !entry && !record
      unless identity && defeated?(event, identity[3])
        log("Not eligible yet: map=#{map_id} event=#{event.id} identity=#{!!identity} defeated=#{identity ? defeated?(event, identity[3]) : false}")
        return false
      end
    end
    @handling_interaction = true
    begin
      unless entry
        if record
          entry = register(record[1], record[2], identity ? identity[2] : 0, map_id, event.id)
        else
          entry = register(identity[0], identity[1], identity[2], map_id, event.id)
        end
        unless entry
          pbMessage(_INTL('Could not register this trainer.'))
          return true
        end
        # Let the trainer greet you before showing the new menu.
      end
      chat(entry, event)
      options = []
      options << _INTL('Rematch') if rematch_ready?(entry)
      options << _INTL('View Team')
      options << _INTL('Trade') if entry[:affinity].to_i >= TRADE_AFFINITY && entry[:team].is_a?(Array) && !entry[:team].empty?
      if partner_key == [entry[:map_id], entry[:event_id]]
        options << _INTL('Dismiss Partner')
      elsif entry[:affinity].to_i == PARTNER_AFFINITY && !partner_key &&
            $PokemonGlobal && !$PokemonGlobal.partner
        options << _INTL('Recruit Partner')
      end
      options << _INTL('Cancel')
      choice = HoennSuiteTrainerMenu.choose(options)
      case options[choice]
      when _INTL('View Team')
        view_team(entry)
      when _INTL('Rematch')
        if pbConfirmMessage(_INTL('Battle {1} again?', entry[:trainer_name]))
          won = with_rematch_team(entry) do
            pbTrainerBattle(entry[:trainer_type], entry[:trainer_name], nil, false,
                            entry[:trainer_version])
          end
          record_rematch(entry, won)
        end
        true
      when _INTL('Trade')
        trade_with_trainer(entry)
      when _INTL('Recruit Partner')
        recruit_partner(entry, event)
      when _INTL('Dismiss Partner')
        dismiss_partner
      else
        true
      end
    ensure
      @handling_interaction = false
    end
  rescue StandardError => e
    report(e)
    false
  end

end

# A contact menu appears before an existing phone trainer's original event.
# Choosing 'Talk normally' runs the vanilla event unchanged.
if defined?(Game_Event)
  module HoennTrainerEventBridge
    def start(*args)
      return if HoennTrainerRematches.handle_event(self)
      super
    end
  end
  Game_Event.prepend(HoennTrainerEventBridge) unless Game_Event.ancestors.include?(HoennTrainerEventBridge)
end

# Trainer data is cloned; original game trainer records are never changed.
module HoennTrainerTeamBridge
  def pbLoadTrainer(tr_type, tr_name, tr_version = 0)
    trainer = super
    entry = HoennTrainerRematches.active_rematch
    return trainer unless entry && trainer && trainer.respond_to?(:party)
    return trainer unless entry[:trainer_type] == tr_type &&
                          entry[:trainer_name] == tr_name &&
                          entry[:trainer_version].to_i == tr_version.to_i
    saved_team = entry[:team]
    return trainer unless saved_team.is_a?(Array) && !saved_team.empty?
    trainer.party = saved_team.map(&:clone) if trainer.respond_to?(:party=)
    trainer
  end
end
Object.prepend(HoennTrainerTeamBridge) unless Object.ancestors.include?(HoennTrainerTeamBridge)

# KIF's old trade bubble is tied to scripted trade pages.
# Registered trainers use affinity trades instead, so hide that old marker.
if defined?(Game_Event)
  module HoennTrainerTradeIconBridge
    def detectTradeIcon(event)
      if event && HoennTrainerRematches.eligible_event?(event)
        registered = HoennTrainerRematches.contact($game_map.map_id, event.id)
        identity = HoennTrainerRematches.trainer_identity(event) unless registered
        if registered || (identity && HoennTrainerRematches.defeated?(event, identity[3]))
          return nil
        end
      end
      super
    end
  end
  Game_Event.prepend(HoennTrainerTradeIconBridge) unless Game_Event.ancestors.include?(HoennTrainerTradeIconBridge)
end

# Re-hide the original trainer when their home map reloads.
if defined?(Game_Event)
  module HoennPartnerOriginalVisibility
    def refresh(*args)
      result = super
      HoennTrainerRematches.hide_partner_original(self)
      result
    end
  end
  Game_Event.prepend(HoennPartnerOriginalVisibility) unless Game_Event.ancestors.include?(HoennPartnerOriginalVisibility)
end

# The follower is a dependent event, not a normal map event.
# Check the facing tile before KIF tries to talk to a map NPC.
if defined?(Game_Player)
  module HoennPartnerFollowerTalk
    def check_event_trigger_there(triggers)
      if triggers.include?(0) && HoennTrainerRematches.partner_follower_in_front?(self)
        return HoennTrainerRematches.partner_follower_menu
      end
      super
    end
  end
  Game_Player.prepend(HoennPartnerFollowerTalk) unless Game_Player.ancestors.include?(HoennPartnerFollowerTalk)
end
