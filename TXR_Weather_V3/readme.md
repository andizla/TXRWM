# TXR Weather Mod V3: Reference

A modular UE4SS Lua mod for **Tokyo Xtreme Racer** that drives **Ultra Dynamic Sky / Weather
(UDS/UDW)**: time of day, weather, lighting, atmosphere, and exposure. This document is the
full feature + configuration + developer reference. For install and a short feature list, see the
landing `README.md`. For per-version changes, see `CHANGELOG.md`.

**Current version: 3.7.0**

---

## 1. What this is, and how it differs from Ultra Dynamic TXR 1.34

TXR Weather Mod V3 is a **ground-up rewrite** of the older Ultra Dynamic TXR 1.34 weather system.
Same goal, drive UDS/UDW inside TXR, but **none of the 1.34 code**.

| | Ultra Dynamic TXR 1.34 | TXR Weather Mod V3 |
|---|---|---|
| Structure | One ~6,700-line `main.lua` monolith + loose helper scripts | Small bootstrap + one focused module per feature under `Scripts/systems/`, single `config.lua` |
| Config | Scattered constants | One `config.lua` tuning surface + per-module `Config.ModuleToggles` |
| Stability | Recurring "stuck rain on preset change", PA state issues | Rain/dry + PA persistence rebuilt and hardened; new visuals use a deferred game-thread "settle gate" so they can't corrupt actors at level load |
| New visual features apply via | Ad-hoc property pokes | UDS/UDW's own `Static Properties - X` functions on the game thread |

**New in V3 that 1.34 did not have:** auto-exposure (ex-VEAO) on a 144-step day/night curve;
exposure-driven auto headlights with animated pop-ups and a controller light-button gesture; a
weighted, time-of-day-aware random weather scheduler; dawn/dusk slow-time + Tokyo tint; Tokyo city
glow (light pollution + night sky glow); a real-star night sky with the Milky Way that rotates like
the real thing; volumetric cloud light rays; wind debris; moon phases and a scalable moon; rainbows;
and an installer with Engine.ini graphics profiles.

**Intentionally dropped from 1.34:** surface/vehicle wetness and screen-space weather effects
(rain-on-lens, frost, heat distortion). They rely on material/post-process paths TXR does not
composite, so they never rendered reliably. See section 6.

---

## 2. Install and Engine.ini (summary)

Run `install.bat`. It auto-detects the Steam install, downloads UE4SS, installs the mod, registers
it in `mods.txt`, and writes `Engine.ini` from a graphics profile you pick (backing up any existing
file). Pick a profile, every profile ships the cvars the mod relies on (exposure + fog):

- **Photomode (+/- exposure)**, highest fidelity, heavier.
- **Optimizations only (+/- exposure)**, lighter, good for midrange / non-DLSS rigs.
- **Minimal**, only what the mod needs.

"Exposure" enables the mod's dynamic day/night exposure (the game's own auto-exposure steered by
the real sun, see Lighting and exposure below); "no exposure" leaves vanilla brightness. If dusk
or night look wrong, you most likely skipped the Engine.ini step, re-run the installer and pick
a profile. **Updating from 3.3.x or older: download a fresh `install.bat` + `install.ps1` first**:
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
| `Alt+K` / `Alt+Shift+K` | Night sky glow down / up (live look tuning; logged under tag `StarTune`). Glow never affects the stars, tune it freely |

In **manual** headlight mode you can also use the car's own light button (keyboard or controller):
a short press turns headlights on, a ~2-second hold turns them off.

---

## 4. Features (current)

### Time and weather
- **Time of day** with adjustable speed, pause, and persistence across sessions (`time_of_day.lua`).
- **Night-only mode**: *new in 3.3.0, off by default.* The cycle runs dusk, night, dawn, then jumps
  straight back to dusk, the day is skipped entirely, and dawn plays out in full before the jump.
  `Config.TimeOfDay.NightOnly` (skip points configurable); also an installer option.
- **Debug short cycle**: *new in 3.3.0, off by default.* Full-length dawn and dusk, but the flat
  midday and deep-night stretches are cut to about an hour each: a complete lighting cycle in
  minutes. `Config.TimeOfDay.DebugShortCycle`; wins over night-only if both are on.
