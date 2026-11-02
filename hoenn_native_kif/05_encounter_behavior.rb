module HoennNativeKIFTownOptionalBattles
  def should_start_battle?
    return false if instance_variable_get(:@hoenn_native_town_wildlife)
    super
  end
end
OverworldPokemonEvent.prepend(HoennNativeKIFTownOptionalBattles)

# Town water Pokémon are passive when the player is standing on land,
module HoennNativeKIFShoreBattleSafety
  def should_start_battle?
    if instance_variable_get(:@hoenn_native_town_water)
      return false unless $PokemonGlobal && ($PokemonGlobal.surfing || $PokemonGlobal.boat)
    end
    super
  end
end
OverworldPokemonEvent.prepend(HoennNativeKIFShoreBattleSafety)

# keep swimming Pokémon within genuine exposed water tiles
module HoennNativeKIFWaterMovement
  def passable?(x, y, d, strict = false)
    if instance_variable_get(:@hoenn_native_town_water)
      nx = x + (d == 6 ? 1 : d == 4 ? -1 : 0)
      ny = y + (d == 2 ? 1 : d == 8 ? -1 : 0)
      return false unless HoennNativeKIF.open_water_tile?(nx, ny)
    end
    super
  end
end
OverworldPokemonEvent.prepend(HoennNativeKIFWaterMovement)


# Deferred shiny chime and map-lifetime shiny protection

# Hoenn builds visible Pokemon directly rather than using pbGenerateWildPokemon.
# Apply only its held-item step; keep the existing shiny/Alpha generation intact.
module HoennNativeKIFWildItems
  def self.apply(pokemon)
    return unless pokemon
    return if pokemon.instance_variable_get(:@hno_wild_item_rolled)
    # A failed item roll is final too. Store this on the Pokemon, so assigning
    # the same object to an event again cannot reroll it or refill a stolen item.
    pokemon.instance_variable_set(:@hno_wild_item_rolled, true)
    return if pokemon.hasItem?
    return if pokemon.respond_to?(:alpha?) && pokemon.alpha?

    items = pokemon.wildHoldItems
    first_pkmn = $Trainer.first_pokemon if $Trainer
    chances = [50, 5, 1]
    chances = [60, 20, 5] if first_pkmn && first_pkmn.hasAbility?(:COMPOUNDEYES)
    itemrnd = rand(100)
    if (items[0] == items[1] && items[1] == items[2]) || itemrnd < chances[0]
      pokemon.item = items[0]
    elsif itemrnd < chances[0] + chances[1]
      pokemon.item = items[1]
    elsif itemrnd < chances[0] + chances[1] + chances[2]
      pokemon.item = items[2]
    end
  end
end

module HoennNativeKIFWildItemEvent
  def setup_pokemon(*args)
    result = super
    HoennNativeKIFWildItems.apply(pokemon) if is_a?(DynamicOverworldPokemonEvent)
    result
  end

  # Radar can replace the Pokemon after native setup restores its species.
  def pokemon=(pkmn)
    result = super
    HoennNativeKIFWildItems.apply(pkmn) if is_a?(DynamicOverworldPokemonEvent)
    result
  end
end
OverworldPokemonEvent.prepend(HoennNativeKIFWildItemEvent)
