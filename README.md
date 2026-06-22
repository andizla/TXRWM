# TXRWM — TXR Weather Mod V3

Modular weather system for **Tokyo Xtreme Racer**, built on Ultra Dynamic Sky/Weather via UE4SS.
Lightweight and modular — roughly half the code of the original, streamlined and optimised.

## Features
- Dynamic time of day — adjustable speed, pause, and persistence across sessions
- Weather preset cycling — clear, cloudy, fog, rain, thunderstorm, and more
- Lightning / thunderstorm flashes
- Enhanced volumetric fog
- Daytime + FOV-scaled shadows (work with photomode zoom)
- HD real-stars night sky
- Automatic time-based headlights with brightness control
- Atmospherics — god rays, night auroras, cloud shadows
- Auto-exposure / photomode aperture (ported from VEAO)

## Requirements
- Tokyo Xtreme Racer (Steam)
- UE4SS — the installer downloads it for you
- Ultra Dynamic Sky/Weather present in the game (the mod *drives* it; UDS content is **not** redistributed here)

## Installation
Run **`install.bat`** and follow the prompts. It will:
1. Locate the game (Steam auto-detect, with a manual fallback).
2. Download and install UE4SS (keeping any existing Mods).
3. Install the mod and register it in `mods.txt`.
4. Write the minimal required `Engine.ini` (Replace / Merge / Skip prompt, backs up any existing file, sets read-only), and disable any old standalone VEAO.

Manual install: copy `TXR_Weather_V3/` into
`…\TokyoXtremeRacer\TokyoXtremeRacer\Binaries\Win64\ue4ss\Mods\`, add `TXR_Weather_V3 : 1`
to `mods.txt`, and add the required cvars to `Engine.ini`. See [`TXR_Weather_V3/readme.md`](TXR_Weather_V3/readme.md) for the full guide.

## Engine.ini — use the minimal one
The mod ships a **minimal `Engine.ini`** with only the cvars it needs (exposure + fog). The
installer places it for you. **This is the supported, tested configuration — please use it.**

If anything looks off — **too bright/dark, poor shadow resolution or distance, matte/broken glass
reflections** — first confirm you're on the minimal `Engine.ini` (re-run the installer and pick
**Replace**, or **Merge** to fold the required cvars into your own file). The large "fidelity"
engine.ini that improves shadow sharpness and reflections is a **separate, optional, community
file that is not currently maintained** — visual quality beyond the game default comes from *that*
file, not the mod. Most "mod bugs" reported so far were a missing, outdated, or custom engine.ini.

## Keybinds
| Key | Action |
|-----|--------|
| `Alt+S` / `Alt+Shift+S` | Cycle weather preset (next / prev) |
| `Alt+T` | Cycle time speed (normal / fast / pause) |
| `Alt+R` | Reset weather |
| `Alt+Q` | Headlight mode (auto / on / off) |
| `Alt+B` / `Alt+Shift+B` | Headlight brightness (up / down) |
| `Alt+L` / `Alt+Shift+L` | Re-apply shadow distance |

## Configuration
All settings live in `TXR_Weather_V3/Scripts/config.lua`. Highlights:
- `Config.Weather.Enabled = false` — time-of-day + visuals only, no weather (presets/rain/cycling off).
- `Config.ModuleToggles` — turn individual modules on/off.

## Known issues
- **Use the minimal `Engine.ini`** (see above). Brightness, shadow-quality, and glass-reflection
  problems are almost always a missing/outdated/custom engine.ini — not the mod. The full fidelity
  engine.ini is optional and not currently maintained.
- **Stars module disabled by default** — causes a course-load crash; proper fix pending.
- **Auto-headlights** — the on/off *timing* works, but on some cars the lamp meshes stay lit and
  pop-up headlights (e.g. AE86) don't actuate. Light-actuation fix pending.
- **Rain in tunnels / odd sun & shadows indoors** — the game's map meshes are broken; not fixable from the mod.
- **Surface wetness** only affects road markings — the game lacks the road material for full wetness.

## Credits
Based on **Silent**'s original and **EDGERUNN3R**'s 1.34. Written by **Ten** (andizla), in conjunction with **Ryan**.

## License
[GPLv3](LICENSE). The mod drives Ultra Dynamic Sky/Weather (a paid Unreal Engine asset); UDS content is not included.

See the [changelog](TXR_Weather_V3/CHANGELOG.md) for version history.
