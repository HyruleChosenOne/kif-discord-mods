#==============================================================================
# Kanto Reloaded Double Abilities - Battle Handler Dispatch
#==============================================================================

module KantoReloaded
  module DoubleAbilities
    module BattleDispatch
      SCALAR_ARGUMENTS = {
        :triggerSpeedCalcAbility => 2,
        :triggerWeightCalcAbility => 2,
        :triggerPriorityChangeAbility => 3,
        :triggerPriorityBracketChangeAbility => 2,
        :triggerMoveBaseTypeModifierAbility => 3,
        :triggerCriticalCalcUserAbility => 3,
        :triggerCriticalCalcTargetAbility => 3
      }.freeze

      BOOLEAN_HANDLERS = [
        :triggerAbilityOnHPDroppedBelowHalf,
        :triggerStatusCheckAbilityNonIgnorable,
        :triggerStatusImmunityAbility,
        :triggerStatusImmunityAbilityNonIgnorable,
        :triggerStatusImmunityAllyAbility,
        :triggerStatusCureAbility,
        :triggerStatLossImmunityAbility,
        :triggerStatLossImmunityAbilityNonIgnorable,
        :triggerStatLossImmunityAllyAbility,
        :triggerMoveBlockingAbility,
        :triggerMoveImmunityTargetAbility,
        :triggerCertainSwitchingUserAbility,
        :triggerTrappingTargetAbility,
        :triggerRunFromBattleAbility
      ].freeze

      # KIF shows "X used Y!" between Dazzling-style blocking and its splash,
      # so the secondary's splash name must outlive that message.
      SPLASH_AFTER_MESSAGE_HANDLERS = [
        :triggerMoveBlockingAbility
      ].freeze

      NATIVE_SECONDARY_HANDLERS = [
        :triggerUserAbilityEndOfMove,
        :triggerTargetAbilityAfterMoveUse
      ].freeze

      OWNER_ARGUMENTS = {
        :triggerSpeedCalcAbility => 1,
        :triggerWeightCalcAbility => 1,
        :triggerAbilityOnHPDroppedBelowHalf => 1,
        :triggerStatusCheckAbilityNonIgnorable => 1,
        :triggerStatusImmunityAbility => 1,
        :triggerStatusImmunityAbilityNonIgnorable => 1,
        :triggerAbilityOnStatusInflicted => 1,
        :triggerStatusCureAbility => 1,
        :triggerStatLossImmunityAbility => 1,
        :triggerStatLossImmunityAbilityNonIgnorable => 1,
        :triggerStatLossImmunityAllyAbility => 1,
        :triggerAbilityOnStatGain => 1,
        :triggerAbilityOnStatLoss => 1,
        :triggerPriorityChangeAbility => 1,
        :triggerPriorityBracketChangeAbility => 1,
        :triggerPriorityBracketUseAbility => 1,
        :triggerAbilityOnFlinch => 1,
        :triggerMoveBlockingAbility => 1,
        :triggerMoveImmunityTargetAbility => 2,
        :triggerMoveBaseTypeModifierAbility => 1,
        :triggerAccuracyCalcUserAbility => 2,
        :triggerAccuracyCalcTargetAbility => 3,
        :triggerDamageCalcUserAbility => 1,
        :triggerDamageCalcTargetAbility => 2,
        :triggerDamageCalcTargetAbilityNonIgnorable => 2,
        :triggerCriticalCalcUserAbility => 1,
        :triggerCriticalCalcTargetAbility => 2,
        :triggerTargetAbilityOnHit => 2,
        :triggerUserAbilityOnHit => 1,
        :triggerUserAbilityEndOfMove => 1,
        :triggerTargetAbilityAfterMoveUse => 1,
        :triggerEORWeatherAbility => 2,
        :triggerEORHealingAbility => 1,
        :triggerEOREffectAbility => 1,
        :triggerEORGainItemAbility => 1,
        :triggerCertainSwitchingUserAbility => 1,
        :triggerTrappingTargetAbility => 2,
        :triggerAbilityOnSwitchIn => 1,
        :triggerAbilityOnSwitchOut => 1,
        :triggerAbilityChangeOnBattlerFainting => 1,
        :triggerAbilityOnBattlerFainting => 1,
        :triggerRunFromBattleAbility => 1
      }.freeze

      ALLY_OWNER_HANDLERS = [
        :triggerStatusImmunityAllyAbility,
        :triggerAccuracyCalcUserAllyAbility,
        :triggerDamageCalcUserAllyAbility,
        :triggerDamageCalcTargetAllyAbility
      ].freeze

      HANDLERS = (
        OWNER_ARGUMENTS.keys +
        ALLY_OWNER_HANDLERS
      ).uniq.freeze

      class << self
        def install
          return false unless defined?(BattleHandlers)
          results = HANDLERS.map { |method_name| install_handler(method_name) }
          install_splash_hook
          install_splash_bar_reset_hook
          installed = results.count { |value| value }
          if defined?(KantoReloaded::Log)
            KantoReloaded::Log.info(
              "Installed Double Abilities dispatch for #{installed}/#{HANDLERS.length} battle handlers",
              :modules
            )
          end
          installed > 0
        rescue StandardError => e
          KantoReloaded::Log.exception(
            "Double Abilities battle dispatch install failed",
            e,
            channel: :modules
          ) if defined?(KantoReloaded::Log)
          false
        end

        private

        def install_handler(method_name)
          KantoReloaded::Hooks.wrap(
            BattleHandlers,
            method_name,
            :"double_abilities_dispatch_#{method_name}",
            :singleton => true
          ) do |hook, *arguments|
            runtime = KantoReloaded::DoubleAbilities::BattleRuntime
            owner = KantoReloaded::DoubleAbilities::BattleDispatch.owner_for(
              method_name,
              arguments
            )
            if KantoReloaded::DoubleAbilities::BattleDispatch.secondary_call?(
              owner,
              arguments[0]
            )
              next runtime.with_slot(owner, 2) do
                KantoReloaded::DoubleAbilities::BattleDispatch.invoke_handler(
                  hook,
                  method_name,
                  arguments
                )
              end
            end
            unless KantoReloaded::DoubleAbilities::BattleDispatch.dispatchable?(
              owner,
              arguments[0]
            )
              next KantoReloaded::DoubleAbilities::BattleDispatch.invoke_handler(
                hook,
                method_name,
                arguments
              )
            end
            runtime.clear_pending_splash(owner)

            primary_result =
              KantoReloaded::DoubleAbilities::BattleDispatch.invoke_handler(
                hook,
                method_name,
                arguments
              )

            next primary_result if KantoReloaded::DoubleAbilities::BattleDispatch.native_secondary_handler?(
              method_name
            )
            if KantoReloaded::DoubleAbilities::BattleDispatch.boolean_handler?(method_name) &&
               primary_result
              next primary_result
            end
            next primary_result unless runtime.validate_battle_pair(owner)
            next primary_result unless runtime.secondary_active?(owner, true)

            secondary = runtime.secondary_id(owner)
            next primary_result unless secondary
            secondary_arguments = arguments.dup
            secondary_arguments[0] = secondary
            scalar_index =
              KantoReloaded::DoubleAbilities::BattleDispatch.scalar_argument(method_name)
            secondary_arguments[scalar_index] = primary_result if scalar_index

            splash_serial = runtime.splash_serial(owner)
            secondary_result = runtime.with_slot(owner, 2) do
              KantoReloaded::DoubleAbilities::BattleDispatch.invoke_handler(
                hook,
                method_name,
                secondary_arguments
              )
            end
            if KantoReloaded::DoubleAbilities::BattleDispatch.boolean_handler?(method_name) &&
               secondary_result &&
               runtime.splash_serial(owner) == splash_serial
              runtime.mark_pending_splash(
                owner,
                secondary,
                2,
                !KantoReloaded::DoubleAbilities::BattleDispatch.splash_after_message?(
                  method_name
                )
              )
            end

            if scalar_index ||
               KantoReloaded::DoubleAbilities::BattleDispatch.boolean_handler?(method_name)
              secondary_result
            else
              primary_result
            end
          end
        end

        def install_splash_hook
          return true unless defined?(::PokeBattle_Battle)
          KantoReloaded::Hooks.wrap(
            ::PokeBattle_Battle,
            :pbShowAbilitySplash,
            :double_abilities_splash_name
          ) do |hook, battler, delay = false, log_trigger = true, ability_name = nil|
            runtime = KantoReloaded::DoubleAbilities::BattleRuntime
            display_battler = battler
            pending = nil
            shown = nil
            if runtime.triggering_slot(battler) == 2
              ability = runtime.secondary_ability(battler)
              ability_name = ability.name if ability
              shown = ability
            elsif ability_name.nil? && (announced = runtime.splash_ability(battler))
              ability_name = announced.name
              shown = announced
            elsif ability_name.nil?
              pending = runtime.pending_splash
              if pending
                pending_battler = pending[:battler]
                pending_ability = GameData::Ability.try_get(pending[:ability])
                if pending_battler == battler && pending_ability
                  ability_name = pending_ability.name
                  shown = pending_ability
                end
              end
            end
            runtime.note_splash_shown(display_battler)
            link = KantoReloaded::DoubleAbilities::Integration
            secondary = link.secondary_splash?(battler, shown)
            known_before = link.splash_record(self, battler) if secondary
            result = hook.call_with([
              display_battler,
              delay,
              log_trigger,
              ability_name
            ])
            link.note_secondary_splash(self, battler, shown.id, known_before) if secondary
            result
          ensure
            runtime.clear_pending_splash(pending[:battler]) if pending
          end
        end

        # KIF's splash bar keeps an explicitly passed ability name forever, so
        # every later splash on that side repeats it. The bar has already drawn
        # by the time the scene call returns, so the stored name is cleared.
        def install_splash_bar_reset_hook
          return true unless defined?(::PokeBattle_Scene)
          KantoReloaded::Hooks.wrap(
            ::PokeBattle_Scene,
            :pbShowAbilitySplash,
            :double_abilities_splash_bar_reset
          ) do |hook, battler, *arguments|
            begin
              hook.call
            ensure
              KantoReloaded::DoubleAbilities::BattleDispatch.reset_splash_bar_names(
                @sprites,
                battler
              )
            end
          end
        end
      end

      def self.reset_splash_bar_names(sprites, battler)
        return unless sprites.is_a?(Hash) && battler.respond_to?(:index)
        side = battler.index % 2
        ["abilityBar_#{side}", "ability2Bar_#{side}"].each do |key|
          bar = sprites[key]
          bar.ability_name = nil if bar.respond_to?(:ability_name=)
        end
      rescue
        nil
      end

      def self.owner_for(method_name, arguments)
        runtime = KantoReloaded::DoubleAbilities::BattleRuntime
        return runtime.captured_owner(arguments[0]) if ALLY_OWNER_HANDLERS.include?(method_name)
        index = OWNER_ARGUMENTS[method_name]
        index ? arguments[index] : nil
      rescue
        nil
      end

      def self.dispatchable?(owner, ability)
        return false unless owner
        runtime = KantoReloaded::DoubleAbilities::BattleRuntime
        return false unless runtime.eligible_battler?(owner)
        passed = GameData::Ability.try_get(ability)
        primary = GameData::Ability.try_get(owner.instance_variable_get(:@ability_id))
        passed && primary && passed.id == primary.id
      rescue
        false
      end

      def self.scalar_argument(method_name)
        SCALAR_ARGUMENTS[method_name]
      end

      def self.boolean_handler?(method_name)
        BOOLEAN_HANDLERS.include?(method_name)
      end

      def self.splash_after_message?(method_name)
        SPLASH_AFTER_MESSAGE_HANDLERS.include?(method_name)
      end

      def self.native_secondary_handler?(method_name)
        NATIVE_SECONDARY_HANDLERS.include?(method_name)
      end

      def self.secondary_call?(owner, ability)
        return false unless owner
        runtime = KantoReloaded::DoubleAbilities::BattleRuntime
        return false unless runtime.eligible_battler?(owner)
        passed = GameData::Ability.try_get(ability)
        secondary = GameData::Ability.try_get(runtime.secondary_id(owner))
        passed && secondary && passed.id == secondary.id
      rescue
        false
      end

      def self.invoke_handler(hook, method_name, arguments)
        if method_name == :triggerUserAbilityEndOfMove &&
           defined?(KantoReloaded::DoubleAbilities::SpecialAbilities)
          handled, result =
            KantoReloaded::DoubleAbilities::SpecialAbilities.dispatch_battle_bond(
              *arguments
            )
          return result if handled
        end
        if method_name == :triggerTargetAbilityOnHit &&
           defined?(KantoReloaded::DoubleAbilities::SpecialAbilities)
          handled, result =
            KantoReloaded::DoubleAbilities::SpecialAbilities.dispatch_contact_ability(
              *arguments
            )
          return result if handled
        end
        if method_name == :triggerAbilityChangeOnBattlerFainting &&
           defined?(KantoReloaded::DoubleAbilities::SpecialAbilities)
          handled, result =
            KantoReloaded::DoubleAbilities::SpecialAbilities.dispatch_faint_copy(
              *arguments
            )
          return result if handled
        end
        result = hook.call_with(arguments)
        if method_name == :triggerAbilityOnSwitchIn &&
           defined?(KantoReloaded::DoubleAbilities::GeneralizedAbilities)
          KantoReloaded::DoubleAbilities::GeneralizedAbilities.apply_commander(
            *arguments
          )
        end
        result
      end
    end
  end
end

KantoReloaded::DoubleAbilities::BattleDispatch.install