- **Weather presets** (`presets.lua` / `weather.lua`). The active rotation *(since 3.7.0)* is six
  dry skies: Clear_Skies, Partly_Cloudy, Cloudy, Overcast, Overcast_Heavy *(new in 3.6.0: a
  denser, properly grey deck)*, Foggy. Cloudy presets carry their own cool/grey sky grade
  (per-preset `skyGrade`). Precipitation presets (rain/snow/dust tiers) are out of the rotation
  for performance and particle-material reliability; their data is retained in `presets.lua` for
  a future return, and old saves holding one fall back to the default preset.
  Rain/dry enforcement here is **stable, do not modify**.
- **Random weather scheduler** (`scheduler.lua`): weighted pool with time-of-day multipliers and an
  `AllowPrecipitation` switch. A manual change re-arms the timer so it never overrides your pick.
- **Clouds and fog** (`clouds_fog.lua`): drift/jitter, day "mood", morning profiles, smooth
  preset ramps. **Enhanced fog** (`enhanced_fog.lua`) drives UDS `Scale Fog Density`.
- **Lightning** (`lightning.lua`): flashes for thunderstorm presets.
- **Dawn/dusk transitions** (`transitions.lua`): slow-time windows + a Tokyo tint. Since 3.4.0 the
  windows are keyed to the sun's real elevation, so they follow the seasons.
- **Seasons**: *new in 3.4.0.* The in-game calendar advances every in-game midnight (the game
  saves it), so sunrise/sunset drift through the year like real Tokyo. Pin a fixed date with
  `Config.RealSun.PinMonth` / `PinDay` if you prefer consistency.
- **Tunnels and overpasses**: *reworked in 3.5.0* (`tunnels.lua`). Fog is removed under roofs
  (global fog is blind to ceilings; foggy weather used to read as a white wall inside bores),
  detection reading the game's own road data (each road point carries a "roofed" attribute, so
  boundaries are exact and every real bore is covered). Also fixes the covered-section lighting:
  the course's covered-road volumes ship with a skylight-leak override that floods interiors with
  flat sky ambient at the volume edge; the mod clears it so tunnel light stays true to the scene
  (see Exposure below). The under-roof rain suppression (hide, keep simulating, instant return
  past the portal) is idle while no wet preset is in the rotation. Knobs in `Config.Tunnels`
  (`TunnelRainKill`, `OverpassRainKill`, `CoveredFogMult`, `KillVolumeSkylightLeak`).
- **Parking Area weather**: *new in 3.4.0.* The PA continues your course weather and time of day
  with the clock running, instead of the canned always-night look. `Config.PA.Mode`:
  `"continue"` (default) / `"freeze"` / `"stock"`.
- **Persistence** (`persistence.lua`): saves and restores the exact sky/weather snapshot, including
  across the parking area (PA). **Stable, do not modify.**
  (The weather-sounds module from 3.2.0 was removed in 3.7.0 along with the precipitation
  rotation; without rain and thunder it had nothing to play.)

### Sky and atmosphere
- **Stars** (`stars.lua`): *fixed for real in 3.7.0.* The real-star night sky, Milky Way band
  included, rotating with time like the actual sky (`Config.Stars.SimulateRealStars`), fading
  naturally at twilight and under cloud cover. Star brightness rides `Config.Stars.Intensity`
  and, inversely, the city-glow light pollution level: the sky material dims stars as light
  pollution rises (realistic), and pollution above 1.0 inverts the math entirely, which is what
  made stars render as black dots in 3.0.15 through 3.6.0. Keep
  `Config.Atmosphere.LightPollutionMax` at or below 1.0.
- **Moon** (`moon.lua`): realistic phases, optional phase-over-time, and a `Scale` knob.
- **Atmosphere** (`atmosphere.lua`): god rays (the sun's screen-space light-shaft bloom, brightened
  and warm-tinted, driving the real v1.5 controls since 3.3.0), soft cloud shadows, **Tokyo city
  glow** (light pollution lighting the cloud bases + a night sky glow) ramped in at night, and an
  optional second cloud layer (high cirrus; works since 3.3.0 but ships off, significant GPU cost).
  Night sky glow is independent of the stars and freely tunable (`Alt+K` live); light pollution
  must stay at or below 1.0 (see Stars above). (Auroras are off: TXR's content can't render them,
  see section 6.)
