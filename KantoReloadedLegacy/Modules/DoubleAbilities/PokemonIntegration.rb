#==============================================================================
# Kanto Reloaded Double Abilities - Pokemon Integration
#==============================================================================

module KantoReloaded
  module DoubleAbilities
    module PokemonIntegration
      class << self
        def install
          return false unless defined?(KantoReloaded::Hooks)
          results = []
          results << install_pokemon_hooks
          results << install_battler_hooks
          results << install_generation_hooks
          results << install_evolution_hook
          results << install_unfusion_hook
          results.all?
        rescue StandardError => e
          KantoReloaded::Log.exception(
            "Double Abilities Pokemon integration failed",
            e,
            channel: :modules
          ) if defined?(KantoReloaded::Log)
          false
        end

        private

        def install_pokemon_hooks
          return false unless defined?(::Pokemon)
          hooks = []
          hooks << KantoReloaded::Hooks.wrap(
            ::Pokemon,
            :initialize,
            :double_abilities_new_pokemon
          ) do |hook, *arguments|
            result = hook.call
            KantoReloaded::DoubleAbilities.initialize_generated!(
              self,
              :reason => :pokemon_created
            )
            result
          end
          # (Pokemon#as_json / #load_json were old KIF's; KIF's PokeIO already
          # carries the Double Abilities fields)
          hooks << KantoReloaded::Hooks.wrap(
            ::Pokemon,
            :species=,
            :double_abilities_species_transition
          ) do |hook, species|
            previous_components =
              KantoReloaded::DoubleAbilities.component_snapshot(self)
            previous_signature =
              KantoReloaded::DoubleAbilities.component_signature(
                previous_components
              )
            previous_pair = [
              KantoReloaded::DoubleAbilities.primary_id(self),
              KantoReloaded::DoubleAbilities.secondary_id(self)
            ]
            had_pair = previous_components.length >= 2
            result = hook.call
            current_components =
              KantoReloaded::DoubleAbilities.component_snapshot(self)
            current_signature =
              KantoReloaded::DoubleAbilities.component_signature(
                current_components
              )
            has_pair = current_components.length >= 2
            transitioned = previous_signature != current_signature
            if transitioned
              generation = instance_variable_get(
                :@kr_double_ability_species_transition_generation
              ).to_i
              instance_variable_set(
                :@kr_double_ability_species_transition_generation,
                generation + 1
              )
            end
            if !had_pair && has_pair
              KantoReloaded::DoubleAbilities.initialize_generated!(
                self,
                :reason => :fusion_species_created
              )
            elsif had_pair && !has_pair
              KantoReloaded::DoubleAbilities.clear_for_single!(self)
            elsif had_pair && has_pair && transitioned
              KantoReloaded::DoubleAbilities.reconcile_evolution!(
                self,
                previous_components,
                previous_pair
              )
            end
            result
          end
          hooks << KantoReloaded::Hooks.wrap(
            ::Pokemon,
            :ability2_id,
            :double_abilities_pokemon_ability2_id,
            :reattach => true
          ) do |hook, *arguments|
            if KantoReloaded::DoubleAbilities.eligible_pokemon?(self)
              KantoReloaded::DoubleAbilities.secondary_id(self)
            else
              hook.call
            end
          end
          hooks << KantoReloaded::Hooks.wrap(
            ::Pokemon,
            :ability2,
            :double_abilities_pokemon_ability2,
            :reattach => true
          ) do |hook, *arguments|
            if KantoReloaded::DoubleAbilities.eligible_pokemon?(self)
              KantoReloaded::DoubleAbilities.secondary_ability(self)
            else
              hook.call
            end
          end
          hooks << KantoReloaded::Hooks.wrap(
            ::Pokemon,
            :hasAbility?,
            :double_abilities_pokemon_has_ability,
            :reattach => true
          ) do |hook, check_ability = nil|
            result = hook.call
            next result if result || check_ability.nil?
            secondary = KantoReloaded::DoubleAbilities.secondary_id(self)
            checked = GameData::Ability.try_get(check_ability)
            KantoReloaded::DoubleAbilities.eligible_pokemon?(self) &&
              secondary &&
              checked &&
              secondary == checked.id
          end
          if ::Pokemon.method_defined?(:isAirborne?)
            hooks << KantoReloaded::Hooks.wrap(
              ::Pokemon,
              :isAirborne?,
              :double_abilities_pokemon_airborne
            ) do |hook, *arguments|
              result = hook.call
              next true if result
              item = respond_to?(:item_id) ?
                item_id :
                instance_variable_get(:@item)
              next false if item == :IRONBALL
              hasAbility?(:LEVITATE)
            end
          end
          hooks << KantoReloaded::Hooks.wrap(
            ::Pokemon,
            :ability2=,
            :double_abilities_pokemon_ability2_writer
          ) do |hook, value|
            if KantoReloaded::DoubleAbilities.eligible_pokemon?(self)
              if value.nil?
                KantoReloaded::DoubleAbilities.clear_secondary!(self)
                next nil
              end
              KantoReloaded::DoubleAbilities.assign_slot!(self, 2, value)
              value
            else
              hook.call
            end
          end
          hooks << KantoReloaded::Hooks.wrap(
            ::Pokemon,
            :ability2_index,
            :double_abilities_pokemon_ability2_index
          ) do |hook, *arguments|
            if KantoReloaded::DoubleAbilities.eligible_pokemon?(self)
              instance_variable_get(:@ability2_index)
            else
              hook.call
            end
          end
          hooks << KantoReloaded::Hooks.wrap(
            ::Pokemon,
            :ability=,
            :double_abilities_pokemon_primary_writer
          ) do |hook, value|
            if KantoReloaded::DoubleAbilities.eligible_pokemon?(self) && !value.nil?
              proposed = GameData::Ability.try_get(value)
              proposed_id = proposed ? proposed.id : nil
              second = KantoReloaded::DoubleAbilities.secondary_id(self)
              unless proposed_id &&
                     KantoReloaded::DoubleAbilities.pair_legal?(proposed_id, second)
                result = hook.call
                KantoReloaded::DoubleAbilities.initialize_generated!(
                  self,
                  :reason => :primary_ability_changed
                )
                next result
              end
            end
            hook.call
          end
          hooks << KantoReloaded::Hooks.wrap(
            ::Pokemon,
            :adjustHPForWonderGuard,
            :double_abilities_wonder_guard_hp
          ) do |hook, stats|
            result = hook.call
            pair = KantoReloaded::DoubleAbilities.active_pair(self)
            pair.include?(:WONDERGUARD) ? 1 : result
          end
          hooks.all?
        end

        def install_battler_hooks
          return false unless defined?(::PokeBattle_Battler)
          hooks = []
          hooks << KantoReloaded::Hooks.wrap(
            ::PokeBattle_Battler,
            :pbInitPokemon,
            :double_abilities_battler_sync,
            :reattach => true
          ) do |hook, pokemon, *arguments|
            KantoReloaded::DoubleAbilities.repair_invalid_pair!(
              pokemon,
              :battle_sync
            )
            result = hook.call
            KantoReloaded::DoubleAbilities::BattleRuntime.sync_battler(self, pokemon)
            result
          end
          hooks << KantoReloaded::Hooks.wrap(
            ::PokeBattle_Battler,
            :ability,
            :double_abilities_owner_capture
          ) do |hook, *arguments|
            result = hook.call
            KantoReloaded::DoubleAbilities::BattleRuntime.capture_ability_owner(self, result)
            result
          end
          hooks << KantoReloaded::Hooks.wrap(
            ::PokeBattle_Battler,
            :ability=,
            :double_abilities_battler_ability_writer
          ) do |hook, value|
            runtime = KantoReloaded::DoubleAbilities::BattleRuntime
            if runtime.eligible_battler?(self) && !value.nil?
              slot = runtime.triggering_slot(self) == 2 ? 2 : 1
              next value if runtime.assign_battle_slot!(self, slot, value)
              key = slot == 2 ? :@ability2_id : :@ability_id
              next instance_variable_get(key)
            end
            hook.call
          end
          hooks << KantoReloaded::Hooks.wrap(
            ::PokeBattle_Battler,
            :ability2,
            :double_abilities_battler_ability2,
            :reattach => true
          ) do |hook, *arguments|
            if KantoReloaded::DoubleAbilities::BattleRuntime.eligible_battler?(self)
              KantoReloaded::DoubleAbilities::BattleRuntime.secondary_ability(self)
            else
              hook.call
            end
          end
          hooks << KantoReloaded::Hooks.wrap(
            ::PokeBattle_Battler,
            :ability2Name,
            :double_abilities_battler_ability2_name
          ) do |hook, *arguments|
            ability = KantoReloaded::DoubleAbilities::BattleRuntime.secondary_ability(self)
            ability ? ability.name : hook.call
          end
          hooks << KantoReloaded::Hooks.wrap(
            ::PokeBattle_Battler,
            :abilityName,
            :double_abilities_battler_ability_name,
            :reattach => true
          ) do |hook, *arguments|
            runtime = KantoReloaded::DoubleAbilities::BattleRuntime
            if runtime.triggering_slot(self) == 2
              ability = runtime.secondary_ability(self)
              next ability.name if ability
            end
            announced = runtime.splash_ability(self)
            next announced.name if announced
            pending = runtime.pending_splash
            if pending && pending[:battler] == self
              ability = GameData::Ability.try_get(pending[:ability])
              next ability.name if ability
            end
            hook.call
          end
          hooks << install_active_ability_hook(:hasActiveAbility?)
          hooks << install_active_ability_hook(:hasWorkingAbility)
          hooks.all?
        end

        def install_active_ability_hook(method_name)
          KantoReloaded::Hooks.wrap(
            ::PokeBattle_Battler,
            method_name,
            :"double_abilities_#{method_name}",
            :reattach => true
          ) do |hook, check_ability, *arguments|
            runtime = KantoReloaded::DoubleAbilities::BattleRuntime
            result = hook.call
            if result
              runtime.clear_pending_splash(self)
              next result
            end
            mold_broken = arguments.length >= 2 && arguments[1]
            next false if mold_broken
            next false unless runtime.secondary_active?(self, arguments[0])
            matched = runtime.check_includes?(
              check_ability,
              runtime.secondary_id(self)
            )
            if matched
              runtime.mark_pending_splash(
                self,
                runtime.secondary_id(self),
                2
              )
            else
              runtime.clear_pending_splash(self)
            end
            matched
          end
        end

        def install_generation_hooks
          return true unless defined?(GameData::Trainer)
          KantoReloaded::Hooks.wrap(
            GameData::Trainer,
            :to_trainer,
            :double_abilities_trainer_generation
          ) do |hook, *arguments|
            trainer = hook.call
            party = trainer && trainer.respond_to?(:party) ? trainer.party : []
            Array(party).each do |pokemon|
              next unless KantoReloaded::DoubleAbilities.initialized?(pokemon)
              KantoReloaded::DoubleAbilities.initialize_generated!(
                pokemon,
                :reason => :trainer_generated
              )
            end
            trainer
          end
        end

        def install_evolution_hook
          scenes = []
          if defined?(::PokemonEvolutionScene) &&
             ::PokemonEvolutionScene.method_defined?(:pbEvolutionSuccess)
            scenes << [
              ::PokemonEvolutionScene,
              :pbEvolutionSuccess,
              :double_abilities_evolution_result,
              true
            ]
          end
          if defined?(::PokemonEvolutionSceneEBDX)
            method_name = if ::PokemonEvolutionSceneEBDX.method_defined?(:createEvolved)
                            :createEvolved
                          elsif ::PokemonEvolutionSceneEBDX.method_defined?(:pbEvolutionSuccess)
                            :pbEvolutionSuccess
                          end
            if method_name
              scenes << [
                ::PokemonEvolutionSceneEBDX,
                method_name,
                :double_abilities_ebdx_evolution_result,
                method_name == :pbEvolutionSuccess
              ]
            end
          end
          return true if scenes.empty?
          scenes.uniq { |entry| [entry[0], entry[1]] }.all? do |entry|
            scene_class, method_name, hook_id, supports_reversing = entry
            KantoReloaded::Hooks.wrap(
              scene_class,
              method_name,
              hook_id
            ) do |hook, *arguments|
              pokemon = instance_variable_get(:@pokemon)
              previous_components =
                KantoReloaded::DoubleAbilities.component_snapshot(pokemon)
              previous_pair = [
                KantoReloaded::DoubleAbilities.primary_id(pokemon),
                KantoReloaded::DoubleAbilities.secondary_id(pokemon)
              ]
              transition_generation = pokemon.instance_variable_get(
                :@kr_double_ability_species_transition_generation
              ).to_i
              result = hook.call
              reversing = supports_reversing && arguments[0] == true
              if reversing
                KantoReloaded::DoubleAbilities.initialize_generated!(
                  pokemon,
                  :reason => :fusion_reversed
                )
              elsif pokemon.instance_variable_get(
                :@kr_double_ability_species_transition_generation
              ).to_i == transition_generation
                KantoReloaded::DoubleAbilities.reconcile_evolution!(
                  pokemon,
                  previous_components,
                  previous_pair
                )
              end
              result
            end
          end
        end

        def install_unfusion_hook
          return true unless Object.private_method_defined?(:pbUnfuse) ||
                             Object.method_defined?(:pbUnfuse)
          KantoReloaded::Hooks.wrap(
            Object,
            :pbUnfuse,
            :double_abilities_unfusion_result
          ) do |hook, pokemon, *arguments|
            result = hook.call
            KantoReloaded::DoubleAbilities.clear_for_single!(pokemon) if result
            result
          end
        end
      end
    end

    module BattleRuntime
      ELIGIBILITY_IVAR = :@kr_double_abilities_eligible
      CONFIG_VERSION_IVAR = :@kr_double_abilities_config_version
      SECONDARY_CACHE_IVAR = :@kr_double_abilities_secondary_cache
      PAIR_PRIMARY_IVAR = :@kr_double_abilities_pair_primary
      PAIR_SECONDARY_IVAR = :@kr_double_abilities_pair_secondary
      PAIR_VALID_IVAR = :@kr_double_abilities_pair_valid

      @last_ability_owner = nil

      class << self
        def sync_battler(battler, pokemon)
          clear_runtime_state(battler)
          refresh_eligibility_cache(battler, pokemon)
          if eligible_battler?(battler)
            battler.instance_variable_set(
              :@ability2_id,
              KantoReloaded::DoubleAbilities.secondary_id(pokemon)
            )
            clear_secondary_cache(battler)
            validate_battle_pair(battler)
          end
        rescue StandardError => e
          KantoReloaded::Log.exception(
            "Double Abilities battler sync failed",
            e,
            channel: :modules
          ) if defined?(KantoReloaded::Log)
        end

        def clear_runtime_state(battler)
          [
            :@kr_double_abilities_disabled,
            :@kr_double_abilities_transformed,
            :@kr_triggering_ability_slot,
            ELIGIBILITY_IVAR,
            CONFIG_VERSION_IVAR,
            SECONDARY_CACHE_IVAR,
            PAIR_PRIMARY_IVAR,
            PAIR_SECONDARY_IVAR,
            PAIR_VALID_IVAR
          ].each { |key| battler.instance_variable_set(key, nil) }
          clear_pending_splash(battler)
        end

        def eligible_pokemon?(pokemon)
          KantoReloaded::DoubleAbilities.eligible_pokemon?(pokemon) &&
            KantoReloaded::DoubleAbilities.multiplayer_compatible?
        end

        def eligible_battler?(battler)
          return false unless battler
          version = KantoReloaded::DoubleAbilities.runtime_config_version
          cached_version = battler.instance_variable_get(CONFIG_VERSION_IVAR)
          if cached_version != version
            refresh_eligibility_cache(battler)
          end
          return false unless battler.instance_variable_get(ELIGIBILITY_IVAR)
          !battler.instance_variable_get(:@kr_double_abilities_disabled)
        rescue
          false
        end

        def secondary_id(battler)
          return nil unless eligible_battler?(battler)
          value = battler.instance_variable_get(:@ability2_id)
          cached = battler.instance_variable_get(SECONDARY_CACHE_IVAR)
          return cached[1] if cached && cached[0] == value
          ability = GameData::Ability.try_get(value)
          resolved = ability ? ability.id : nil
          battler.instance_variable_set(
            SECONDARY_CACHE_IVAR, [value, resolved]
          )
          resolved
        rescue
          nil
        end

        def secondary_ability(battler)
          id = secondary_id(battler)
          id ? GameData::Ability.try_get(id) : nil
        rescue
          nil
        end

        def secondary_active?(battler, ignore_fainted = false)
          return false unless eligible_battler?(battler)
          return false unless secondary_id(battler)
          battler.abilityActive?(ignore_fainted)
        rescue
          false
        end

        def secondary_matches?(battler, ability, ignore_fainted = false)
          return false unless secondary_active?(battler, ignore_fainted)
          expected = GameData::Ability.try_get(ability)
          expected && secondary_id(battler) == expected.id
        rescue
          false
        end

        def active_ids(battler)
          return [] unless eligible_battler?(battler)
          values = [battler.instance_variable_get(:@ability_id)]
          values << secondary_id(battler) if secondary_active?(battler, true)
          values.compact
        rescue
          []
        end

        def ability_at(battler, slot)
          id = slot.to_i == 2 ?
            battler.instance_variable_get(:@ability2_id) :
            battler.instance_variable_get(:@ability_id)
          ability = GameData::Ability.try_get(id)
          ability ? ability.id : nil
        rescue
          nil
        end

        def assign_battle_slot!(battler, slot, ability)
          return false unless eligible_battler?(battler)
          data = GameData::Ability.try_get(ability)
          return false unless data
          first = slot.to_i == 1 ? data.id : ability_at(battler, 1)
          second = slot.to_i == 2 ? data.id : ability_at(battler, 2)
          return false unless KantoReloaded::DoubleAbilities.pair_legal?(first, second)
          key = slot.to_i == 2 ? :@ability2_id : :@ability_id
          battler.instance_variable_set(key, data.id)
          clear_secondary_cache(battler) if slot.to_i == 2
          cache_pair_validation(battler, first, second, true)
          true
        rescue
          false
        end

        def legal_replacement_slots(battler, ability)
          data = GameData::Ability.try_get(ability)
          return [] unless data && eligible_battler?(battler)
          [1, 2].select do |slot|
            current = ability_at(battler, slot)
            next false if current == data.id
            unstoppable = battler.unstoppableAbility?(current)
            next false if unstoppable
            first = slot == 1 ? data.id : ability_at(battler, 1)
            second = slot == 2 ? data.id : ability_at(battler, 2)
            KantoReloaded::DoubleAbilities.pair_legal?(first, second)
          end
        rescue
          []
        end

        def validate_battle_pair(battler)
          first = battler.instance_variable_get(:@ability_id)
          second = battler.instance_variable_get(:@ability2_id)
          cached_valid = battler.instance_variable_get(PAIR_VALID_IVAR)
          if !cached_valid.nil? &&
             battler.instance_variable_get(PAIR_PRIMARY_IVAR) == first &&
             battler.instance_variable_get(PAIR_SECONDARY_IVAR) == second
            return cached_valid
          end
          valid = KantoReloaded::DoubleAbilities.pair_legal?(first, second)
          cache_pair_validation(battler, first, second, valid)
          return true if valid
          battler.instance_variable_set(:@kr_double_abilities_disabled, true)
          if defined?(KantoReloaded::Log)
            KantoReloaded::Log.warning_once(
              "Disabled an invalid Double Abilities secondary slot for the current battle",
              :modules,
              key: "double_abilities_invalid_battle_pair"
            )
          end
          false
        rescue
          false
        end

        def invalidate_battler_cache(battler)
          return false unless battler
          [
            ELIGIBILITY_IVAR,
            CONFIG_VERSION_IVAR,
            SECONDARY_CACHE_IVAR,
            PAIR_PRIMARY_IVAR,
            PAIR_SECONDARY_IVAR,
            PAIR_VALID_IVAR
          ].each { |key| battler.instance_variable_set(key, nil) }
          true
        rescue
          false
        end

        def refresh_eligibility_cache(battler, pokemon = nil)
          return false unless battler
          pokemon ||= battler.respond_to?(:pokemon) ? battler.pokemon : nil
          transformed = battler.instance_variable_get(
            :@kr_double_abilities_transformed
          )
          eligible = if transformed
                       KantoReloaded::DoubleAbilities.enabled? &&
                         !KantoReloaded::DoubleAbilities.family_pokemon?(pokemon) &&
                         KantoReloaded::DoubleAbilities.multiplayer_compatible?
                     else
                       eligible_pokemon?(pokemon)
                     end
          battler.instance_variable_set(ELIGIBILITY_IVAR, !!eligible)
          battler.instance_variable_set(
            CONFIG_VERSION_IVAR,
            KantoReloaded::DoubleAbilities.runtime_config_version
          )
          !!eligible
        rescue
          battler.instance_variable_set(ELIGIBILITY_IVAR, false) if battler
          false
        end

        def clear_secondary_cache(battler)
          battler.instance_variable_set(SECONDARY_CACHE_IVAR, nil)
        end

        def cache_pair_validation(battler, first, second, valid)
          battler.instance_variable_set(PAIR_PRIMARY_IVAR, first)
          battler.instance_variable_set(PAIR_SECONDARY_IVAR, second)
          battler.instance_variable_set(PAIR_VALID_IVAR, !!valid)
        end

        def capture_ability_owner(battler, ability)
          @last_ability_owner = battler if battler && ability
        end

        def captured_owner(ability)
          battler = @last_ability_owner
          return nil unless battler
          current = battler.instance_variable_get(:@ability_id)
          current == ability_id(ability) ? battler : nil
        rescue
          nil
        ensure
          @last_ability_owner = nil
        end

        def triggering_slot(battler)
          battler.instance_variable_get(:@kr_triggering_ability_slot).to_i
        rescue
          0
        end

        def with_slot(battler, slot)
          previous = battler.instance_variable_get(:@kr_triggering_ability_slot)
          battler.instance_variable_set(:@kr_triggering_ability_slot, slot)
          yield
        ensure
          battler.instance_variable_set(:@kr_triggering_ability_slot, previous)
        end

        # Names the splash for an ability whose effect was decided earlier
        # (for example during damage calculation) and is announced later,
        # after the pending-splash window has closed.
        def with_splash_ability(battler, ability)
          data = battler ? GameData::Ability.try_get(ability) : nil
          return yield unless data
          previous = battler.instance_variable_get(:@kr_splash_ability)
          battler.instance_variable_set(:@kr_splash_ability, data.id)
          begin
            yield
          ensure
            battler.instance_variable_set(:@kr_splash_ability, previous)
          end
        end

        def splash_ability(battler)
          GameData::Ability.try_get(
            battler.instance_variable_get(:@kr_splash_ability)
          )
        rescue
          nil
        end

        # A non-expiring entry lasts until the next splash or ability check
        # clears it; use it only when a splash is certain to follow.
        def mark_pending_splash(battler, ability, slot = 2, expires = true)
          data = GameData::Ability.try_get(ability)
          return false unless battler && data
          @pending_splash = {
            :battler => battler,
            :ability => data.id,
            :slot => slot.to_i,
            :frame => expires ? graphics_frame : nil
          }
          true
        rescue
          false
        end

        def pending_splash
          data = @pending_splash
          return nil unless data
          frame = data[:frame]
          if !frame.nil? && graphics_frame - frame.to_i > 1
            @pending_splash = nil
            return nil
          end
          data
        rescue
          @pending_splash = nil
          nil
        end

        def clear_pending_splash(battler = nil)
          data = @pending_splash
          return false unless data
          return false if battler && data[:battler] != battler
          @pending_splash = nil
          true
        rescue
          false
        end

        def splash_serial(battler)
          battler.instance_variable_get(:@kr_ability_splash_serial).to_i
        rescue
          0
        end

        def note_splash_shown(battler)
          return unless battler
          battler.instance_variable_set(
            :@kr_ability_splash_serial,
            splash_serial(battler) + 1
          )
        rescue
          nil
        end

        def check_includes?(check, ability)
          id = ability_id(ability)
          return false unless id
          if check.is_a?(Array)
            check.any? { |value| ability_id(value) == id }
          else
            ability_id(check) == id
          end
        rescue
          false
        end

        private

        def ability_id(value)
          data = GameData::Ability.try_get(value)
          data ? data.id : nil
        rescue
          nil
        end

        def graphics_frame
          defined?(Graphics) && Graphics.respond_to?(:frame_count) ?
            Graphics.frame_count.to_i :
            0
        rescue
          0
        end
      end
    end
  end
end

KantoReloaded::DoubleAbilities::PokemonIntegration.install
