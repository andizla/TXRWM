# TXR Weather Mod V3 - Reference

A modular UE4SS Lua mod for **Tokyo Xtreme Racer** that drives **Ultra Dynamic Sky / Weather
(UDS/UDW)**: time of day, weather, lighting, atmosphere, and exposure. This document is the
full feature + configuration + developer reference. For install and a short feature list, see the
landing `README.md`. For per-version changes, see `CHANGELOG.md`.

**Current version: 3.2.0**

---

## 1. What this is, and how it differs from Ultra Dynamic TXR 1.34

TXR Weather Mod V3 is a **ground-up rewrite** of the older Ultra Dynamic TXR 1.34 weather system.
Same goal - drive UDS/UDW inside TXR - but **none of the 1.34 code**.

| | Ultra Dynamic TXR 1.34 | TXR Weather Mod V3 |
|---|---|---|
| Structure | One ~6,700-line `main.lua` monolith + loose helper scripts | Small bootstrap + one focused module per feature under `Scripts/systems/`, single `config.lua` |
| Config | Scattered constants | One `config.lua` tuning surface + per-module `Config.ModuleToggles` |
| Stability | Recurring "stuck rain on preset change", PA state issues | Rain/dry + PA persistence rebuilt and hardened; new visuals use a deferred game-thread "settle gate" so they can't corrupt actors at level load |
| New visual features apply via | Ad-hoc property pokes | UDS/UDW's own `Static Properties - X` functions on the game thread |

**New in V3 that 1.34 did not have:** auto-exposure (ex-VEAO) on a 144-step day/night curve;
exposure-driven auto headlights with animated pop-ups and a controller light-button gesture; a
weighted, time-of-day-aware random weather scheduler; dawn/dusk slow-time + Tokyo tint; Tokyo city
glow (light pollution + night sky glow); volumetric cloud light rays; wind debris; moon phases and a
scalable moon; rainbows; a night-sky nebula; and an installer with Engine.ini graphics profiles.

**Intentionally dropped from 1.34:** surface/vehicle wetness and screen-space weather effects
(rain-on-lens, frost, heat distortion). They rely on material/post-process paths TXR does not
composite, so they never rendered reliably. See section 6.

---

## 2. Install and Engine.ini (summary)

Run `install.bat`. It auto-detects the Steam install, downloads UE4SS, installs the mod, registers
it in `mods.txt`, and writes `Engine.ini` from a graphics profile you pick (backing up any existing
file). Pick a profile - every profile ships the cvars the mod relies on (exposure + fog):

- **Photomode (+/- exposure)** - highest fidelity, heavier.
- **Optimizations only (+/- exposure)** - lighter, good for midrange / non-DLSS rigs.
- **Minimal** - only what the mod needs.

"Exposure" enables the mod's dynamic day/night exposure (the game's own auto-exposure steered by
the real sun - see Lighting and exposure below); "no exposure" leaves vanilla brightness. If dusk
or night look wrong, you most likely skipped the Engine.ini step - re-run the installer and pick
a profile. **Updating from 3.3.x or older: download a fresh `install.bat` + `install.ps1` first** -
old installer copies write an Engine.ini line that breaks the 3.4+ exposure.

Updates preserve your saved time-of-day/weather state, headlight settings and
`Logs/tuning_feedback.log`; `config.lua` intentionally resets to the new release defaults.

The base profile inis live in `engines/` (`photomode_engine.ini`, `optimization_only_engine.ini`).
The runtime copy excludes that folder; the installer composes the live `Engine.ini` from the chosen
base.

---

## 3. Keybinds

