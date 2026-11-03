#==============================================================================
# Kanto Reloaded Double Abilities
#==============================================================================
# Owns persistent ability-pair data and feature-level compatibility policy.
#==============================================================================

module KantoReloaded
  module DoubleAbilities
    SETTING_KEY = :double_abilities
    DATA_VERSION = 1
    CAPABILITY_ID = :kanto_reloaded_double_abilities
    CAPABILITY_VERSION = 1

    AS_ONE_VARIANTS = [:ASONE, :ASONEGLASTRIER, :ASONESPECTRIER].freeze

    class << self
      def install
        register_setting
        register_setting_callback
        log_info("Installed Double Abilities data and settings layer")
        true
      rescue StandardError => e
        log_exception("Double Abilities data install failed", e)
        false
      end

      def enabled?
        value = KantoReloaded::Settings.get(SETTING_KEY, 0)
        setting_on = value == true || (value.respond_to?(:to_i) && value.to_i == 1)
        setting_on && !native_system_enabled?
      rescue
        false
      end

      # cody's KIF: Elite Redux (Mods/KIF-ER) runs a fusion's 2nd ability
      # itself while it's On: its own picker after fusing, the Ability
      # Capsules, its Summary tab, and in battle (it switches Legacy off per
      # battler). Legacy then stands down there and only stays On, since ER
      # counts a fusion as dual while this switch is On.
      def kif_er_active?
        defined?(::KIFER) && ::KIFER.respond_to?(:enabled?) && ::KIFER.enabled?
      rescue
        false
      end

      def kif_er_owns?(pokemon)
        kif_er_active? && ::KIFER.respond_to?(:dual?) && ::KIFER.dual?(pokemon)
      rescue
        false
      end

      def runtime_config_version
        @runtime_config_version ||= 0
      end

      def invalidate_runtime_config!
        @runtime_config_version = runtime_config_version + 1
      end

      def capability
        {
          :id => CAPABILITY_ID,
          :version => CAPABILITY_VERSION,
          :enabled => enabled?
        }
      end

      def native_system_enabled?
        return false unless defined?(SWITCH_DOUBLE_ABILITIES)
        return false unless defined?($game_switches) && $game_switches
        !!$game_switches[SWITCH_DOUBLE_ABILITIES]
      rescue
        false
      end

      def family_pokemon?(pokemon)
        return false unless pokemon
        return true if pokemon.respond_to?(:has_family?) && pokemon.has_family?
        raw_family = pokemon.instance_variable_get(:@family)
        raw_subfamily = pokemon.instance_variable_get(:@subfamily)
        !raw_family.nil? && !raw_subfamily.nil?
      rescue
        false
      end

      def initialized?(pokemon)
        return false unless pokemon
        pokemon.instance_variable_get(:@kr_double_abilities_version).to_i > 0
      rescue
        false
      end

      def eligible_pokemon?(pokemon)
        enabled? &&
          initialized?(pokemon) &&
          !family_pokemon?(pokemon) &&
          component_data(pokemon).length >= 2
      rescue
        false
      end

      def multiplayer_compatible?
        return true unless multiplayer_battle_active?
        if defined?(KantoReloadedMultiplayerCapabilities) &&
           KantoReloadedMultiplayerCapabilities.respond_to?(:all_support?)
          return !!KantoReloadedMultiplayerCapabilities.all_support?(
            CAPABILITY_ID,
            CAPABILITY_VERSION
          )
        end
        false
      rescue
        false
      end

      def primary_id(pokemon)
        return nil unless pokemon
        value = pokemon.ability_id
        ability_id(value)
      rescue
        nil
      end

      def secondary_id(pokemon)
        return nil unless initialized?(pokemon)
        ability_id(pokemon.instance_variable_get(:@ability2))
      rescue
        nil
      end

      def secondary_ability(pokemon)
        id = secondary_id(pokemon)
        id ? GameData::Ability.try_get(id) : nil
      rescue
        nil
      end

      def active_pair(pokemon)
        ids = [primary_id(pokemon)]
        ids << secondary_id(pokemon) if eligible_pokemon?(pokemon)
        ids.compact
      end

      def pair_legal?(first, second)
        first_id = ability_id(first)
        second_id = ability_id(second)
        return true if second_id.nil?
        return false if first_id.nil? || first_id == second_id
        !as_one_duplicate?(first_id, second_id)
      rescue
        false
      end

      def hard_blacklist_reason(first, second)
        first_id = ability_id(first)
        second_id = ability_id(second)
        return "Abilities must be different." if first_id && first_id == second_id
        return "Only one As One variant can be active." if as_one_duplicate?(first_id, second_id)
        nil
      rescue
        "That ability pair is not available."
      end

      def component_data(pokemon)
        return [] unless pokemon
        if pokemon.respond_to?(:species1) &&
           pokemon.respond_to?(:species2) &&
           pokemon.respond_to?(:species3)
          return [
            GameData::Species.get(pokemon.species1),
            GameData::Species.get(pokemon.species2),
            GameData::Species.get(pokemon.species3)
          ].compact
        end
        return [] unless pokemon.respond_to?(:isFusion?) && pokemon.isFusion?
        body = pokemon.respond_to?(:body_id) ? pokemon.body_id : nil
        head = pokemon.respond_to?(:head_id) ? pokemon.head_id : nil
        [body, head].compact.map { |id| GameData::Species.get(id) }
      rescue
        []
      end

      def component_pools(pokemon, include_hidden = true)
        component_data(pokemon).map do |data|
          values = normal_abilities(data)
          values += hidden_abilities(data) if include_hidden
          values.compact.uniq
        end
      end

      def component_snapshot(pokemon)
        component_data(pokemon).dup
      rescue
        []
      end

      def component_signature(components)
        Array(components).map do |data|
          id = data.respond_to?(:id) ? data.id : data
          [id, normal_abilities(data), hidden_abilities(data)]
        end
      rescue
        []
      end

      def normal_abilities(data)
        Array(data && data.abilities).map { |value| ability_id(value) }.compact.uniq
      rescue
        []
      end

      def hidden_abilities(data)
        Array(data && data.hidden_abilities).map { |value| ability_id(value) }.compact.uniq
      rescue
        []
      end

      def legal_slot_choices(pokemon, slot, include_hidden = false)
        return [] unless initialized?(pokemon)
        source_index = source_index_for(pokemon, slot)
        pools = component_pools(pokemon, include_hidden)
        source_pool = pools[source_index] || pools.flatten
        other = slot.to_i == 2 ? primary_id(pokemon) : secondary_id(pokemon)
        source_pool.select { |id| pair_legal_for_slot?(slot, id, other) }.uniq
      rescue
        []
      end

      def hidden_slot_choices(pokemon, slot)
        data = component_data(pokemon)
        source_index = source_index_for(pokemon, slot)
        candidates = hidden_abilities(data[source_index])
        other = slot.to_i == 2 ? primary_id(pokemon) : secondary_id(pokemon)
        candidates.select { |id| pair_legal_for_slot?(slot, id, other) }
      rescue
        []
      end

      def initialize_generated!(pokemon, options = {})
        return false unless enabled?
        return false if family_pokemon?(pokemon)
        components = component_data(pokemon)
        return false if components.length < 2

        primary = primary_id(pokemon)
        return false unless primary
        personal_id = pokemon.respond_to?(:personalID) ? pokemon.personalID.to_i : 0
        source_candidates = []
        components.each_with_index do |data, index|
          pool = normal_abilities(data) + hidden_abilities(data)
          source_candidates << index if pool.include?(primary)
        end
        primary_source = source_candidates.empty? ?
          personal_id % components.length :
          source_candidates[personal_id % source_candidates.length]
        secondary_sources = (0...components.length).to_a.reject { |index| index == primary_source }
        secondary_sources = rotate_stably(secondary_sources, personal_id >> 1)

        secondary = nil
        secondary_source = nil
        secondary_sources.each do |index|
          candidates = rotate_stably(normal_abilities(components[index]), personal_id >> 2)
          secondary = candidates.find { |id| pair_legal?(primary, id) }
          if secondary
            secondary_source = index
            break
          end
        end

        mark_initialized!(pokemon, primary_source, secondary_source)
        write_secondary!(pokemon, secondary, secondary_source)
        refresh_stats(pokemon)
        log_debug_pair(pokemon, options[:reason] || :generated)
        true
      rescue StandardError => e
        log_exception("Failed to initialize generated fusion abilities", e)
        false
      end

      def repair_invalid_pair!(pokemon, reason = :invalid_pair)
        return false unless enabled? && initialized?(pokemon)
        return false if family_pokemon?(pokemon)
        components = component_data(pokemon)
        return false if components.length < 2

        first = primary_id(pokemon)
        second = secondary_id(pokemon)
        return false if first && second && pair_legal?(first, second)
        return initialize_generated!(pokemon, :reason => reason) unless first

        primary_source = normalized_source_index(
          source_index_for(pokemon, 1), components.length, 0
        )
        secondary_source = normalized_source_index(
          source_index_for(pokemon, 2),
          components.length,
          [1, components.length - 1].min
        )
        source_order = [secondary_source]
        source_order.concat((0...components.length).to_a)
        replacement = nil
        replacement_source = nil
        source_order.uniq.each do |index|
          pool = normal_abilities(components[index])
          pool.concat(hidden_abilities(components[index]))
          replacement = pool.compact.uniq.find do |candidate|
            pair_legal?(first, candidate)
          end
          if replacement
            replacement_source = index
            break
          end
        end

        return false if replacement.nil? && second.nil?

        result = assign_pair!(
          pokemon,
          first,
          replacement,
          [primary_source, replacement_source]
        )
        log_warning(
          "Repaired invalid Double Abilities pair for #{pokemon.species}: " \
          "#{first.inspect}/#{second.inspect} -> " \
          "#{first.inspect}/#{replacement.inspect} (#{reason})"
        ) if result
        result
      rescue StandardError => e
        log_exception("Failed to repair invalid fusion ability pair", e)
        false
      end

      def reconcile_evolution!(pokemon, previous_components,
                               previous_pair = nil)
        return false unless initialized?(pokemon)
        return false if family_pokemon?(pokemon)
        current_components = component_data(pokemon)
        return clear_for_single!(pokemon) if current_components.length < 2

        previous = Array(previous_components)
        primary_source = normalized_source_index(
          source_index_for(pokemon, 1),
          current_components.length,
          0
        )
        secondary_source = normalized_source_index(
          source_index_for(pokemon, 2),
          current_components.length,
          [1, current_components.length - 1].min
        )
        native_primary = primary_id(pokemon)
        native_secondary = secondary_id(pokemon)
        prior_ids = Array(previous_pair)
        previous_primary = ability_id(prior_ids[0]) || native_primary
        previous_secondary = if prior_ids.length >= 2
                               ability_id(prior_ids[1])
                             else
                               native_secondary
                             end
        primary_choices = evolution_slot_preferences(
          previous[primary_source],
          current_components[primary_source],
          previous_primary
        )
        secondary_choices = evolution_slot_preferences(
          previous[secondary_source],
          current_components[secondary_source],
          previous_secondary
        )
        secondary_choices = [nil] if secondary_choices.empty?
        return false if primary_choices.empty?

        legal_pairs = []
        primary_choices.each_with_index do |first, first_index|
          secondary_choices.each_with_index do |second, second_index|
            next unless pair_legal?(first, second)
            changes = 0
            changes += 1 if first != previous_primary
            changes += 1 if second != previous_secondary
            legal_pairs << [
              changes,
              first_index + second_index,
              first_index,
              second_index,
              first,
              second
            ]
          end
        end

        selected = legal_pairs.min_by { |entry| entry[0, 4] }
        first = selected ? selected[4] : primary_choices[0]
        second = selected ? selected[5] : nil
        changed = first != native_primary || second != native_secondary
        result = assign_pair!(
          pokemon,
          first,
          second,
          [primary_source, secondary_source]
        )
        log_debug_pair(pokemon, :fusion_evolved) if result && changed
        result
      rescue StandardError => e
        log_exception("Failed to reconcile evolved fusion abilities", e)
        false
      end

      def assign_pair!(pokemon, first, second, sources = nil)
        return false unless pokemon
        return false if family_pokemon?(pokemon)
        first_id = ability_id(first)
        second_id = ability_id(second)
        return false unless first_id && pair_legal?(first_id, second_id)

        source_values = Array(sources)
        primary_source = source_values[0]
        secondary_source = source_values[1]
        pokemon.instance_variable_set(:@ability, first_id)
        primary_index = primary_source.nil? ?
          ability_index_for(pokemon, first_id) :
          ability_index_for_source(pokemon, first_id, primary_source)
        pokemon.instance_variable_set(:@ability_index, primary_index)
        mark_initialized!(pokemon, primary_source, secondary_source)
        write_secondary!(pokemon, second_id, secondary_source)
        refresh_stats(pokemon)
        true
      rescue StandardError => e
        log_exception("Failed to assign fusion ability pair", e)
        false
      end

      def assign_slot!(pokemon, slot, ability)
        return false unless eligible_pokemon?(pokemon)
        id = ability_id(ability)
        return false unless id
        first = slot.to_i == 1 ? id : primary_id(pokemon)
        second = slot.to_i == 2 ? id : secondary_id(pokemon)
        return false unless pair_legal?(first, second)

        if slot.to_i == 1
          pokemon.instance_variable_set(:@ability, id)
          pokemon.instance_variable_set(
            :@ability_index,
            ability_index_for_source(pokemon, id, source_index_for(pokemon, 1))
          )
        else
          write_secondary!(pokemon, id, source_index_for(pokemon, 2))
        end
        refresh_stats(pokemon)
        true
      rescue StandardError => e
        log_exception("Failed to assign Double Abilities slot", e)
        false
      end

      def clear_secondary!(pokemon)
        return false unless initialized?(pokemon)
        return false if family_pokemon?(pokemon)
        write_secondary!(
          pokemon,
          nil,
          pokemon.instance_variable_get(:@kr_double_ability_secondary_source)
        )
        refresh_stats(pokemon)
        true
      rescue
        false
      end

      def clear_for_single!(pokemon)
        return false unless initialized?(pokemon)
        return false if component_data(pokemon).length >= 2
        pokemon.instance_variable_set(:@ability2, nil)
        pokemon.instance_variable_set(:@ability2_index, nil)
        clear_metadata!(pokemon)
        refresh_stats(pokemon)
        true
      rescue
        false
      end

      def restore_from_json!(pokemon, json)
        data = json.is_a?(Hash) ? json : {}
        version = data["kr_double_abilities_version"] || data[:kr_double_abilities_version]
        unless version.to_i > 0
          clear_metadata!(pokemon)
          return false
        end
        pokemon.instance_variable_set(:@kr_double_abilities_version, version.to_i)
        pokemon.instance_variable_set(
          :@kr_double_ability_primary_source,
          data["kr_double_ability_primary_source"] || data[:kr_double_ability_primary_source]
        )
        pokemon.instance_variable_set(
          :@kr_double_ability_secondary_source,
          data["kr_double_ability_secondary_source"] || data[:kr_double_ability_secondary_source]
        )
        true
      rescue
        clear_metadata!(pokemon)
        false
      end

      def add_json_fields(pokemon, json)
        return json unless json.is_a?(Hash)
        json["kr_double_abilities_version"] =
          pokemon.instance_variable_get(:@kr_double_abilities_version)
        json["kr_double_ability_primary_source"] =
          pokemon.instance_variable_get(:@kr_double_ability_primary_source)
        json["kr_double_ability_secondary_source"] =
          pokemon.instance_variable_get(:@kr_double_ability_secondary_source)
        json
      rescue
        json
      end

      def source_index_for(pokemon, slot)
        key = slot.to_i == 2 ?
          :@kr_double_ability_secondary_source :
          :@kr_double_ability_primary_source
        value = pokemon.instance_variable_get(key)
        return value.to_i unless value.nil?
        0
      rescue
        0
      end

      def ability_name(value)
        data = GameData::Ability.try_get(value)
        data ? data.name : value.to_s
      rescue
        value.to_s
      end

      private

      def register_setting
        KantoReloaded::Settings.register(SETTING_KEY, {
          :name => "Double Abilities",
          :description => "Gives newly created fusion Pokemon two active abilities.",
          :type => :toggle,
          :category => :gameplay,
          :owner => :double_abilities,
          :value_style => :integer,
          :default => 0,
          :priority => 1000
        })
      end

      def register_setting_callback
        KantoReloaded::Settings.register_on_change(
          SETTING_KEY,
          :double_abilities_native_isolation,
          :owner => :double_abilities
        ) do |value, old_value, _definition|
          invalidate_runtime_config!
          value_on = value == true || (value.respond_to?(:to_i) && value.to_i == 1)
          old_on = old_value == true ||
            (old_value.respond_to?(:to_i) && old_value.to_i == 1)
          next unless value_on && !old_on
          next unless native_system_enabled?
          accepted = false
          if defined?(KantoReloaded::PopupWindow)
            accepted = KantoReloaded::PopupWindow.confirm(
              "KIF Double Abilities is already active. Disable KIF's system and use Kanto Reloaded Double Abilities instead?",
              :serious => true,
              :default => false
            )
          end
          if accepted
            $game_switches[SWITCH_DOUBLE_ABILITIES] = false
            log_info("Disabled KIF Double Abilities before enabling KR Double Abilities")
          else
            KantoReloaded::Settings.set(SETTING_KEY, 0, :notify => false)
            log_warning("KR Double Abilities remained disabled because KIF Double Abilities is active")
          end
        end
      end

      def mark_initialized!(pokemon, primary_source, secondary_source)
        pokemon.instance_variable_set(:@kr_double_abilities_version, DATA_VERSION)
        pokemon.instance_variable_set(:@kr_double_ability_primary_source, primary_source)
        pokemon.instance_variable_set(:@kr_double_ability_secondary_source, secondary_source)
      end

      def clear_metadata!(pokemon)
        pokemon.instance_variable_set(:@kr_double_abilities_version, nil)
        pokemon.instance_variable_set(:@kr_double_ability_primary_source, nil)
        pokemon.instance_variable_set(:@kr_double_ability_secondary_source, nil)
      end

      def write_secondary!(pokemon, ability, source_index)
        id = ability_id(ability)
        pokemon.instance_variable_set(:@ability2, id)
        pokemon.instance_variable_set(
          :@ability2_index,
          id ? ability_index_for_source(pokemon, id, source_index) : nil
        )
        pokemon.instance_variable_set(:@kr_double_ability_secondary_source, source_index)
      end

      def ability_index_for(pokemon, ability)
        list = pokemon.respond_to?(:getAbilityList) ? Array(pokemon.getAbilityList) : []
        entry = list.find { |candidate| ability_id(candidate[0]) == ability_id(ability) }
        entry ? entry[1] : nil
      rescue
        nil
      end

      def ability_index_for_source(pokemon, ability, source_index)
        data = component_data(pokemon)[source_index.to_i]
        return nil unless data
        normal = normal_abilities(data)
        hidden = hidden_abilities(data)
        normal_index = normal.index(ability_id(ability))
        return normal_index if normal_index
        hidden_index = hidden.index(ability_id(ability))
        hidden_index ? hidden_index + 2 : nil
      rescue
        nil
      end

      def pair_legal_for_slot?(slot, candidate, other)
        slot.to_i == 1 ? pair_legal?(candidate, other) : pair_legal?(other, candidate)
      end

      def evolution_slot_preferences(previous_data, current_data, current_ability)
        current_id = ability_id(current_ability)
        new_normal = normal_abilities(current_data)
        new_hidden = hidden_abilities(current_data)
        available = (new_normal + new_hidden).compact.uniq
        return [] if available.empty?

        preferences = []
        preferences << current_id if available.include?(current_id)
        old_normal = normal_abilities(previous_data)
        old_hidden = hidden_abilities(previous_data)
        normal_index = old_normal.index(current_id)
        hidden_index = old_hidden.index(current_id)
        if normal_index
          preferences << new_normal[normal_index]
          preferences.concat(new_normal)
          preferences.concat(new_hidden)
        elsif hidden_index
          preferences << new_hidden[hidden_index]
          preferences.concat(new_hidden)
          preferences.concat(new_normal)
        else
          preferences.concat(new_normal)
          preferences.concat(new_hidden)
        end
        preferences.compact.uniq
      rescue
        []
      end

      def normalized_source_index(value, length, fallback)
        index = value.nil? ? fallback.to_i : value.to_i
        return fallback.to_i if index < 0 || index >= length.to_i
        index
      rescue
        fallback.to_i
      end

      def ability_id(value)
        data = GameData::Ability.try_get(value)
        data ? data.id : nil
      rescue
        nil
      end

      def as_one_duplicate?(first, second)
        AS_ONE_VARIANTS.include?(first) && AS_ONE_VARIANTS.include?(second)
      end

      def rotate_stably(values, seed)
        array = Array(values).dup
        return array if array.length < 2
        offset = seed.to_i % array.length
        array.rotate(offset)
      end

      def refresh_stats(pokemon)
        pokemon.calc_stats if pokemon.respond_to?(:calc_stats)
      rescue
        nil
      end

      def multiplayer_battle_active?
        if defined?(CoopBattleState) && CoopBattleState.respond_to?(:in_coop_battle?)
          return true if CoopBattleState.in_coop_battle?
        end
        if defined?(MultiplayerClient) && MultiplayerClient.respond_to?(:in_battle?)
          return true if MultiplayerClient.in_battle?
        end
        false
      rescue
        false
      end

      def log_debug_pair(pokemon, reason)
        return unless defined?(KantoReloaded::Log)
        first = primary_id(pokemon)
        second = secondary_id(pokemon)
        KantoReloaded::Log.debug(
          "Double Abilities initialized #{pokemon.species}: #{first.inspect}/#{second.inspect} (#{reason})",
          :modules
        )
      rescue
        nil
      end

      def log_info(message)
        KantoReloaded::Log.info(message, :modules) if defined?(KantoReloaded::Log)
      end

      def log_warning(message)
        KantoReloaded::Log.warning(message, :modules) if defined?(KantoReloaded::Log)
      end

      def log_exception(message, error)
        KantoReloaded::Log.exception(message, error, channel: :modules) if defined?(KantoReloaded::Log)
      end
    end
  end
end

KantoReloaded::DoubleAbilities.install
