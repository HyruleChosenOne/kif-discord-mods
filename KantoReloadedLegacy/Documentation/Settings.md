# Kanto Reloaded Legacy Settings

`KantoReloaded::Settings` is the persistent registry behind Kanto Reloaded
Legacy's settings. It does not render a menu itself: Players change the
settings in KIF Settings, the game's own settings screen (see KIF Settings
Rows below). Setting definitions and callbacks remain runtime-only. Values use
per-save storage by default, while definitions marked `:scope => :global` are
written immediately to KR's global settings file and apply across all saves.

## Register a Setting

```ruby
KantoReloaded::Settings.register(:battle_style, {
  :name => "Battle Style",
  :description => "Select the preferred battle rules.",
  :type => :enum,
  :values => ["Standard", "Fast"],
  :default => 0,
  :scope => :save,
  :category => :gameplay,
  :owner => :example_mod
})
```

Supported types are `:toggle`, `:enum`, `:number`, `:slider`, `:text`,
`:button`, and `:custom`.

Supported scopes are `:save` and `:global`. The default is `:save`, which
stores values inside `SaveData.system(:settings)`. Global values are stored
outside individual save slots, in `KantoReloadedSettings.json` in the game's
save folder (KR's user-data folder on JoiPlay), and persist as soon as they
change. Existing per-save values are copied to global storage the first time a
global setting is loaded, but never overwrite a global value that already
exists.

On first start (no settings file yet) Legacy copies an old
`KantoReloadedSettings.json` from the game's save folder. The old file is only
read. Old Kuray's save folder and JoiPlay's old user-data folder were outside the
game, which KIF 2.0.0's Mod Safety doesn't allow, so since 1.6.2 they're no longer
read. A fresh install with no old file writes nothing at start.

The global settings are Cursor Color, Overworld Menu, Reloaded EBDX Cursor,
Effectiveness Borders and its five colors, Wild Link's Sprites, Reloaded PC's
Icons, Starting Money, and the Weather System's Custom Audio, Rain Audio, and
Thunder Audio. Every other setting is per-save.

A button can declare `:metadata => { "after" => "setting_key" }` to sit
directly after that row. Only the old KR settings scenes in
`Core/UI/SettingsUI.rb` read it; KIF Settings places rows by
`KIFSettings::LAYOUT`.

```ruby
value = KantoReloaded::Settings.get(:battle_style)
KantoReloaded::Settings.set(:battle_style, 1)
KantoReloaded::Settings.reset(:battle_style)
```

## KIF Settings Rows

`Core/Compatibility/KIFSettings.rb` loads last, after every feature has
registered its settings. It adds one sidebar section labelled `KR Legacy`,
placed first in KIF Settings' sidebar, with one heading per feature:
Overworld, Wild Link, Weather, PokeVial, Money, Shops, PC, Bag, Trainers, Pink
Slips and Records, Battles, EBDX, Levels, Critical EV Gain, Fusion, Eggs and
Natures, and Look. If KIF Settings isn't there (`KIF::Options` or
`KIF::SettingsScreen::SECTIONS` missing), no rows are added and the log says
so.

`KIFSettings::LAYOUT` lists the rows as `[heading, [[key, [child keys]], ...]]`.
Each row is one of PIF's own option types built from the registry definition,
and it reads and writes through `Settings.get` and `Settings.set`, so stored
values stay where they always were:

- `:toggle` becomes an Off/On row.
- `:enum` becomes a choice row with the definition's values.
- `:number` with a range of 200 or less becomes a number row; a wider
  `:number` or any `:slider` becomes a slider using the definition's step.
- `:button` becomes a button that calls `Settings.activate`.

Child keys are KIF child rows: They sit under their switch and hide while it
is Off. Per-save rows only appear while a save is loaded; global rows also
appear from the title screen. KIF hangs a child under whichever row came
before it, so a child of a per-save switch builds nothing until a save is
loaded (`parent_shown?`); otherwise Weather's global audio rows would sit under
Wild Link on the title screen. Each row hands KIF its default, so KIF shows the
changed dot and Z resets the row. The old Reset Module and Reset Category
buttons are not carried over.

The rows don't use `:category`, `:priority`, `:visible_if`, or `:enabled_if`,
so a row whose setting has no effect in the current state stays changeable.
`KIFSettings::NAMES` changes a few shown names (`Effectiveness Borders`, since
KIF has its own Move Effectiveness; `Reloaded EBDX Cursor`; `HP`; `Poké
Balls`). A name KIF already uses gets a unique internal name and is shown
plainly through KIF's `RENAMES`. A key whose setting isn't registered, such as
Reloaded EBDX Cursor without EBDX, gets no row.

The buttons that used to live on the old settings pages are registered by
`KIFSettings` as settings: Reset Search Levels, Open Forecast, Claim Pending
Transfers, View Trainer Records, and Reset All Trainer Records.

A setting registered by another mod only appears in KIF Settings once its key
is added to `KIFSettings::LAYOUT`.

## Categories

```ruby
KantoReloaded::Settings.register_category(:gameplay, {
  :name => "Gameplay",
  :description => "Gameplay behavior and convenience settings.",
  :priority => 100,
  :owner => :example_mod
})
```

The old KR settings scenes in `Core/UI/SettingsUI.rb` read
`Settings.categories` and `Settings.definitions` to build their screens.
`Settings.visible?` and `Settings.enabled?` evaluate optional `:visible_if`
and `:enabled_if` conditions supplied by a registration. Nothing in the game
opens those scenes anymore.

## Module Settings

Module helpers namespace saved keys as `module_id.setting_id`.

```ruby
KantoReloaded::Settings.register(:miscmods_infinite_repel, {
  :name => "Infinite Repel",
  :type => :toggle,
  :default => 0,
  :category => :quality_of_life,
  :owner => :quality_assurance
})

KantoReloaded::Settings.get(:miscmods_infinite_repel)
KantoReloaded::Settings.set(:miscmods_infinite_repel, 1)
```

The built-in Quality Assurance module keeps this older key so an Infinite
Repel value stored by an earlier version still applies.

## Change Callbacks

```ruby
KantoReloaded::Settings.register_on_change(
  :battle_style,
  :example_mod_apply,
  :owner => :example_mod,
  :invoke => true
) do |value, old_value|
  # Apply the setting without replacing a base method.
end
```

Callbacks are reapplied after a KR save bucket loads and when a new game bucket
is created. A failing callback is logged without stopping other callbacks.

## Bulk Import and Export

`import_values` and `export_values` read and write many values at once.
Nothing in Kanto Reloaded Legacy calls them now: The Mod Settings Menu import
and Settings Presets support that used them were dropped.
