# TXRWM - TXR Weather Mod V3

Modular weather system for **Tokyo Xtreme Racer**, built on Ultra Dynamic Sky/Weather via UE4SS.
Lightweight and modular - roughly half the code of the original, streamlined and optimised.

## Features
- Dynamic time of day - adjustable speed, pause, and persistence across sessions
- **Night-only mode** - dusk, night, dawn, then straight back to dusk: the day is skipped entirely (off by default; installer option)
- **Cinematic sky** - a daytime look pass: denser cloud cores, silver-lining glow, high cirrus that lights up near the sun, richer sky color, luminous overcast, stronger sunsets, slower cloud drift
- **Per-weather exposure compensation** - overcast, rain, fog and snow scenes automatically get brighter instead of gray mush
- Weather preset cycling - clear, cloudy, fog, rain, thunderstorm, and more
- Random weather scheduler - weighted and time-of-day aware (clear skies rarer by day)
- Lightning / thunderstorm flashes
- Enhanced volumetric fog
- Daytime + FOV-scaled shadows (work with photomode zoom)
- HD real-stars night sky
- Headlights with **animated pop-ups** - Auto mode tracks the scene brightness; manual mode works in the garage and on a controller (short-press on / hold off); adjustable brightness
- Atmospherics - god rays, volumetric cloud light rays, cloud shadows, Tokyo city glow (night light pollution)
- Wind debris in storms, and moon phases / scalable moon
- **Weather sounds** - rain and wind loops that follow the weather, thunder cracks in storms
- **Wider garage alignment sliders** - camber, toe, ride height, wheel offset and tire width run to 3x their stock range, and out-of-range setups persist and apply on spawn (nothing is unlocked)
- **Rainbows** after rain when the sun comes through (drawn on a world mesh, so it renders in TXR)
- **Night-sky nebula** - a faint nebula band that fades in at night (optional, stylistic)
- **Dynamic wet grip** - tire grip drops in the rain and recovers as it dries, for every car including the AI rivals, and it works in PA battles
- **Photo mode camera unlocked** - no collision (fly anywhere), no distance cap, a much wider zoom range, faster free-cam, and the photo vignette off for clean shots
- **Hide HUD vignette** - optional cleaner look for screenshots / photo driving
- Auto-exposure / photomode aperture (ported from VEAO)
- Fully compatible with manual time adjustments done by CoolConsoleCommands by Shibexd, i will implement my own soon

## How this differs from Ultra Dynamic TXR 1.34
TXR Weather Mod V3 is a **ground-up rewrite** of the Ultra Dynamic TXR 1.34 weather system - it
shares the same goal (driving Ultra Dynamic Sky/Weather inside TXR) but **none of the 1.34 code**.

- **Architecture.** 1.34 was a single ~6,700-line `main.lua` monolith plus a handful of loose helper
  scripts. V3 is a modular system: a small bootstrap + one focused module per feature under
  `Scripts/systems/`, a single `config.lua` tuning surface, and per-module on/off toggles.
- **Stability.** The rain/dry-enforcement and parking-area persistence paths were rebuilt and hardened
  (the long-standing "stuck rain on preset change" and PA state issues). New visual features use a
  deferred, game-thread "settle gate" apply so they can't corrupt actors during level load.
- **What's the same idea, done cleaner.** Weather presets, time-of-day, lightning, fog, stars,
  and vehicle-aware headlights all exist in both - V3 reimplements them and tends to drive them through
  Ultra Dynamic Sky/Weather's own functions rather than ad-hoc property pokes.
- **What's new in V3 (not in 1.34).** Auto-exposure (ex-VEAO) on a 144-step day/night curve,
  exposure-driven auto headlights with animated pop-ups + a controller light-button gesture, a weighted
  time-of-day-aware random weather scheduler, dawn/dusk slow-time, Tokyo city glow, volumetric cloud
  light rays, wind debris, moon phases, rainbows, a night-sky nebula, audible weather sounds, wider
  garage alignment sliders, a night-only time cycle, a cinematic daytime sky pass, per-weather
  exposure compensation, and an installer with Engine.ini graphics profiles.
- **What 1.34 had that V3 deliberately leaves out.** Surface/vehicle wetness and screen-space weather
  effects (rain-on-lens, frost) - they rely on material/post-process paths the game doesn't composite,
  so they never rendered reliably; V3 focuses on the effects that actually show in TXR.

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
| `Alt+Q` | Headlights on / off (manual; also toggles the displayed car in the garage). Auto mode is set in config |
| `Alt+B` / `Alt+Shift+B` | Headlight brightness (up / down) |
| `Alt+L` / `Alt+Shift+L` | Re-apply shadow distance |

In **manual** headlight mode you can also use the car's own light button (keyboard or
controller): a short press turns the headlights on, a ~2-second hold turns them off.

## Configuration
All settings live in `TXR_Weather_V3/Scripts/config.lua`. Highlights:
- `Config.Weather.Enabled = false` - time-of-day + visuals only, no weather (presets/rain/cycling off).
- `Config.ModuleToggles` - turn individual modules on/off.
- `Config.TimeOfDay.NightOnly = true` - the night-only cycle (dusk -> night -> dawn, repeat).
- `Config.CinematicSky` - the daytime look pass: cloud density/silver lining/cirrus/color knobs (on by default).
- `Config.Rainbow` / `Config.SpaceLayer` - rainbows and the night-sky nebula (both on; tune or disable).
- `Config.WetGrip` - dynamic wet grip: grip floors, the full-wet rain threshold, and wet/dry timing (on by default).
- `Config.PhotoMode` - photo mode camera unlocks: collision, distance, zoom range, and speed (on by default).
- `Config.Audio` - weather sound volumes and per-sound toggles (on by default).
- `Config.Tuning` - alignment slider widening factor and spawn re-apply (on by default).
- `Config.Vignette.Enabled = true` - hide the in-game HUD vignette for a cleaner photo look.

## Known issues
- **Pick an Engine.ini profile in the installer** (see above). Brightness, shadow-quality, and
  glass-reflection problems are almost always a skipped Engine.ini step or a custom/outdated one,
  not the mod.
- **High-beam flash resets the headlight brightness** back to default until the next brightness
  change (the game recomputes intensity on its own hi-beam path).
- **Rain in tunnels / odd sun & shadows indoors** - the game's tunnel meshes have no interior
  collision, so weather and lighting can't be occluded there from the mod.
- **Surface wetness and screen weather effects** - the game's road materials lack Ultra Dynamic
  Weather's wetness logic, and the game doesn't composite UDW's screen-space effects (rain-on-lens,
  frost, etc.), so those don't render. Not fixable from the mod; would need cooked content.
- **Transitions might be rough** i am working on ingame time of day/weather/brightness value GUI to easily report these events when noticed
## Credits
Inspired by **Silent**'s original Dynamic Day/Night Cycle. **EDGERUNN3R** took it further and made Ultra Dynamic TXR. This project was started together with **EDGERUNN3R**, who shared his early source and helped get it set up and understand UDS and UE4SS. TXR Weather Mod V3 is a full rewrite by **Ten** (andizla) and uses none of the original Ultra Dynamic TXR 1.34 code. The dynamic wet grip's global tire-table approach is credited to **Chrystales**. The alignment slider-widening approach is credited to **NadzW** and **FenderBender** (WheelOffsetUnlocker).

## License
[GPLv3](LICENSE). The mod drives Ultra Dynamic Sky/Weather; UDS content is not included.

See the [changelog](TXR_Weather_V3/CHANGELOG.md) for version history.