| Key | Action |
|-----|--------|
| `Alt+S` / `Alt+Shift+S` | Cycle weather preset next / previous |
| `Alt+P` / `Alt+Shift+P` | Random weather preset now / force Clear Skies |
| `Alt+T` | Cycle time speed (normal / fast / pause) |
| `Alt+R` | Reset weather to default |
| `Alt+Q` | Headlights on/off (manual). In the garage, toggles the displayed car (pop-ups animate). Auto mode is config-only and ignores this. |
| `Alt+B` / `Alt+Shift+B` | Headlight brightness up / down (0.5x / 1x / 2x / 3x / 5x) |
| `Alt+L` / `Alt+Shift+L` | Re-apply shadow distance |
| `Alt+D` / `Alt+Shift+D` | Exposure feedback: flag the picture as too dark / too bright (logs time + weather + applied exposure under tag `ExposureTune`, and appends the datapoint to `Logs/tuning_feedback.log` for easy sharing) |
| `Alt+Z` / `Alt+Shift+Z` | Skylight tuning: raise / lower the skylight leak albedo |
| `Alt+X` / `Alt+Shift+X` | Skylight tuning: raise / lower the skylight leak roughness |
| `Alt+C` / `Alt+Shift+C` | Skylight tuning: raise / lower the skylight intensity |
| `Alt+V` / `Alt+Shift+V` | Skylight tuning: log a datapoint (tag `SkylightTune`) / reset overrides back to the exposure curve |
| `Alt+W` / `Alt+Shift+W` | Force wetness / force dry (only if the WIP wetness module is enabled) |
| `Alt+J` | Toggle rain/snow particles off/on without changing the weather (the tunnel system drives the same mechanism automatically) |

In **manual** headlight mode you can also use the car's own light button (keyboard or controller):
a short press turns headlights on, a ~2-second hold turns them off.

---

## 4. Features (current)

### Time and weather
- **Time of day** with adjustable speed, pause, and persistence across sessions (`time_of_day.lua`).
- **Night-only mode** - *new in 3.3.0, off by default.* The cycle runs dusk, night, dawn, then jumps
  straight back to dusk - the day is skipped entirely, and dawn plays out in full before the jump.
  `Config.TimeOfDay.NightOnly` (skip points configurable); also an installer option.
- **Debug short cycle** - *new in 3.3.0, off by default.* Full-length dawn and dusk, but the flat
  midday and deep-night stretches are cut to about an hour each: a complete lighting cycle in
  minutes. `Config.TimeOfDay.DebugShortCycle`; wins over night-only if both are on.
- **13 weather presets** (`presets.lua` / `weather.lua`): Clear_Skies, Partly_Cloudy, Cloudy,
  Overcast, Foggy, Rain_Light, Rain, Rain_Thunderstorm, Snow_Light, Snow, Snow_Blizzard,
  Sand_Dust_Calm, Sand_Dust_Storm. Rain/dry enforcement here is **stable - do not modify**.
- **Random weather scheduler** (`scheduler.lua`): weighted pool with time-of-day multipliers and an
  `AllowPrecipitation` switch. A manual change re-arms the timer so it never overrides your pick.
- **Clouds and fog** (`clouds_fog.lua`): drift/jitter, day "mood", morning profiles, smooth
  preset ramps. **Enhanced fog** (`enhanced_fog.lua`) drives UDS `Scale Fog Density`.
- **Lightning** (`lightning.lua`): flashes for thunderstorm presets.
- **Dawn/dusk transitions** (`transitions.lua`): slow-time windows + a Tokyo tint. Since 3.4.0 the
  windows are keyed to the sun's real elevation, so they follow the seasons.
- **Seasons** - *new in 3.4.0.* The in-game calendar advances every in-game midnight (the game
  saves it), so sunrise/sunset drift through the year like real Tokyo. Pin a fixed date with
  `Config.RealSun.PinMonth` / `PinDay` if you prefer consistency.
- **Tunnels** - *new in 3.4.0* (`light_cycle.lua` containment + `weather.lua` suppression). Driving
  under covered road in daylight darkens the picture the way eyes would, and rain/snow stop
  falling inside and return at the exit portal. Uses the course's own covered-road volume data.
  Knobs in `Config.LightCycle` (`TunnelTrimScale`, `TunnelRainKill`, `TunnelAutoByBias`).
- **Parking Area weather** - *new in 3.4.0.* The PA continues your course weather and time of day
  with the clock running, instead of the canned always-night look. `Config.PA.Mode`:
  `"continue"` (default) / `"freeze"` / `"stock"`.
