# Changelog

All notable changes to TXR Weather Mod V3 are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [3.0.18] - 2026-06-27

### Changed
- **Auto headlights are more reliable.** They reconcile to the correct on/off state
  on course load, and the cast light plus the brightness boost now only show when a
  car's lights are actually on.
- **Reworked the dawn/dusk exposure ramp** for a smoother, better-matched day/night
  transition (still tuning).
- **Slower, smoother scheduled weather changes.**
- **Sharper close-range shadows** in the Photomode Engine.ini profile.

### Internal
- Removed unused modules and dead code.

## [3.0.17] - 2026-06-26

### Changed
- **Headlights follow the exposure brightness in Auto mode** instead of a fixed
  clock. The lights now switch on/off with the actual scene brightness (the
  exposure lens curve) with a hysteresis band so they do not flicker at the
  boundary. Falls back to time-of-day thresholds if the exposure module is off.
  Retractable pop-up headlights and lights in general work but might desync if
  spammed in the garage or during cutscenes, will fix later.
- **Smoother weather transitions.** Cloud coverage and fog now ramp to a new
  preset over `Config.CloudsFog.PresetTransitionSeconds` instead of snapping, so
  weather changes ease in to match the precipitation blend (no more abrupt pop).
- **Smoother exposure transitions.** Auto-exposure now interpolates continuously
  between its time-of-day slots instead of stepping every 30 minutes, removing the
  dawn/dusk brightness cliffs.

### Added
- **Headlight manual toggle, persistent.** Alt+Q is a clean manual on/off toggle
  (no more three-state cycle that desynced). Auto (exposure-driven) mode is set in
  config only (`Config.Headlights.Mode`). The manual on/off state and brightness
  level should persist across sessions.