- **Cinematic sky** (`cinematic_sky.lua`): *new in 3.3.0, on by default.* A daytime look pass:
  denser, darker cloud cores, stronger silver-lining glow, crisper cloud detail, visible high cirrus
  that lights up near the sun, richer sky color, luminous overcast, stronger sunset/sunrise colors,
  slower cloud drift, and time-lapse-coherent cloud movement. Unknown-range knobs are multipliers on
  the sky's stock values (fresh each course, never compounds); each apply logs stock -> tuned pairs
  under `CinematicSky` for data-driven retuning. `Config.CinematicSky`.
- **Volumetric cloud light rays** (`volumetric_light_rays.lua`): god-ray shafts through natural
  cloud gaps (Niagara ray cards).
- **Wind debris** (`wind_debris.lua`): leaves/dust blowing through the air, scaled by wind intensity.
- **Rainbow** (`rainbow.lua`): *new in 3.0.20.* UDW's rainbow, drawn on a world mesh (not a screen
  post-process), so it renders in TXR. UDW decides when it shows from the weather state: rain or fog
  feeding it, the camera in direct sun (not under overcast), and the sun low enough. On by default.
- **Space Layer** (`space_layer.lua`): *off since 3.6.x.* The separate decal-rendered nebula
  layer; superseded by the real-star map's own Milky Way band (see Stars), which renders more
  reliably in TXR. Machinery kept behind `Config.SpaceLayer.Enabled`.

### Lighting and exposure
- **Exposure and look** (`light_cycle.lua`): *settled in 3.5.0, shaped in 3.5.1.* The
  game's own auto-exposure runs stock (it reads right once the covered-road skylight
  leak is fixed, see Tunnels above); adaptation runs fast into daylight and slow into
  the dark, like eyes. A sun-elevation bias curve (`Config.LightCycle.BiasCurve`, EV vs
  sun angle) ships with a gentle low-key tune: about two thirds of a stop under during
  the day, easing off through dusk, for a photographic look with deep blacks; set the
  anchors to 0 for the plain stock picture. Dusk and dawn land wherever the sun
  actually is, any date, any season. On top sits a **post-process look layer**
  (`Config.LightCycle.PostProcess`): per-course, log-verified overrides for bloom,
  vignette, interior global-illumination quality, shadow contrast, near-black lift,
  saturation and highlight rolloff, and it accepts any engine post-process field if you
  want to go further.
  Requires the 3.4+ Engine.ini (re-run the installer). Live **skylight tuning
  keybinds** still apply (`Alt+Z/X/C`, confirm with `Alt+V`, see Keybinds).
- **Headlights** (`headlights.lua`): Auto mode follows the sun's real elevation (with hysteresis) so
  the lamps come on at dusk and go off after sunrise in any season, and *since 3.6.0* also inside
  real tunnel bores (lone overpasses deliberately do not flash them; the rain trigger exists but is
  inert without wet presets); manual mode (`Alt+Q`, the garage, and the light-button gesture);
  adjustable brightness; animated pop-ups via the game's native raise/lower.
- **Display profiles (HDR/SDR)**: *new in 3.6.0.* The game applies a hidden shadow-lifting grade
  only on HDR output, so a look tuned on HDR crushes on SDR screens. The mod detects the display
  per session and on SDR backs the look off toward stock with a softer bias curve
  (`Config.LightCycle.DisplayProfile` = auto/hdr/sdr, tables in `Config.LightCycle.SDR`). `Alt+D`
  feedback lines carry the active profile.
- **Shadows** (`shadows.lua`): adaptive FOV-to-distance table so shadows survive photo-mode zoom.

### Driving
- **Dynamic wet grip** (`wet_grip.lua`): *new in 3.1.0, ships disabled since 3.7.0* (no rain in the
  rotation). Tire grip drops as the road gets wet and recovers as it dries, scaling with the live
  rain intensity (wets up fast, dries off slowly). Driven into the global tire model, so it applies
  to every car including the AI rivals and works in parking-area battles. Re-enable together with a
  precipitation preset via `Config.WetGrip.Enabled` + `Config.ModuleToggles.WetGrip`. Grip approach
  credited to Chrystales.
