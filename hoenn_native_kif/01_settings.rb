# KIF Mod Manager integration: Options > Modules > Mod Settings.
module HoennNativeKIFSettings
  CATEGORY = "Hoenn Native Overworld"
  DEFAULTS = {
    :hno_enabled => 0,
    :hno_density => 6,
    :hno_fusion => 5,
    :hno_towns => 0,
    :hno_water => 0,
    :hno_sparkles => 0,
    :hno_interval => 180,
    :hno_town_water_cap => 2,
    :hno_route_water_cap => 3,
    :hno_shiny_chime => 0,
    :hno_shiny_persist => 0,
    :hno_social => 0,
    :hno_social_chance => 15,
    :hno_territorial_evo_test => 1,
    :hno_territorial_battle_test => 1
  }
  def self.get(key)
    return DEFAULTS[key] unless defined?(::ModSettingsMenu) && ::ModSettingsMenu.respond_to?(:get)
    value = ::ModSettingsMenu.get(key)
    value.is_a?(Integer) ? value : DEFAULTS[key]
  rescue StandardError
    DEFAULTS[key]
  end
  def self.enabled?; get(:hno_enabled) == 0; end
  def self.towns?; get(:hno_towns) == 0; end
  def self.water?; get(:hno_water) == 0; end
  def self.sparkles?; get(:hno_sparkles) == 0; end
  def self.fusion_percent; [[get(:hno_fusion), 1].max, 100].min; end
  def self.spawn_interval; [[get(:hno_interval), 60].max, 600].min; end
  def self.town_water_limit; [[get(:hno_town_water_cap), 1].max, 10].min; end
  def self.route_water_limit; [[get(:hno_route_water_cap), 1].max, 10].min; end
  def self.shiny_chime?; get(:hno_shiny_chime) == 0; end
  def self.shiny_persistence?; get(:hno_shiny_persist) == 0; end
  def self.social?; get(:hno_social) == 0; end
  def self.social_chance; [[get(:hno_social_chance), 0].max, 100].min; end
  def self.territorial_battle_test?; get(:hno_territorial_battle_test) == 0; end
  def self.territorial_evo_test?; get(:hno_territorial_evo_test) == 0; end
  def self.population_limit; [[get(:hno_density), 1].max, 25].min; end
  def self.register_settings
    return unless defined?(::ModSettingsMenu) && ::ModSettingsMenu.respond_to?(:register)
    entries = [
      [:hno_enabled, "Overworld spawning", ["On", "Off"], "Enable or pause new Hoenn-style overworld encounters."],
      [:hno_density, "Max land Pokemon", nil, "Maximum simultaneously active land Pokemon. Default 6; spawning stays gradual."],
      [:hno_fusion, "Natural fusion chance (%)", nil, "Chance for naturally spawning route or cave Pokemon to be pre-fused. Default 5%."],
      [:hno_towns, "Town wildlife", ["On", "Off"], "Allow ambient land wildlife in towns and cities."],
      [:hno_water, "Aquatic Pokemon", ["On", "Off"], "Allow ambient water Pokemon in ponds and route water."],
      [:hno_sparkles, "Shiny sparkles", ["On", "Off"], "Show repeating sparkle effects on shiny overworld Pokemon."],
      [:hno_interval, "Spawn interval (frames)", nil, "Frames between spawn attempts. 180 is the original default; lower is faster."],
      [:hno_town_water_cap, "Town water Pokemon limit", nil, "Maximum aquatic Pokemon in town ponds. Default 2."],
      [:hno_route_water_cap, "Route water Pokemon limit", nil, "Maximum aquatic Pokemon in route water. Default 3."],
      [:hno_shiny_chime, "Shiny spawn chime", ["On", "Off"], "Play the discovery sound when a shiny overworld Pokemon spawns."],
      [:hno_shiny_persist, "Shiny map persistence", ["On", "Off"], "Protect shiny overworld Pokemon from distance despawn and population eviction until map exit."],
      [:hno_social, "Wild Pokemon interactions", ["On", "Off"], "Allow nearby calm wild Pokemon to greet and play briefly."],
      [:hno_social_chance, "Social encounter chance (%)", nil, "Chance of a social reaction when an eligible pair meets. Default 15%."],
      [:hno_territorial_battle_test, "Territorial battle test", ["On", "Off"], "Force a fight when two eligible Pokemon are next to each other. Personal testing only."],
      [:hno_territorial_evo_test, "Territorial evolution test", ["On", "Off"], "Force the rare post-fight evolution roll to succeed. Personal testing only."]
    ]
    entries.each do |key, name, values, description|
      if [:hno_density, :hno_fusion, :hno_interval, :hno_town_water_cap, :hno_route_water_cap, :hno_social_chance].include?(key)
        ::ModSettingsMenu.register(key, :name => name, :type => :slider,
          :min => (key == :hno_interval ? 60 : (key == :hno_social_chance ? 0 : 1)),
          :max => ({:hno_density => 25, :hno_fusion => 100, :hno_interval => 600,
                    :hno_town_water_cap => 10, :hno_route_water_cap => 10, :hno_social_chance => 100}[key]),
          :default => DEFAULTS[key], :description => description,
          :category => CATEGORY)
      else
        ::ModSettingsMenu.register(key, :name => name, :type => :enum,
          :values => values, :default => DEFAULTS[key],
          :description => description, :category => CATEGORY)
      end
    end
  end
end
if defined?(::ModSettingsMenu) && ::ModSettingsMenu.respond_to?(:register)
  HoennNativeKIFSettings.register_settings
else
  $MOD_SETTINGS_PENDING_REGISTRATIONS ||= []
  $MOD_SETTINGS_PENDING_REGISTRATIONS << proc { HoennNativeKIFSettings.register_settings }
end