- **Weather sounds** (`audio.lua`) - *working since 3.2.0.* Rain and wind loops that follow the live
  weather intensity, plus distant/close thunder cracks on a randomized timer during thunderstorms.
  Played directly from the UDS sound assets (the weather system's own sound path is inert in TXR).
  Volumes and per-sound toggles in `Config.Audio`.
- **Persistence** (`persistence.lua`): saves and restores the exact sky/weather snapshot, including
  across the parking area (PA). **Stable - do not modify.**

### Sky and atmosphere
- **Stars** (`stars.lua`): UDS real-stars night sky (safe bool + `Static Properties - Stars` on the
  game thread, settle-gated).
- **Moon** (`moon.lua`): realistic phases, optional phase-over-time, and a `Scale` knob.
- **Atmosphere** (`atmosphere.lua`): god rays (the sun's screen-space light-shaft bloom, brightened
  and warm-tinted - driving the real v1.5 controls since 3.3.0), soft cloud shadows, **Tokyo city
  glow** (light pollution lighting the cloud bases + a night sky glow) ramped in at night, and an
  optional second cloud layer (high cirrus; works since 3.3.0 but ships off - significant GPU cost).
  (Auroras are off: TXR's content can't render them, see section 6.)
- **Cinematic sky** (`cinematic_sky.lua`) - *new in 3.3.0, on by default.* A daytime look pass:
  denser, darker cloud cores, stronger silver-lining glow, crisper cloud detail, visible high cirrus
  that lights up near the sun, richer sky color, luminous overcast, stronger sunset/sunrise colors,
  slower cloud drift, and time-lapse-coherent cloud movement. Unknown-range knobs are multipliers on
  the sky's stock values (fresh each course, never compounds); each apply logs stock -> tuned pairs
  under `CinematicSky` for data-driven retuning. `Config.CinematicSky`.
- **Volumetric cloud light rays** (`volumetric_light_rays.lua`): god-ray shafts through natural
  cloud gaps (Niagara ray cards).
- **Wind debris** (`wind_debris.lua`): leaves/dust blowing through the air, scaled by wind intensity.
- **Rainbow** (`rainbow.lua`) - *new in 3.0.20.* UDW's rainbow, drawn on a world mesh (not a screen
  post-process), so it renders in TXR. UDW decides when it shows from the weather state: rain or fog
  feeding it, the camera in direct sun (not under overcast), and the sun low enough. On by default.
- **Night-sky nebula / Space Layer** (`space_layer.lua`) - *new in 3.0.20.* A faint nebula band
  rendered into the sky like the stars/moon, fading in at night. Stylistic - on at a modest
  intensity, easy to disable.

### Lighting and exposure
- **Dynamic exposure** (`light_cycle.lua`) - *reworked in 3.4.0.* The game's own auto-exposure
  stays in charge; the mod steers it through the sky system's native exposure-bias controls,
  driven by the sun's REAL elevation (`Config.LightCycle.BiasCurve`, EV vs sun angle). Dusk and
  dawn land wherever the sun actually is - any date, any season - and brightness self-normalizes
  across weathers. Tunnel exposure trim rides the same system. Requires the 3.4 Engine.ini
  (re-run the installer). Live **skylight tuning keybinds** still apply (`Alt+Z/X/C`, confirm
  with `Alt+V` - see Keybinds). The pre-3.4 fixed 144-slot curve (`exposure.lua`) remains as a
  config fallback (`Config.Exposure.Enabled` + `OutputMode = "cvars"`, needs the old
  MethodOverride line back).
- **Headlights** (`headlights.lua`): Auto mode follows the exposure brightness (with hysteresis) so
  the lamps track available light; manual mode (`Alt+Q`, the garage, and the light-button gesture);
  adjustable brightness; animated pop-ups via the game's native raise/lower.
- **Shadows** (`shadows.lua`): adaptive FOV-to-distance table so shadows survive photo-mode zoom.

### Driving
- **Dynamic wet grip** (`wet_grip.lua`) - *new in 3.1.0.* Tire grip drops as the road gets wet and
  recovers as it dries, scaling with the live rain intensity (wets up fast, dries off slowly). It is
  driven into the global tire model, so it applies to every car including the AI rivals and works in
  parking-area battles. Cornering grip is hit a little harder than longitudinal. Tunable floors and
  wet/dry timing in `Config.WetGrip`. On by default. Grip approach credited to Chrystales.