- **Wider alignment sliders** (`tuning.lua`): *new in 3.2.0.* The garage alignment sliders (camber,
  toe, ride height, wheel offset, tire width) run to `RangeMultiplier` x their stock range (default
  3x), the displayed car previews values beyond stock live, and out-of-range values are re-applied
  to the car on spawn (the game saves them but does not apply extremes on load by itself). Locked
  settings stay locked, nothing is unlocked. `Config.Tuning`. Approach credited to NadzW and
  FenderBender (WheelOffsetUnlocker).

### Photo mode and quality-of-life
- **Photo mode camera unlock** (`photomode.lua`): *new in 3.1.0.* Frees the Advanced Photo Mode free
  camera: no collision (fly through geometry and off the track), no distance cap, a much wider orbit
  pan, and a much wider zoom range at both ends (closer macro, wider angle). Free-camera movement is
  faster, rotation scales with the zoom so tight framing isn't twitchy, and the photo-mode vignette
  starts off. On by default; `Config.PhotoMode`.
- **Photo mode sessions** (*new in 3.6.0, sharpened in 3.7.0*): time of day freezes for the whole
  session (sun, shadows and clouds hold still, long exposures included) and exposure switches to
  manual metering so the aperture option genuinely drives brightness like a real camera. The
  session's base level follows the sun's position on the field-tuned 3.4.0 curve
  (`Config.PhotoMode.ManualCurve`); sessions opened inside covered road use a fixed indoor level
  instead of the sun (`Config.PhotoMode.CoveredLens`), so day shots in bores aren't black. Session
  detection is instant, and everything restores the moment you close photo mode
  (`Config.PhotoMode.FreezeTime` / `ManualExposure`).
- **Hide HUD vignette** (`vignette.lua`): *new in 3.0.20, ON by default.* Removes the darkened
  corner vignette the game draws during normal play (`WBP_Com_Vignette_Frame` on the in-game HUD).
  It's a HUD overlay, not a render setting, so Engine.ini can't touch it, this can. Pure HUD-widget
  toggle, no game files touched.

---

## 5. Configuration

All settings live in `Scripts/config.lua`. Each feature has its own `Config.X` block (commented in
place). General highlights:

- `Config.Weather.Enabled = false`, time-of-day + visuals only, no weather (presets/rain/cycling off).
- `Config.ModuleToggles`, hard on/off per module (the handle is nil-ed in `main.lua`, so the module's
  tick/setup never runs). Core modules (Actors/Presets/Keybinds) are not toggleable.
- `Config.LightCycle.BiasCurve`, the day/night exposure shaping: EV bias vs sun elevation
  (negative = darker; anchors interpolate). Use the `Alt+D` / `Alt+Shift+D` feedback keys, then
  grep the log for `ExposureTune` to see the sun elevation to nudge. Every feedback keypress is
  also appended to `Logs/tuning_feedback.log`, a small, session-marked file that is perfect to
  attach when reporting exposure that looks wrong (no need to send full session logs).
- `Config.Tunnels.TunnelRainKill` / `OverpassRainKill`, covered-road rain handling (idle while no
  wet preset is in the rotation): whether rain cuts inside covered road (the game's own road data
  marks roofed stretches exactly) and under lone overpass decks (a roof trace, with
  `OverpassTraceLength` setting the headroom).
- `Config.Atmosphere.LightPollutionMax`, the city-glow light-pollution peak. **Keep at or below
  1.0**: the sky material dims stars as pollution rises, and above 1.0 the star math inverts and
  stars render as dark dots. `Config.Atmosphere.NightSkyGlowMax` is the star-safe glow knob.
- `Config.Stars`: `SimulateRealStars` (the rotating real-star map with the Milky Way; false = a
  static tiling star texture), `Intensity`, `Tiling`.
- `Config.PA.Mode`, parking-area weather: `"continue"` (default), `"freeze"`, `"stock"`.
- `Config.RealSun.PinMonth` / `PinDay`, pin the calendar to a fixed date (default: seasons drift).
- `Config.Headlights.Mode`: `"auto"` (exposure-driven, untouchable at runtime), `"force_on"`, or
  `"force_off"` (manual; `Alt+Q` toggles). Manual on/off + brightness persist across restarts.

