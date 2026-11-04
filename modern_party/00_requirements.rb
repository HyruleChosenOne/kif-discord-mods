# Fail before installing any hooks if this is a different engine/API family.
required = ['KIF::Options','KIF::LevelCap','KIF::MoveLearning',
  'HoennNativeKIFSocial','DynamicOverworldPokemonEvent']
missing = required.reject do |name|
  name.split('::').inject(Object) { |scope, part| scope.const_get(part) } rescue false
end
raise "Modern Party KIF requires the Hoenn Native Overworld / KIF 6.8.2 APIs. Missing: #{missing.join(', ')}" unless missing.empty?

# JoiPlay can provide keyboard input without the desktop controller extension.
module KIFModernInput
  def self.key_triggered?(key)
    Input.respond_to?(:triggerex?) && Input.triggerex?(key)
  end
  def self.controller_value(method,index)
    return nil unless defined?(Input::Controller)
    controller=Input::Controller
    return nil unless controller.respond_to?(:connected?) && controller.connected?
    return nil unless controller.respond_to?(method)
    values=controller.public_send(method)
    values[index] if values.respond_to?(:[])
  end
end

module KIFModernParty
  def self.always_share?
    defined?(::ModSettingsMenu) && ::ModSettingsMenu.get(:kmp_always_share_exp)==1
  end
  def self.register_settings
    ::ModSettingsMenu.register(:kmp_field_exp_percent,
      :name=>'Overworld EXP (%)', :type=>:slider, :min=>1, :max=>100, :interval=>1,
      :default=>10, :category=>'Modern Party KIF',
      :description=>'Percentage of the full normal-battle EXP reward earned in auto battles, including normal EXP bonuses.')
    ::ModSettingsMenu.register(:kmp_always_share_exp,
      :name=>'Always share party EXP', :type=>:enum, :values=>['Off','On'],
      :default=>0, :category=>'Modern Party KIF',
      :description=>'On: share EXP with the able party without items. Off: require held Exp Share or active EXP All.')
  end
  def self.field_exp_percent
    value=::ModSettingsMenu.get(:kmp_field_exp_percent) if defined?(::ModSettingsMenu)
    value.is_a?(Numeric) ? value.to_i.clamp(1,100) : 10
  end
  def self.exp_all?
    always_share? || ($PokemonBag && GameData::Item.exists?(:EXPALL) && $PokemonBag.pbHasItem?(:EXPALL))
  end
  def self.exp_recipient?(pokemon,participated,shares=[],index=nil)
    pokemon && !pokemon.egg? && pokemon.able? &&
      (participated || pokemon.hasItem?(:EXPSHARE) || (index && shares.include?(index)) || exp_all?)
  end
  def self.roaming_target?(event)
    return false unless HoennNativeKIFSocial.event_ours?(event) && event.respond_to?(:pokemon) && event.pokemon
    return false unless $game_map && $game_map.events[event.id].equal?(event)
    return false if event.instance_variable_get(:@hno_radar_stationary) || event.instance_variable_get(:@kif_fusion_pending) || event.instance_variable_get(:@hno_turf_busy)
    return false if event.instance_variable_get(:@terrain)==:Water
    return false if event.respond_to?(:current_state) && event.current_state!=:ROAMING
    true
  end
  def self.evolved_parent(parent,target)
    candidate = "#{target}_#{parent.form}".to_sym
    if parent.form.to_i > 0 && !parent.mega_stone && GameData::Species.exists?(candidate)
      candidate
    else
      target
    end
  end
end
if defined?(::ModSettingsMenu) && ::ModSettingsMenu.respond_to?(:register)
  KIFModernParty.register_settings
else
  $MOD_SETTINGS_PENDING_REGISTRATIONS ||= []
  $MOD_SETTINGS_PENDING_REGISTRATIONS << proc { KIFModernParty.register_settings }
end