- **Exposure tuning feedback keys.** Alt+D ("too dark") and Alt+Shift+D ("too
  bright") log the current time, weather, and exposure values so the right
  exposure slot can be nudged from the log.

### Known Issues
- Flashing the high-beams resets the headlight brightness back to default until the
  next brightness change (the game recomputes intensity on its own hi-beam path).

## [3.0.16] - 2026-06-25

### Added
- **Wind Debris**: UDW Niagara debris (leaves/dust) blowing through the air, scaled
  by the wind intensity of the current weather state (shows in windy / storm presets).
  `Config.WindDebris`.
- **Volumetric Cloud Light Rays**: UDS god-ray shafts that break down through gaps in
  the cloud cover, rendered by a Niagara system of additive ray cards. Shows in daytime
  under broken / overcast cloud. `Individual Clouds Light Rays` casts rays through
  natural cloud gaps (no cloud painting needed). `Config.LightRays`.
- **Moon appearance**: realistic moon phases (instead of a flat full disc), optional
  phase change over time, and a `Scale` knob for a bigger, cinematic moon. `Config.Moon`.

### Known Issues
- **Sun lens flare is not available.** UDS's filmic sun flare is a post-process material
  on UDS's own PostProcess component, which TXR does not composite, the same dead-end as
  the other screen-space effects. The module was built then left orphaned.
- **Screen-space / material weather effects** (screen droplets, frost, wetness/puddles)
  do not render in TXR (post-process not composited; road materials lack UDW's functions).
  Not fixable from the mod; would need cooked content.
- **Tunnel rain** is not fixable from Lua (tunnels have no overhead collision to occlude
  against).
- **Auto-headlights** - on/off timing works, but on some cars lamp meshes stay lit and
  pop-ups (e.g. AE86) don't actuate. Fix pending.
- **Pick an Engine.ini profile in the installer** for correct brightness/shadows/reflections.

## [3.0.15] - 2026-06-24

### Added
- **Random weather scheduler** (`systems/scheduler.lua`, Phase 11): auto-changes
  weather to a weighted-random preset on a randomized interval (default 3-8 min).
  All changes route through `Weather.Apply`, so the stable rain/dry/clouds/fog
  pipeline stays in the loop (not UDW's native random variation). A manual change
  or persistence restore re-arms the timer so it never overrides a deliberate pick.
- **`Config.Scheduler.TimeWeights`**: per-period (day/night/dawn/dusk) weight
  multipliers on top of the base pool. Default makes clear skies rare during the
  day so daytime isn't boring.
- **`Config.Scheduler.AllowPrecipitation`**: set `false` to keep the scheduler
  from ever picking rain/snow/dust (does not affect manual cycling).
- **New keybinds**: Alt+P (random preset now), Alt+Shift+P (force clear).
- **City glow** (`Config.Atmosphere`): light pollution + night sky glow, ramped in
  at night. Light pollution lights cloud bases warm amber (Tokyo city-haze look);
  night sky glow keeps nights from going pitch black. Tunable
  `LightPollutionMax` / `NightSkyGlowMax` and colors.

### Changed
- **Dawn/dusk slow-time** is now a fraction of normal speed
  (`Config.Transitions.SlowFactor`, default `0.40`) instead of a hardcoded value,
  and the post-window restore tracks `Config.TimeOfDay.DefaultSpeed`.
- **Photomode Engine.ini profile** retuned (Lumen reflection roughness, volumetric
  cloud/fog sampling, AO/GI denoiser, streaming and foliage LOD).

### Fixed
- **Stars re-enabled and the course-load crash (`0xC0000005`) fixed.** Rewrote
  `systems/stars.lua`: it no longer loads or writes the star texture object
  off-thread. It sets the `Simulate Real Stars` bool and calls UDS's own
  `Static Properties - Stars` on the game thread (UDS resolves its own texture),
  deferred past `BeginPlay` by a settle gate. Verified crash-free across course
  loads and PA transitions.

### Removed
- **Screen Droplets and tunnel-rain experiments** unwired from the active code
  (module files left orphaned for reference). Both confirmed non-functional in TXR
  (see Known Issues). Frees the Alt+D and Alt+U keys.

### Known Issues
- **Screen-space / post-process weather effects** (screen droplets, frost, heat
  distortion, wind fog) and **material wetness/puddles** do not render in TXR. The
  game does not composite UDW's post-process component onto the view, and the road
  materials lack UDW's material functions. Confirmed not fixable from the Lua mod;
  would require cooked content (a pak).
- **Tunnel rain** is not fixable from Lua: tunnels have no overhead collision on any
  query channel, so UDW's particle occlusion has nothing to trace against. Would
  require placed occlusion volumes via a content pak.
- **Auto-headlights** - on/off timing works, but on some cars the lamp meshes stay
  lit and pop-up headlights (e.g. AE86) don't actuate. Light-actuation fix pending.
- **Pick an Engine.ini profile in the installer.** Brightness, shadow, and
  glass-reflection issues are almost always a skipped Engine.ini step, not the mod.

## [3.0.14] - 2026-06-23

### Added
- **`Config.Weather.Enabled`** master switch - set `false` for time-of-day +
  visuals only (no weather presets, rain, or cycling). For "ToD only" setups.
- **Installer** (`install.bat` + `install.ps1`): detects the game via Steam,
  downloads UE4SS and the mod, sets up `Engine.ini` from a chosen graphics profile,
  and disables any old standalone VEAO.
- **Engine.ini profiles in the installer**: Photomode or Optimizations only, each with
  or without exposure, plus Minimal. The mod-required cvars (fog + the exposure set) are
  applied onto whichever profile, and `Config.Exposure.Enabled` is set to match.

### Changed
- **config.lua slimmed** (~560 → ~265 lines): comments trimmed; `Config.ModuleToggles`
  kept as the module on/off surface.

### Removed
- **Runtime engine-CVAR migration** (`core/cvars.lua`, `Config.Exposure.SetupCvars`,
  `Config.EnhancedFog`). Those exposure/fog cvars are init-time, so they ship in a
  minimal Engine.ini (placed by the installer) instead. Resolves the 3.0.13
  "runtime CVAR migration not applying" issue.
- Dead config blocks `Config.Shadows` (inert after the shadow revert) and
  `Config.Visuals` (unbuilt-feature stubs).

### Fixed
- **Alt+L / Alt+Shift+L** no longer error - rewired from the removed calibration
  nudge to `Shadows.Apply` (force re-apply shadow distance). Resolves the 3.0.13
  orphaned-keybind issue.

### Known Issues
- **Pick an Engine.ini profile in the installer.** Brightness, shadow-resolution/distance,
  and glass-reflection problems are almost always a skipped Engine.ini step or a
  custom/outdated file, not the mod.
- **Stars disabled by default** - course-load crash (`0xC0000005`); fix pending.
- **Auto-headlights** - on/off timing works, but on some cars the lamp meshes stay
  lit and pop-up headlights (e.g. AE86) don't actuate. Light-actuation fix pending.
- **Tunnels** - rain and lighting are wrong indoors (broken game map meshes; not fixable).
- **Wetness** (WIP) - only road markings get wet, not the road surface (missing material).

## [3.0.13] - 2026-06-18

### Added
- **Exposure module** (`systems/exposure.lua`, Phase 13): the standalone VEAO
  auto-exposure scheduler ported into V3. TOD-driven 48-slot scheduler that drives
  `r.SkylightIntensityMultiplier`, `r.Lumen.SkylightLeaking.ReflectionAverageAlbedo`
  and `r.EyeAdaptation.LensAttenuation`; garage forces the night slot. Runs on the
  TXR tick (self-throttled ~2 s) and issues console commands on the game thread.
- **`Config.Exposure`** block (enable, slot geometry, CVAR names, 48-slot table).
- **`Config.ModuleToggles`**: per-module on/off switch (nils the module handle so
  its tick/setup is skipped). Serves as both a debug bisection tool and a permanent
  feature-flag.
- **`core/cvars.lua`**: shared helper for applying console variables on the game
  thread.

### Fixed
- **Course-load crash (access violation, `0xC0000005`).** Root cause: the Stars
  module resolved a texture asset and wrote an object-typed UProperty off the game
  thread during `BeginPlay`, corrupting UE4SS reflection. Diagnosed via minidump
  analysis. Stars is disabled via `Config.ModuleToggles.Stars = false` until a
  proper fix lands (preload the texture at init / defer setup until world settled).

### Reverted
- **Shadow-system rework from 3.0.12.** `systems/shadows.lua` restored to the
  original adaptive FOV lookup-table implementation. The 3.0.12 "flat mode default"
  with a version-robust `applyDistance` that scanned and wrote **every**
  `DirectionalLightComponent` via `FindAllOf` crashed the game on v1.5; the original
  adaptive table works. `Config.Shadows` is currently inert (the restored module
  does not read it).

### Known Issues
- **Stars module disabled** pending the proper game-thread / preload fix.
- **Runtime engine-CVAR migration not yet applying.** Moving the Engine.ini
  exposure/fog CVARs (`r.EyeAdaptation.MethodOverride`, `r.fog`, `r.Lumen.SampleFog`,
  etc.) into the modules does not take effect in-game yet - keep those in Engine.ini
  for now. (Code is in place behind `Config.Exposure.SetupCvars` /
  `Config.EnhancedFog.SetupCvars`; investigation continues.)
- **Alt+L / Alt+Shift+L shadow keybinds are orphaned** after the shadow revert -
  they call calibration functions that no longer exist and log an error if pressed.

## [3.0.12] - 2026-06-17

### Added
- **Stars module** (`systems/stars.lua`, Phase 12): high-resolution real-stars night sky.
  Enables `Simulate Real Stars`, swaps in the 8k `Real Stars Texture`, and applies
  tiling/intensity once per course load (no per-tick cost). Runtime API:
  `UseHD()`, `UseOriginal()`, `Toggle()`, `SetIntensity()`, `GetStatus()`.
- **`Config.Stars`** block (`Enabled`, `HDStars`, `TexturePath`, `Tiling`, `Intensity`).
- **`Config.Shadows`** block: `Mode` (`flat` | `adaptive`), `FlatDistance`,
  `CascadeExponent`, `CalibrationStep`, `DistanceMin`, `DistanceMax`.
- **Live shadow calibration**: Alt+L / Alt+Shift+L raise/lower the flat shadow
  distance in real time and log the current FOV + distance, for re-deriving values
  on the current game version.
- **Shadow diagnostics**: a one-time `Sun light diagnostic` log line reporting the
  light found, which setter methods exist, and the before/after distance values.

### Changed
- **Shadows now default to `flat` mode.** A fixed `FlatDistance` is applied every
  tick (reasserted periodically) instead of the FOV lookup table, which was
  calibrated on game v1.1 and drifts on newer versions. The adaptive table is kept
  and selectable via `Config.Shadows.Mode = "adaptive"`.
- **Alt+L / Alt+Shift+L repurposed** from "apply shadow distance" to calibration
  nudge up/down (they previously both called the same apply function).
- **Logging**: file flushes are throttled (~0.5 s) instead of flushing on every
  line; WARN/ERROR still flush immediately so crash diagnostics are never lost.
- **Logging**: `Config.Logging.EnableConsoleLogging` is now honored (it was
  previously ignored and always printed). Default remains `true`.
- **Performance**: cached the `PlayerCameraManager` lookup in `shadows.lua`,
  cached the `time_of_day` module require in `clouds_fog.lua`, and skipped
  redundant per-tick UDS writes / property read-backs in `atmosphere.lua`
  (god rays, aurora).
- Removed the dead `Config.Visuals.Stars` stub (superseded by `Config.Stars`).
- Version bumped to 3.0.12.

### Fixed
- **Shadow distance was a silent no-op on game v1.5.** `applyDistance` now tries
  several sun-light property names, falls back to scanning all
  `DirectionalLightComponent`s, and writes the underlying properties directly when
  the setter methods are absent.
- **Invalid FOV reads** (`GetFOVAngle` returning 0 during camera transitions /
  course load) no longer spike shadow distance to maximum for a frame - non-positive
  reads are now rejected and the last good distance is kept.

### Known issues / in progress
- The adaptive `FOV_DISTANCE_TABLE` is still calibrated for game v1.1. Recalibration
  for v1.5 is pending in-game measurements (use the Alt+L / Alt+Shift+L tool).
- Stars: if the HD texture is not yet loaded at course-load time it may not swap in
  (real stars still enable with the default texture, with a warning logged); a
  deferred-retry can be added if needed.

---

## [3.0.11] - prior
- Phase 9 & 10: Atmospheric enhancements (god rays, aurora, cloud shadows), auto
  headlights and brightness control.

## [3.0.10] - prior
- Phase 8: Dawn/Dusk transitions (slow time, Tokyo tint).

## [3.0.9] - prior
- Phase 6.5: Shadow FOV scaling system with lookup table.

## [3.0.8] - prior
- Phase 7: Lightning & Enhanced Fog systems.

## [3.0.7] - prior
- PA persistence fixes (Fix7), fresh file reads, invalid TOD validation.

## [3.0.0] - prior
- Initial modular rewrite of Ultradynamic TXR V1.34.
