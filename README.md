# TXRWM - TXR Weather Mod V3

Modular weather system for **Tokyo Xtreme Racer**, built on Ultra Dynamic Sky/Weather via UE4SS.
Lightweight and modular - roughly half the code of the original, streamlined and optimised.

## Features
- Dynamic time of day - adjustable speed, pause, and persistence across sessions
- Weather preset cycling - clear, cloudy, fog, rain, thunderstorm, and more
- Random weather scheduler - weighted and time-of-day aware (clear skies rarer by day)
- Lightning / thunderstorm flashes
- Enhanced volumetric fog
- Daytime + FOV-scaled shadows (work with photomode zoom)
- HD real-stars night sky
- Automatic time-based headlights with brightness control (see known issues)
- Atmospherics - god rays, night auroras, cloud shadows, Tokyo city glow (night light pollution)
- Auto-exposure / photomode aperture (ported from VEAO)
- Fully compatible with manual time adjustments done by CoolConsoleCommands by Shibexd, i will implement my own soon

## Requirements
- Tokyo Xtreme Racer (Steam)
- Silents UE4SS - the installer downloads it for you from Silent github
- Ultra Dynamic Sky/Weather is present in the game (the mod *drives* it; UDS content is **not** redistributed here)

## Installation
Run **`install.bat`** and follow the prompts. It will automatically:
1. Locate the game (Steam auto-detect, with a manual fallback).
2. Download and install UE4SS (keeping any existing Mods).
3. Install the mod and register it in `mods.txt`.
4. Set up `Engine.ini` from a graphics profile you pick (backs up any existing file, sets read-only), and disable any old standalone VEAO.

Manual install: copy `TXR_Weather_V3/` into
`…\TokyoXtremeRacer\TokyoXtremeRacer\Binaries\Win64\ue4ss\Mods\`, add `TXR_Weather_V3 : 1`
to `mods.txt`, and add the required cvars to `Engine.ini`. See [`TXR_Weather_V3/readme.md`](TXR_Weather_V3/readme.md) for the full guide.

## Engine.ini - pick a profile
The installer sets up `Engine.ini` for you and offers graphics profiles. Every profile includes the
cvars the mod relies on (exposure + fog):

- **Photomode + exposure** (recommended) - highest fidelity, resource heavy.
- **Photomode, no exposure** - same fidelity, the game's vanilla brightness.
- **Optimizations only + exposure** (recommended for midrange / non-DLSS rigs) - lighter.
- **Optimizations only, no exposure** - lighter, vanilla brightness.
- **Minimal** - only what the mod needs, lightest.

"Exposure" means the mod drives manual exposure (correct brightness, working photomode aperture).
"No exposure" leaves the game's own auto-exposure (vanilla brightness). The installer keeps
`Config.Exposure.Enabled` in sync with the profile you choose.

If the game looks too bright or washed out, you most likely skipped the Engine.ini step. Re-run the
installer and pick a profile. Shadow sharpness/distance and reflection quality also come from the
profile, so try Photomode if a lighter profile looks flat.

## Keybinds
| Key | Action |
|-----|--------|
| `Alt+S` / `Alt+Shift+S` | Cycle weather preset (next / prev) |
| `Alt+P` / `Alt+Shift+P` | Random weather preset / force clear |
| `Alt+T` | Cycle time speed (normal / fast / pause) |
| `Alt+R` | Reset weather |
| `Alt+Q` | Headlight mode (auto / on / off) |
| `Alt+B` / `Alt+Shift+B` | Headlight brightness (up / down) |
| `Alt+L` / `Alt+Shift+L` | Re-apply shadow distance |

## Configuration
All settings live in `TXR_Weather_V3/Scripts/config.lua`. Highlights:
- `Config.Weather.Enabled = false` - time-of-day + visuals only, no weather (presets/rain/cycling off).
- `Config.ModuleToggles` - turn individual modules on/off.

## Known issues
- **Pick an Engine.ini profile in the installer** (see above). Brightness, shadow-quality, and
  glass-reflection problems are almost always a skipped Engine.ini step or a custom/outdated one,
  not the mod.
- **Auto-headlights** - the on/off *timing* works, but on some cars the lamp meshes stay lit and
  pop-up headlights (e.g. AE86) don't actuate. Light-actuation fix pending.
- **Rain in tunnels / odd sun & shadows indoors** - the game's tunnel meshes have no interior
  collision, so weather and lighting can't be occluded there from the mod.
- **Surface wetness and screen weather effects** - the game's road materials lack Ultra Dynamic
  Weather's wetness logic, and the game doesn't composite UDW's screen-space effects (rain-on-lens,
  frost, etc.), so those don't render. Not fixable from the mod; would need cooked content.
- **Transitions might be rough** i am working on ingame time of day/weather/brightness value GUI to easily report these events when noticed
## Credits
Inspired by **Silent**'s original Dynamic Day/Night Cycle. **EDGERUNN3R** took it further and made Ultra Dynamic TXR. This project was started together with **EDGERUNN3R**, who shared his early source and helped get it set up and understand UDS and UE4SS. TXR Weather Mod V3 is a full rewrite by **Ten** (andizla) and uses none of the original Ultra Dynamic TXR 1.34 code.

## License
[GPLv3](LICENSE). The mod drives Ultra Dynamic Sky/Weather; UDS content is not included.

See the [changelog](TXR_Weather_V3/CHANGELOG.md) for version history.
