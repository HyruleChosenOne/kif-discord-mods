# Kanto Reloaded Legacy Platform

`KantoReloaded::Platform` provides runtime detection and portable helpers for
Windows, Proton/Wine, JoiPlay, and unknown hosts.

```ruby
KantoReloaded::Platform.id
KantoReloaded::Platform.label
KantoReloaded::Platform.windows?
KantoReloaded::Platform.proton?
KantoReloaded::Platform.joiplay?
KantoReloaded::Platform.supports?(:clipboard)
KantoReloaded::Platform.clipboard_write("text")
KantoReloaded::Platform.open_url("https://example.com")
```

## Paths

Use the platform helpers for paths handled by KR modules or external mods:

```ruby
path = KantoReloaded::Platform.join_path(KantoReloaded::Platform::GAME_ROOT, "Mods", "Example")
KantoReloaded::Platform.normalize_path(path)
KantoReloaded::Platform.path_within?(path)
KantoReloaded::Platform.glob(File.join(path, "**", "*.json"))
```

`display_path` returns a log-safe relative or basename-only path. It should be
used in user-facing errors instead of exposing a full local filesystem path.

`user_data_directory` is `Kanto Reloaded Legacy` inside the game's save folder
(`System.data_directory`), or Legacy's own mod folder when there's none. Nothing
outside the game and its save folder is read or written, no program is started
and nothing of the computer's settings (`ENV`) is read: KIF 2.0.0's Mod Safety
grades those red (1.6.2). Proton is what KIF's own check says
(`KIF::ModCompat.wine?`), and a phone is JoiPlay's marker, Ruby saying android,
or `KIF.mobile?`.

Windows and Proton expose a guarded clipboard adapter. JoiPlay feature-detects
clipboard writes through `Input.clipboard=`. Unknown runtimes report it as
unavailable so callers can provide an in-game fallback.

## JSON

Legacy reads and writes JSON with its own strict `KantoReloaded::SafeJSON`
(`Core/Foundation/SafeJSON.rb`, loaded before Platform), on every platform. The
game's `::JSON` (PIF's `003_HTTP_Utilities.rb`) reads with `eval`: it ran a
file's text as Ruby code, turned `"key":` into symbols (Legacy's version read
as 0.0.0), and failed on `null`; its writer doesn't escape quotes or
backslashes. SafeJSON returns String keys, raises `SafeJSON::ParseError` on bad
JSON, and escapes what it writes.

```ruby
data = KantoReloaded::Platform.parse_json(text)
text = KantoReloaded::Platform.generate_json(data)
```

## Platform Overrides

`set_override` is runtime-only and intended for debug tools and contract tests.
It does not persist into save data or settings. Call `clear_override` to return
to automatic detection.

## JoiPlay UI Compatibility

Some KIF builds declare the `GenOneStyle` title-screen disposal helpers after
the class has already closed. This places `dispose` on `Object`, where JoiPlay
can recursively invoke it while KR menus release unrelated UI helpers.

On JoiPlay, KR detects that exact malformed method layout, restores the methods
directly to `GenOneStyle`, and guards the accidental global `dispose` fallback.
The workaround is not installed on Windows, Proton, or KIF builds where
`GenOneStyle` already owns its disposal method.

KR global settings use the platform user-data directory on JoiPlay instead of
attempting to write into the read-only game directory.