- **Wider alignment sliders** (`tuning.lua`) - *new in 3.2.0.* The garage alignment sliders (camber,
  toe, ride height, wheel offset, tire width) run to `RangeMultiplier` x their stock range (default
  3x), the displayed car previews values beyond stock live, and out-of-range values are re-applied
  to the car on spawn (the game saves them but does not apply extremes on load by itself). Locked
  settings stay locked - nothing is unlocked. `Config.Tuning`. Approach credited to NadzW and
  FenderBender (WheelOffsetUnlocker).

### Photo mode and quality-of-life
- **Photo mode camera unlock** (`photomode.lua`) - *new in 3.1.0.* Frees the Advanced Photo Mode free
  camera: no collision (fly through geometry and off the track), no distance cap, a much wider orbit
  pan, and a much wider zoom range at both ends (closer macro, wider angle). Free-camera movement is
  faster, rotation scales with the zoom so tight framing isn't twitchy, and the photo-mode vignette
  starts off. On by default; `Config.PhotoMode`.
- **Hide HUD vignette** (`vignette.lua`) - *new in 3.0.20, OFF by default.* Removes the darkened
  corner vignette the game draws during normal play (`WBP_Com_Vignette_Frame` on the in-game HUD).
  It's a HUD overlay, not a render setting, so Engine.ini can't touch it - this can. Pure HUD-widget
  toggle, no game files touched.

---

## 5. Configuration

All settings live in `Scripts/config.lua`. Each feature has its own `Config.X` block (commented in
place). General highlights:

- `Config.Weather.Enabled = false` - time-of-day + visuals only, no weather (presets/rain/cycling off).
- `Config.ModuleToggles` - hard on/off per module (the handle is nil-ed in `main.lua`, so the module's
  tick/setup never runs). Core modules (Actors/Presets/Keybinds) are not toggleable.
- `Config.LightCycle.BiasCurve` - the day/night exposure shaping: EV bias vs sun elevation
  (negative = darker; anchors interpolate). Use the `Alt+D` / `Alt+Shift+D` feedback keys, then
  grep the log for `ExposureTune` to see the sun elevation to nudge. Every feedback keypress is
  also appended to `Logs/tuning_feedback.log` - a small, session-marked file that is perfect to
  attach when reporting exposure that looks wrong (no need to send full session logs).
- `Config.LightCycle.TunnelTrimScale` / `TunnelRainKill` / `TunnelAutoByBias` - tunnel handling:
  how hard tunnels darken in daylight, whether rain cuts inside covered road, and whether the
  course's own covered-road data picks the volumes (set `TunnelAutoByBias = false` to fall back
  to the curated `TunnelVolumes` list only).
- `Config.PA.Mode` - parking-area weather: `"continue"` (default), `"freeze"`, `"stock"`.
- `Config.RealSun.PinMonth` / `PinDay` - pin the calendar to a fixed date (default: seasons drift).
- `Config.Headlights.Mode` - `"auto"` (exposure-driven, untouchable at runtime), `"force_on"`, or
  `"force_off"` (manual; `Alt+Q` toggles). Manual on/off + brightness persist across restarts.

Feature blocks of note:
- `Config.TimeOfDay.NightOnly` - the night-only cycle (dusk -> night -> dawn -> dusk), with
  `NightOnlySkipFrom` / `NightOnlySkipTo` to move the day-skip points.
- `Config.TimeOfDay.DebugShortCycle` - the short cycle (full dawn/dusk, ~1h day and night cores),
  with `ShortCycleDaySkipFrom/To` and `ShortCycleNightSkipFrom/To` to move the four jump points.
  `FastSpeed` (Alt+T fast mode) is also here - default is a full day in about two minutes.
- `Config.CinematicSky` - the daytime look pass. Multiplier knobs for cloud density, silver lining,
  detail, cirrus wisps, overcast luminance, sunset strength, cloud drift speed; absolute
  `Saturation`; render-quality sample multipliers (ship at 1.0 - raise deliberately, GPU cost).
- `Config.PhotoMode` - camera collision/distance/orbit unlocks, the zoom-range floor/ceiling and step,
  free-cam movement and rotation scaling, and the photo-mode vignette default.
- `Config.WetGrip` - `MinGripMult` / `MinSideGripMult` (grip floors at full wet), `PrecipForFullWet`,
  snow handling, and the `WetRiseSeconds` / `DrySeconds` wet/dry timing.