Feature blocks of note:
- `Config.TimeOfDay.NightOnly`, the night-only cycle (dusk -> night -> dawn -> dusk), with
  `NightOnlySkipFrom` / `NightOnlySkipTo` to move the day-skip points.
- `Config.TimeOfDay.DebugShortCycle`, the short cycle (full dawn/dusk, ~1h day and night cores),
  with `ShortCycleDaySkipFrom/To` and `ShortCycleNightSkipFrom/To` to move the four jump points.
  `FastSpeed` (Alt+T fast mode) is also here, default is a full day in about two minutes.
- `Config.CinematicSky`, the daytime look pass. Multiplier knobs for cloud density, silver lining,
  detail, cirrus wisps, overcast luminance, sunset strength, cloud drift speed; absolute
  `Saturation`; render-quality sample multipliers (ship at 1.0, raise deliberately, GPU cost).
- `Config.PhotoMode`, camera collision/distance/orbit unlocks, the zoom-range floor/ceiling and step,
  free-cam movement and rotation scaling, and the photo-mode vignette default.
- `Config.WetGrip`: `MinGripMult` / `MinSideGripMult` (grip floors at full wet), `PrecipForFullWet`,
  snow handling, and the `WetRiseSeconds` / `DrySeconds` wet/dry timing.
- `Config.Rainbow`: `MaxStrength` / mask caps (nil = UDW defaults).
- `Config.SpaceLayer`: `NebulaIntensity`, colors, brightness, `SetDBuffer`.
- `Config.Vignette`: `Enabled` (default false), `Hide`.
- `Config.Tuning`: `RangeMultiplier` (slider widening factor), `ReapplyOnLoad`, `SkipLockedRows`.

---

## 6. What does NOT render in TXR, and why

These are confirmed dead-ends, do not re-attempt without cooked content. TXR renders UDS/UDW
effects that come from **scene components** (Niagara particles, lights, exponential height fog, the
sky/atmosphere/stars/moon, and mesh-drawn effects), but does **not** composite either actor's
`PostProcess` component, and the game's own materials don't include UDW's material functions.

- **Screen-space post-process effects**: Screen Droplets (rain-on-lens), Screen Frost, Heat
  Distortion, Post Process Wind Fog, and the UDS Sun Lens Flare. These are weighted blendables on a
  `PostProcess` component TXR doesn't run. Screening rule: a feature with a `... MID` **and** a
  `... WB` (weighted blendable) is post-process = dead in TXR.
- **Material-function effects**, surface wetness, puddles, glass rain drips, DLWE, foliage wind,
  water rain ripples. The game's road/ground materials don't sample UDW's parameters, and material
  graph nodes can't be added from Lua. (`wetness.lua` exists but is disabled, logic runs, nothing
  draws.)
- **Native rain occlusion**: UDW's own weather-exposure occlusion never sees TXR's tunnel
  geometry (no usable overhead query collision), so rain would fall indoors if left to it. The
  mod's own covered-road detection (`tunnels.lua`) suppresses the particles instead; a few short
  bores with unusual meshes still slip through both its signals.
- **Auroras**, the 2D aurora is a sky-material shader that samples UDS's `Aurora_Clouds` texture,
  and that texture is not in TXR's cooked content (a runtime load fails). UDS happily computes the
  aurora as active, but the shader has nothing to draw. Would need cooked content (pak) to revive;
  the module machinery is kept behind `Config.Atmosphere.EnableAurora = false`.
- **UDW's own weather sounds**, the native sound path (enable + volumes + its apply functions) runs
  but never plays in TXR. (Versions 3.2.0-3.6.0 played weather audio via directly spawned 2D
  sounds; that module was removed with the precipitation rotation in 3.7.0.)

