# Discord Rich Presence for Kuray Infinite Fusion (v1.2.0)

Broadcast your live **Kuray's Infinite Fusion** adventure to your Discord profile with full-size custom fusion sprites, stylized pixel-art location scenes, live progression stats, battle opponents, and co-op team leader previews.

---

## ✨ Features

- **Full-Size Party Leader Sprite (`large_image`)**:
  - **Fusions**: Automatically resolves the exact in-game custom fusion battler sprite (`head_id.body_id.png`).
  - **Unfused Pokémon**: Choose between **Animated (Showdown)**, **Pixel**, or **Official Artwork** sprites (with official animated shiny Showdown GIF support).
  - **Hover Breakdown**: Hovering over your Pokémon's sprite displays its shiny star (`★`), localized species/name, level, and fused **Head + Body** breakdown (e.g., `★ Torizard (Lv. 75) • Torterra + Charizard` / `★ Torifeu (Niv. 75) • Torterra + Dracaufeu`) or typing.
- **Co-op Team Leader Integration**:
  - **Co-op Leader Orb (`small_image`)**: In a co-op session, the small corner orb displays your partner's team leader sprite without exposing any player username.
  - **Co-op Hover Breakdown**: Hovering over the orb displays the partner's team leader species, level, and fusion breakdown (e.g. `Co-op: ★ Venustoise (Lv. 62) • Venusaur + Blastoise`).
- **Stylized Location Pixel Art (`small_image` or `large_image`)**:
  - Displays hand-crafted pixel art from **Kanto Redrawn** covering all **Kanto & Johto Towns**, **Routes 1–25**, **Gyms**, **Oak's Lab**, **Pokémon Centers & Poké Marts**, **Caves & Dungeons**, and the **Sevii Islands**.
  - **Map Hover Tooltip**: Shows **Game Mode & Difficulty** (`Classic (Hard)`), active **Challenges** (`Nuzlocke`, `Soul Link`, `Single Species`), and **Session Status** (`Solo` or `Co-op (2 Players)`).
- **Clean Activity Context**:
  - Dynamically updates when **Exploring**, **Cycling**, **Surfing**, **Diving**, **Fishing**, or **In Battle**.
  - **Intelligent Battle Classification**: Automatically identifies **Gym Battles** (`Gym Battle vs. Brock • Pewter Gym`), **Elite Four** (`Elite Four vs. Lorelei`), **Champion Matches** (`Champion Match vs. Blue`), **Rivals** (`Rival Battle vs. Blue`), **Bosses** (`Boss Battle vs. Giovanni`), and wild encounters (`Wild ★ Torizard (Lv. 50) • Torterra + Charizard`).
  - **Battle Format Detection**: Accurately recognizes non-standard formats (`[2v2]` Doubles, `[3v3]` Triples).
  - Subscribes to KIF's official event bus (`KIF::API.on`) for instant updates on save load, map changes, battles, catches, fusions, and level-ups.
- **Live Progression Stats**:
  - Displays your **Gym Badges**, **Pokédex Owned**, **Caught Shinies** (`★ Shinies` across Party + PC Boxes), **Fusions**, and optional **Money Balance** (`$125K`).
  - Optional **Nuzlocke Tracker** (`💀 Deaths: X`) and **Level Cap Indicator** (`Cap: Lv. 25`) for challenge runs (disabled by default to keep presence clean).
- **Flexible Elapsed Timer**:
  - Choose between **Session Time**, **Total Save Playtime**, or **Off**.
- **100% Read-Only & Safe**:
  - Never modifies save files, party data, or base game mechanics.

---

## ⚙️ In-Game Settings (Codybase / KIF)

All options can be customized live in-game without restarting under **`Options > Mods > Discord Rich Presence`**:

| Setting | Options | Description |
| :--- | :--- | :--- |
| **Discord RPC** | `Off` / `On` | Enable or disable Discord Rich Presence broadcasting. |
| **Primary Image** | `Leader Sprite` / `Location Art` | Choose which image is displayed full-size vs. in the corner orb. |
| **Unfused Sprite Style** | `Animated` / `Pixel` / `Artwork` | Sprite style for unfused Pokémon (fusions always use custom fusion sprites). |
| **Location Artwork** | `Off` / `On` | Show stylized pixel-art scenes of your current town, gym, dungeon, or route. |
| **Leader Breakdown** | `Off` / `On` | Show fused Head + Body Pokémon names or typing in the sprite hover tooltip. |
| **Show Badges** | `Off` / `On` | Display gym badge count (`8 Badges`). |
| **Show Pokédex** | `Off` / `On` | Display caught Pokédex count (`Dex: 341`). |
| **Show Shinies** | `Off` / `On` | Display total caught shinies in Party + PC (`★ Shinies: 12`). |
| **Show Fusions** | `Off` / `On` | Display total fusions obtained (`Fusions: 208`). |
| **Show Money** | `Off` / `On` | Display formatted money balance (`$125K`). |
| **Battle Opponent Info** | `Off` / `On` | Display opponent trainer or wild Pokémon name during battles. |
| **Show Game Mode** | `Off` / `On` | Display game mode, difficulty, and active challenges in the orb tooltip. |
| **Show Challenge in Text** | `Off` / `On` | Display active challenges (`Nuzlocke`, `Soul Link`, etc.) in the status line. |
| **Show Session Type** | `Off` / `On` | Display `Solo` or `Co-op` session status in the orb tooltip. |
| **Co-op Leader Orb** | `Off` / `On` | Display co-op partner's team leader Pokémon sprite in the small corner orb. |
| **Co-op Leader in Text** | `Off` / `On` | Show co-op partner's team leader and fusion breakdown in the bottom status line. |
| **Elapsed Timer** | `Session Time` / `Save Playtime` / `Off` | Choose which time counter appears on Discord. |
| **Leader in Status Text** | `Off` / `On` | Also show your party leader's name and level in the text status line. |
| **Nuzlocke Tracker** | `Off` / `On` | Show Nuzlocke losses and deaths in status line (off by default). |
| **Level Cap Indicator** | `Off` / `On` | Show active gym level cap in status line when level caps are enabled (off by default). |
| **Reconnect Discord** | `[Button]` | Immediately reconnect to Discord and refresh your Rich Presence. |

---

## 📦 Installation

1. Extract the `DiscordRichPresence` folder into `KIF/Mods/` (so `KIF/Mods/DiscordRichPresence/mod.json` exists).
2. Make sure the **Discord Desktop App** is open on your PC with **Activity Privacy > Share your detected activity with others** enabled.
3. Launch **Kuray's Infinite Fusion**!