- `Config.Rainbow` - `MaxStrength` / mask caps (nil = UDW defaults).
- `Config.SpaceLayer` - `NebulaIntensity`, colors, brightness, `SetDBuffer`.
- `Config.Vignette` - `Enabled` (default false), `Hide`.
- `Config.Audio` - per-sound enables + `RainVolume` / `WindVolume` / `ThunderVolume`.
- `Config.Tuning` - `RangeMultiplier` (slider widening factor), `ReapplyOnLoad`, `SkipLockedRows`.

---

## 6. What does NOT render in TXR, and why

These are confirmed dead-ends - do not re-attempt without cooked content. TXR renders UDS/UDW
effects that come from **scene components** (Niagara particles, lights, exponential height fog, the
sky/atmosphere/stars/moon, and mesh-drawn effects), but does **not** composite either actor's
`PostProcess` component, and the game's own materials don't include UDW's material functions.

- **Screen-space post-process effects** - Screen Droplets (rain-on-lens), Screen Frost, Heat
  Distortion, Post Process Wind Fog, and the UDS Sun Lens Flare. These are weighted blendables on a
  `PostProcess` component TXR doesn't run. Screening rule: a feature with a `... MID` **and** a
  `... WB` (weighted blendable) is post-process = dead in TXR.
- **Material-function effects** - surface wetness, puddles, glass rain drips, DLWE, foliage wind,
  water rain ripples. The game's road/ground materials don't sample UDW's parameters, and material
  graph nodes can't be added from Lua. (`wetness.lua` exists but is disabled - logic runs, nothing
  draws.)
- **Tunnel rain** - tunnels have no overhead query collision on any channel, so UDW can't occlude
  rain inside them. Not fixable from Lua.
- **Auroras** - the 2D aurora is a sky-material shader that samples UDS's `Aurora_Clouds` texture,
  and that texture is not in TXR's cooked content (a runtime load fails). UDS happily computes the
  aurora as active, but the shader has nothing to draw. Would need cooked content (pak) to revive;
  the module machinery is kept behind `Config.Atmosphere.EnableAurora = false`.
- **UDW's own weather sounds** - the native sound path (enable + volumes + its apply functions) runs
  but never plays in TXR. Weather audio works via directly spawned 2D sounds instead (see
  `audio.lua`).

**Rainbow is NOT in this list** (3.0.20): it has a `Rainbow MID` but no weighted blendable - it's
drawn on `Rainbow Mesh` with `Rainbow Material 2D` / `Rainbow Material Volumetric`, i.e. scene-
rendered, so it works.

---

## 7. Architecture notes (for developers)

- **Entry / loop.** `main.lua` loads `config` + core (`logging`, `utils`, `state`), then the system
  modules, and runs an 8 Hz (`Config.MainLoop.TickIntervalMs = 125`) `LoopAsync` loop calling each
  module's `Tick`. All tick logic is wrapped in `pcall` so a module error never crashes the game.
- **Off-thread footgun.** TXR calls the tick inside its `LoopAsync` callback with no
  `ExecuteInGameThread`, so module ticks run on UE4SS's **async thread**. Primitive reads/writes on
  UDS/UDW are tolerated, but: (1) `r.*` render cvar console commands **must** be marshalled to the
  game thread (`Utils.ExecConsoleCommands` does this), and (2) object-typed writes / asset loads
  during `BeginPlay` can corrupt reflection and hard-crash.
- **Proven safe pattern for new native visuals** (stars / moon / wind debris / light rays / rainbow /
  space layer): set the primitive bools/scalars, then call the feature's own
  `Static Properties - <feature>` function **on the game thread**, **deferred** past BeginPlay by a
  ~32-tick settle gate (`SETTLE_TICKS`). The one-shot modules reset their gate when off-course.
- **Do-not-touch zones:** the rain particles + dry enforcement in `weather.lua`, and the PA
  persistence in `persistence.lua`. Both took long debugging and are stable.
- **Actor access.** `systems/actors.lua` owns discovery and caching: `Actors.GetUDS()`,
  `Actors.GetUDW()`, `Actors.IsOnCourse()`, `Actors.IsInGarage()`, plus safe property/function
  helpers. UDS is `Ultra_Dynamic_Sky_C`; UDW is the UDS actor's `"Ultra Dynamic Weather"` property.