**Rainbow is NOT in this list** (3.0.20): it has a `Rainbow MID` but no weighted blendable, it's
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
  game thread (`Utils.ExecConsoleCommands` does this), (2) object-typed writes / asset loads
  during `BeginPlay` can corrupt reflection and hard-crash, (3) object searches
  (`FindFirstOf`/`FindAllOf`) and UFunction calls from the async thread can access-violate while
  the game frees objects (menu/map streaming): probing must be gated, settled once its answer is
  known, and event-driven where a hook already has the actor in hand (see `actors.lua`), and
  (4) a UFunction's `FName` parameter must be passed as an `FName(...)` userdata, never a bare
  Lua string (a bare string is a deterministic crash inside UE4SS's binding).
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

- **3.7.0**: night stars fixed for real (bright, rotating real-star sky with the
  Milky Way; the city-glow light pollution had been driving the sky's star math
  out of range since 3.0.15); course-map/menu crash fixed (background polling
  now settles instead of probing objects the game is freeing); photo mode
  meters correctly in covered road and sessions engage instantly;
  precipitation presets, weather sounds and wet grip removed from the rotation
  (performance; data and modules retained for a future return).
- **3.6.0**: crash fix for PA/world transitions; photo mode freezes time and the
  aperture works (manual metering on the 3.4.0 sun curve); Heavy Overcast preset +
  grey/cool grades for cloudy-wet weather; tiered thunder; auto headlights in
  tunnels and rain; HDR/SDR display profiles; skylight rework (no sky on glass,
  geometry-aware translucent lighting, low ambient floor).
- **3.5.1**: first shaped pass of the low-key photographic look (day sits under the
  meter, color survives the shade, skies keep their tone).
- **3.5.0**: Covered-road lighting fixed at the root (the volumes' skylight-leak override);
  exposure runs stock with a new configurable post-process look layer (bloom, shadows,
  reflections, interior GI); covered-road detection rebuilt on the game's own road data
  (exact portals, short bores covered); rain under roofs hidden instead of stopped
  (returns instantly); no fog under roofs; less Lumen shimmer; legacy slot-exposure
  system removed.
- **3.4.0**: New exposure engine (rides the game's own auto-exposure, driven by the sun's real
  elevation, re-run the installer); seasons (the calendar advances and sunrise/sunset drift like
  real Tokyo, pinnable); tunnels handled properly (daylight exposure adaptation + rain stops under
  covered road); the Parking Area continues your course weather with the clock running; sun-synced
  dawn/dusk slow-time; cloudy-night city-glow floor; `Alt+J` manual rain toggle.
- **3.3.1**: Transition crash hardening; course loads settle in seconds; headlight brightness
  and auto-timing fixes; dawn/dusk exposure retune from feedback datapoints; exposure feedback
  side-channel (`Logs/tuning_feedback.log`).
- **3.3.0**: Night-only mode (dusk -> night -> dawn, repeat); debug short cycle
  (full dawn/dusk, ~1h day and night cores); cinematic daytime sky (cloud shading, cirrus, color
  grade, golden hour); god rays fixed (first time actually working); per-weather exposure
  compensation; skylight tuning keybinds; exposure/skylight baseline retune (paint keeps sky
  reflections in shade, earlier and brighter dusk ramp); 2x faster fast-forward;
  garage-transition crash fixed; Engine.ini profiles reworked (car-paint reflections, TSR
  ghosting/pattern fixes, GI shimmer fixes, cleaned optimization profile, re-run the installer).
- **3.2.0**: Weather sounds (rain/wind/thunder, audible for the first time); wider garage alignment
  sliders with persistence (camber/toe/ride height/offset/tire width, 3x stock range); auroras
  retired as unrenderable in TXR; quieter release logging.
- **3.1.0**: Photo mode camera unlocked (no collision/distance cap, much wider zoom, faster
  free-cam, vignette off); dynamic wet grip (grip drops in the rain for every car incl. AI, works
  in PA).
- **3.0.20**: Rainbows (reclassified as mesh-rendered, now enabled); night-sky nebula (Space Layer);
  optional hide-HUD-vignette.
- **3.0.19**: Animated pop-up headlights; garage headlight control on `Alt+Q`; manual light-button
  gesture; 144-slot exposure + brightened dusk; PA-exit flash fix; faster garage detection.
- **3.0.18**: Auto headlights reconcile on load + owner-gated cast/brightness; reworked dawn/dusk
  exposure ramp; smoother scheduled changes; sharper close shadows; cleanup.
- **3.0.17**: Exposure-driven auto headlights; persistent manual toggle; continuous exposure/weather
  interpolation; exposure feedback keys.
- **3.0.16**: Wind debris, volumetric cloud light rays, moon appearance.
- **3.0.15**: Random scheduler; Tokyo city glow; stars crash-fixed + re-enabled.