- **Adding a module.** Create `systems/<name>.lua` returning a table with `Init`/`Tick`; in
  `main.lua` add a `safeRequire` + `Init` in `loadSystemModules`, a `Tick` call in `onTick`, a
  `ModuleToggles` line, and a return-table entry; add a `Config.<Name>` block.

### Key property/function names (verified in the v1.5 dump)
```
-- Time / weather
UDS["Time Of Day"]                 -- 0-2400
UDS["Simulation Speed"]            -- 0 = pause
UDW["Change Weather"](preset, seconds)
UDW["Cloud Coverage"], ["Rain"], ["Fog"], ["Thunder/Lightning"], ["Wind Intensity"]  -- 0-10
-- Visuals
UDW["Enable Rainbow"]; UDW["Static Properties - Rainbow"]
UDS["Render Nebula"], ["Space Glow Brightness"]; UDS["Static Properties - Space Layer"]   -- needs r.DBuffer 1
-- Dynamic wet grip (global tire model)
DT "/Game/ITSB/Core/Quest/DT_TireDegradationInfo" -> rows' Max/Cliff/Min(Side)GripRate
-- Photo mode
BPC_PhotoMode_C, BP_FreeCamera_C; WBP_PhotoMode_Bar_Slider_C (ListKey "FOV")
```

---

## 8. Version history

See `CHANGELOG.md` for the full list. Most recent:

- **3.4.0** - New exposure engine (rides the game's own auto-exposure, driven by the sun's real
  elevation - re-run the installer); seasons (the calendar advances and sunrise/sunset drift like
  real Tokyo, pinnable); tunnels handled properly (daylight exposure adaptation + rain stops under
  covered road); the Parking Area continues your course weather with the clock running; sun-synced
  dawn/dusk slow-time; cloudy-night city-glow floor; `Alt+J` manual rain toggle.
- **3.3.1** - Transition crash hardening; course loads settle in seconds; headlight brightness
  and auto-timing fixes; dawn/dusk exposure retune from feedback datapoints; exposure feedback
  side-channel (`Logs/tuning_feedback.log`).
- **3.3.0** - Night-only mode (dusk -> night -> dawn, repeat); debug short cycle
  (full dawn/dusk, ~1h day and night cores); cinematic daytime sky (cloud shading, cirrus, color
  grade, golden hour); god rays fixed (first time actually working); per-weather exposure
  compensation; skylight tuning keybinds; exposure/skylight baseline retune (paint keeps sky
  reflections in shade, earlier and brighter dusk ramp); 2x faster fast-forward;
  garage-transition crash fixed; Engine.ini profiles reworked (car-paint reflections, TSR
  ghosting/pattern fixes, GI shimmer fixes, cleaned optimization profile - re-run the installer).
- **3.2.0** - Weather sounds (rain/wind/thunder, audible for the first time); wider garage alignment
  sliders with persistence (camber/toe/ride height/offset/tire width, 3x stock range); auroras
  retired as unrenderable in TXR; quieter release logging.
- **3.1.0** - Photo mode camera unlocked (no collision/distance cap, much wider zoom, faster
  free-cam, vignette off); dynamic wet grip (grip drops in the rain for every car incl. AI, works
  in PA).
- **3.0.20** - Rainbows (reclassified as mesh-rendered, now enabled); night-sky nebula (Space Layer);
  optional hide-HUD-vignette.
- **3.0.19** - Animated pop-up headlights; garage headlight control on `Alt+Q`; manual light-button
  gesture; 144-slot exposure + brightened dusk; PA-exit flash fix; faster garage detection.
- **3.0.18** - Auto headlights reconcile on load + owner-gated cast/brightness; reworked dawn/dusk
  exposure ramp; smoother scheduled changes; sharper close shadows; cleanup.
- **3.0.17** - Exposure-driven auto headlights; persistent manual toggle; continuous exposure/weather
  interpolation; exposure feedback keys.
- **3.0.16** - Wind debris, volumetric cloud light rays, moon appearance.
- **3.0.15** - Random scheduler; Tokyo city glow; stars crash-fixed + re-enabled.
