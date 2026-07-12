# Changelog

All notable changes to TXR Weather Mod V3 are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [3.5.1]: 2026-07-13

### Changed
- **First shaped pass of the low-key look**, tuned against photographic references.
  The picture sits about two thirds of a stop under the meter during the day (easing
  off through dusk and night so dark hours don't double-darken), a touch more
  saturation keeps color alive in the shade, and a softer highlight rolloff lets
  skies keep their tone instead of clipping to white. Everything lives in the config
  (`Config.LightCycle.BiasCurve` + `PostProcess`); set the bias anchors to 0 for the
  plain stock picture, and use `Alt+D` / `Alt+Shift+D` to log tuning feedback.

## [3.5.0]: 2026-07-13

### Changed
- **Covered-road lighting fixed at the root.** The course's covered-road volumes ship
  with a skylight-leak override that flooded tunnels and covered sections with flat
  sky ambient, and made the whole world's lighting visibly jump at every volume edge.
  The mod now clears it per course: interiors keep their true lighting (sun bounce +
  tunnel lamps), and portals no longer flip the picture. This turned out to be the
  root cause behind most historical "tunnel exposure" complaints.
- **Exposure runs stock.** With the lighting fixed, the game's own exposure pipeline
  reads right, so the mod's exposure shaping ships neutral (the sun-elevation bias
  curve is still there for tuning). Auto-exposure adaptation is slowed to a third of
  stock, eyes do not adapt at three stops per second.
- **A new look layer.** The mod now applies a small set of post-process refinements
  per course, each verified in the log: less bloom, no vignette, higher screen-space
  reflection quality, finer interior global illumination, and neutralized shadow
  lifting (film toe + local exposure) so unlit areas keep real contrast. All of it is
  configurable through `Config.LightCycle.PostProcess`, which accepts any of the
  engine's 246 post-process fields.
- **Covered-road detection rebuilt on the game's own road data.** Every vehicle tracks
  a per-road-point "roofed" attribute; the mod now reads it directly. Boundaries are
  exact at the portal, and every real bore is covered, including the short tunnels
  the previous volume/trace detection missed. A roof trace remains for lone overpasses,
  which the road data does not mark.
- **Rain under cover is now hidden, not stopped.** The rain keeps simulating invisibly
  while you are under a roof, so it returns instantly at full density the moment you
  exit, no more dry seconds after a tunnel. Weather state, wetness and grip are
  untouched throughout.
- **No fog under roofs.** Global fog is blind to ceilings, so foggy weather used to
  read as a white wall inside every bore. Fog is now removed while the road data says
  you are under a roof (`Config.Tunnels.CoveredFogMult`).
- **Less Lumen shimmer.** The bundled Engine.ini now clamps per-ray GI radiance and
  restores proper spatial/temporal filtering, the flickering bright specks on dark
  tunnel ceilings are largely gone.

### Removed
- The legacy 144-slot time-of-day exposure table and its module, fully superseded
  since 3.4.0 and no longer functional on the current pipeline.
- The headlight lens-proxy fallback; auto headlights key on sun elevation with a
  plain clock fallback.

### Fixed
- Rain restarting several seconds late after tunnels and overpasses.
- Rain falling inside short tunnels with unusual geometry.
- Fog and rain state after mid-tunnel weather changes.

## [3.4.0]: 2026-07-09

### Changed
- **New exposure engine.** The mod no longer replaces the game's auto-exposure with a
  fixed manual anchor; it rides the stock auto-exposure and steers it through the sky
  system's own exposure-bias controls, driven by the sun's real elevation. Dusk and dawn
  land wherever the sun actually is, brightness self-normalizes across weathers, and
  menus/cutscenes can no longer catch an unmanaged exposure state.
  **Re-run the installer:** the old `r.EyeAdaptation.MethodOverride=3` line must be gone
  from Engine.ini for 3.4+ to look right, the updated installer strips it automatically.
- **Seasons.** The in-game calendar advances every in-game midnight (the game saves it),
  so sunrise and sunset times drift through the year like real Tokyo, long summer
  evenings, early winter nights. Prefer a fixed date? Set `Config.RealSun.PinMonth` /
  `PinDay`.
- **Tunnels handled properly.** Entering a tunnel in daylight now darkens the picture
  the way eyes would (nights were already right), and rain/snow stop falling under
  covered road and return at the exit portal, it keeps raining outside. Detection uses
  the course's own covered-road volume data, so it covers every tunnel without a
  hand-made list.
- **The Parking Area continues your weather.** No more canned always-night PA: your
  course weather and time of day carry over and the clock keeps running.
  `Config.PA.Mode` = `"continue"` (default), `"freeze"` (carry the state, stop the
  clock), or `"stock"` (the old canned night).
- **Dawn/dusk slow-time windows follow the sun**, tracking the drifting seasons instead
  of a fixed clock window.
- **Cloudy and overcast nights lifted** to a realistic city-glow floor through the
  sky's native night levers (they were the darkest nights of all; real overcast city
  nights are the brightest).

### Added
- `Alt+J`: manually toggle rain/snow particles off/on without changing the weather.
- **Installer: updates keep your data.** Re-running the installer over an existing
  install now preserves the saved time-of-day/weather state, headlight settings and
  `Logs/tuning_feedback.log` (`config.lua` still intentionally resets to the new
  release defaults).

### Fixed
- A stuck game clock when loading into a course during a dawn/dusk window in
  fast-forward mode.
- Changing the weather while inside a tunnel no longer makes it rain in the tunnel.

## [3.3.1]: 2026-07-06

### Fixed
- **Transition crash hardening.** The weather-audio, photo-mode and HUD-vignette systems
  no longer touch game objects while a world is being torn down, the cause of rare hard
  crashes during garage/course transitions reported on some installs. If a sound asset
  never becomes playable (older game versions are missing some), the mod now gives up
  after ~30 seconds instead of retrying forever.
- **Course loads settle in seconds.** New-world detection was broken, so every course
  load waited out a 15-second failsafe before time-of-day, weather and exposure snapped
  in. Loads now settle in about 2 seconds, this also covers the pre-race camera
  sweeps, which used to play with unmanaged exposure ("auto exposure off in cutscenes").
- **Garage brightness applies immediately** after leaving a course (was up to 15 seconds
  of leftover on-course exposure, very dark after a dusk drive).
- **Headlight brightness survives hi-beam flashes.** The chosen brightness level is now
  baked into the lamp source values and re-asserted after a flash instead of snapping
  back to stock. Deferred brightness application also now works in the manual force
  modes, and applies without delay in auto.
- **Auto headlights respect the game's own call at course entry.** Spawning at dusk no
  longer forces lamps off that the game had just turned on; the auto ON threshold was
  retuned to match the game's native timing.
- **Stale saved time speed.** A fast-forward speed saved by an older version can no
  longer make the clock silently run fast every session; unknown saved speeds now reset
  to normal.
- **Parking-area state freeze** works again (its world detection had been silently
  broken in 3.3.0).

### Changed
- **Dawn and dusk exposure fully retuned** from in-car feedback datapoints. Dusk now
  holds daylight until ~19:00, collapses with the sun through ~20:00, and reaches the
  night look by ~20:10 (was ramping from late afternoon and not settling until ~21:30).
  Dawn brightens more decisively before sunrise and lands on the day look by ~07:15.
  Partly Cloudy compensation trimmed to match.
- **Brighter night sky.** Night-sky city glow raised and the real-star layer roughly
  doubled in intensity.

### Added
- **Tuning feedback file.** Every exposure/skylight feedback keypress (`Alt+D`,
  `Alt+Shift+D`, `Alt+V`, and the skylight nudge keys) is now also appended to
  `Logs/tuning_feedback.log`, one small, session-marked file you can attach to a
  feedback report instead of digging through full session logs.

## [3.3.0]: 2026-07-04

### Added
- **Night-only mode.** The time cycle runs dusk, night, dawn, then jumps straight back to
  dusk, the day is skipped entirely, and dawn plays out in full before the jump. For
  night drivers who still want the golden-hour bookends. Off by default
  (`Config.TimeOfDay.NightOnly`), and offered as an installer option.
- **Cinematic sky.** A new daytime look pass (`cinematic_sky.lua` / `Config.CinematicSky`):
  denser, darker cloud cores; a stronger silver-lining glow when the sun is behind cloud;
  crisper cloud edge detail; visible high cirrus streaks that catch fire near a low sun;
  richer overall sky color; overcast days that stay luminous instead of going gray mush;
  stronger sunset and sunrise colors; a slower, statelier cloud drift; and clouds that
  stay coherent during `Alt+T` time-lapses. Knobs with undocumented internal ranges are
  applied as multipliers on the sky's own stock values (re-read fresh every course, so
  nothing compounds), and every apply logs the stock and tuned value pairs
  (grep `CinematicSky`) so retuning is data-driven.
- **Skylight tuning keybinds.** Live-tune the skylight look while driving:
  `Alt+Z` / `Alt+X` / `Alt+C` raise skylight leak albedo / leak roughness / intensity
  (`Alt+Shift` lowers), `Alt+V` logs a datapoint (time, weather, values, grep
  `SkylightTune`), `Alt+Shift+V` resets to the exposure curve.
- **Per-weather exposure compensation.** The exposure curve is tuned for clear skies;
  overcast, rain, fog and snow scenes now get a brightness boost on top of it, smoothed so
  weather changes never pop the exposure. Two tables: `Config.Exposure.WeatherSkyMult`
  (skylight intensity, the effective brightness lever, since heavy cloud is exactly what
  takes that light away) and `WeatherLensMult` (a secondary eye-adaptation shaping lever). The `Alt+D`
  feedback log records the active multiplier, so curve feedback and weather feedback stay
  separable. Headlight auto mode inherits it, lamps come on earlier under gloomy skies.
- **Debug short time cycle** (`Config.TimeOfDay.DebugShortCycle`, off by default). Dawn
  and dusk play at full length, but the flat midday and deep-night stretches are cut to
  about an hour each, a complete lighting cycle in minutes, for exposure tuning or for
  anyone who mostly wants the golden-hour bookends. Takes precedence over night-only mode
  if both are enabled.

### Changed
- **Engine.ini profiles reworked.** The Photomode profile ships a full rendering overhaul:
  sky and clouds reflect in car paint again (the game's stale reflection probes are bypassed
  in favor of live Lumen), TSR anti-ghosting is restored plus a fix for the static pattern
  on bright lights, GI blotch/shimmer fixes, photographic night highlights (reflected light
  sources no longer clamp to dull blobs), crisper shadows, and anti-flicker temporal tuning
  for reflections and GI. The Optimizations-only profile was cleaned out: debug and logging
  switches removed, inert settings dropped (over a third of the old file sat in config
  sections the engine never reads), and it picks up the car-paint reflection fix too.
  **Re-run the installer and pick a profile to get the update**: Engine.ini is only
  written at install time.
- **God rays now actually work.** The module had been writing sun light-shaft property
  names that do not exist in this game version, so god rays were silently doing nothing.
  It now drives the real controls: the sun's screen-space light-shaft bloom, brightened
  from stock and warm-tinted.
- **Softer cloud shadows**, dappled light rolling over the track instead of hard-edged
  blotches (`Config.Atmosphere.CloudShadowSoftnessMult`).
- **Bigger daytime skies.** The automatic cloud-coverage ceiling was raised (3.0 to 4.5 of
  10) so real cumulus fields can build instead of the near-clear bias.
- **Exposure and skylight baseline retune.** Car paint keeps a live sky reflection in
  shade and tunnels (the skylight intensity now has a floor, and the skylight-leaking
  baseline was raised); the daytime exposure is re-anchored; the dusk ramp starts earlier
  (16:50) and runs about twice as bright through the evening; the dawn descent was
  lifted. All values retuned from in-game feedback datapoints.
- **Faster fast-forward.** `Alt+T` fast mode is twice as fast, a full day in roughly two
  minutes.

### Fixed
- **The garage-transition crash.** The alignment-slider module's menu scans could run
  during map transitions (and in parking areas), walking UI widgets on the game thread
  while the old world was being destroyed, an intermittent access-violation crash, most
  often when entering the garage from a course. Scans now run only while the garage is
  positively detected and never during a map transition. The same hardening pass also
  made the whole mod quieter during transitions: the sky-actor search fully pauses while
  a world is tearing down, and the per-actor lifecycle hooks do far less work in that
  window.
- **Second cloud layer.** The toggle had been writing a property that does not exist in
  this game version, so it never did anything. It now enables the real second layer (high
  cirrus above the cumulus), but ships **off**: it raises cloud rendering cost
  significantly and is under stability observation (`Config.Atmosphere.EnableSecondCloudLayer`).
- The skylight tuning keys no longer emit no-op console pushes when held at their limit.
- Cloud render-quality sample scales exist in `Config.CinematicSky` but ship at stock
  (1.0) pending GPU-stability testing, raise `ViewSampleQualityMult` deliberately if you
  want cleaner clouds up close in photo mode.

## [3.2.0]: 2026-07-02

### Added
- **Weather sounds.** Rain, wind, and thunder are audible for the first time: a rain
  loop that follows the rain intensity, a wind bed that follows the wind, and distant/
  close thunder cracks rolling on their own timer during thunderstorms. The mod plays
  the weather system's own sound assets directly (its built-in sound path does not
  function in TXR). Per-sound toggles and volumes in `Config.Audio`.
- **Wider garage alignment sliders.** Camber, toe, ride height, wheel offset, and tire
  width now run to 3x their stock range (configurable via `Config.Tuning.RangeMultiplier`),
  the garage car previews out-of-range values live, and saved extremes are re-applied to
  the car on spawn, so the stance you set is the stance you drive. Locked settings stay
  locked, nothing is unlocked by this. Slider-widening approach credited to NadzW and
  FenderBender (WheelOffsetUnlocker).

### Fixed
- The weather audio module addressed the weather system with property names that do
  not exist in this game version, so it had always been silent, rewritten (see Added).
- The headlight light-button gesture log now says when a press is ignored because
  headlights are in auto mode (auto remains deliberately config-only).

### Removed
- **Auroras retired.** The aurora texture is not part of TXR's cooked game content, so
  the sky shader has nothing to draw, auroras cannot render in this game. The option
  remains in config (`Config.Atmosphere.EnableAurora`, off) in case a future content
  route makes the texture loadable.

### Internal
- Release builds now cap log verbosity at INFO (`Config.IS_RELEASE_BUILD`).
- Full code review pass across all modules; the tuning menu scan pauses while driving.

## [3.1.0]: 2026-07-01

### Added
- **Photo mode camera unlocked.** The Advanced Photo Mode free camera is freed up for
  proper screenshots: it can pass through geometry and leave the track (no collision),
  the distance cap is removed so you can pull right back from the car, the orbit camera
  pans much further, and the zoom range is widened a lot at both ends (much closer macro
  shots and much wider angles). Free-camera movement is faster, rotation is scaled to the
  zoom so framing a tight shot is not twitchy, and the photo-mode vignette starts off for
  a clean image. On by default. `Config.PhotoMode`.
- **Dynamic wet grip.** Tire grip now drops as the road gets wet and recovers as it dries,
  scaling with the live rain intensity (rises quickly, dries off slowly). It applies to
  every car, so the AI rivals get just as loose in the rain as you do, and it works in
  parking-area battles. Lateral (cornering) grip is hit a little harder than longitudinal,
  matching how a wet surface actually behaves. Tunable floors and wet/dry timing.
  On by default. `Config.WetGrip`. The global tire-table grip approach is credited to
  Chrystales.

## [3.0.20]: 2026-06-30

### Added
- **Rainbows.** After a careful re-check of the UDS/UDW data, the rainbow turned out
  to be drawn on a world mesh (not a screen post-process like the screen-droplet
  family that does not render in TXR), so it works here. Weather decides when it
  appears: there has to be rain or fog feeding it, the camera has to be in direct
  sunlight (not under an overcast sky), and the sun has to be low enough. So it
  shows up naturally as a shower clears toward the sun, rather than in every weather.
  On by default. `Config.Rainbow`.
- **Night-sky nebula (Space Layer).** A faint nebula band rendered into the sky the
  same way as the stars and moon, fading in only at night. It is a stylistic touch (real
  Tokyo skies are light-polluted), keep it subtle, or turn it off for a plain night
  sky. On by default at a modest intensity. `Config.SpaceLayer`.
- **Hide HUD vignette (opt-in).** Removes the darkened corner vignette the game draws
  over the screen during normal play (it's a HUD overlay, so Engine.ini can't disable
  it). Cleaner, more photographic image. Pure HUD toggle, no game files touched. Off by
  default; set `Config.Vignette.Enabled = true`. `Config.Vignette`.

### Fixed
- **Day-to-day weather variety now actually re-rolls after the morning.** A config-key
  typo meant `ResumeRandomizeAfterMorning` never took effect, so the cloud/fog "mood"
  stayed fixed once a day started. It now re-randomizes after the morning window as
  intended (set the option false in `Config.CloudsFog` if you preferred it static).
- **Log files now show the correct mod version** in the session header (was always
  printing 3.0.0), and the startup "modules loaded" count is now accurate.

### Notes
- These features are additive, follow the same safe deferred-apply pattern as the
  stars / moon / wind-debris features, and each has its own `Config` block and module
  toggle, so any one can be turned off independently.
- No new game files are added or edited; everything is driven at runtime on the
  Ultra Dynamic Sky / Weather actors (and TXR's own HUD widget for the vignette).

## [3.0.19]: 2026-06-30

### Added
- **Pop-up (retractable) headlights now animate** when the lights switch on/off,
  using the game's native raise/lower instead of snapping into place.
- **Garage headlight control.** Alt+Q in the garage toggles the displayed car's
  lights, and the pop-ups animate there too.
- **Manual-mode light-button gesture (keyboard + controller).** With headlights set
  to manual, a short press of the light button turns them on and a ~2-second hold
  turns them off, so manual lights work on a controller without a keybind.

### Changed
- **Higher-resolution auto-exposure.** The day/night exposure curve is sampled every
  10 minutes (144 steps) instead of every 30, for smoother ramps.
- **Brighter dusk and after sundown.** The evening exposure now comes up earlier so
  it is no longer too dark once the sun is down.
- **Auto headlights are fully automatic** (set in config). There is no runtime switch
  out of auto, so they can't be turned off by accident.

### Fixed
- **No more night flash when leaving the parking area.** Exiting a PA into a daytime
  course no longer flickers a frame of full-night exposure before it corrects.
- **Smoother fast-forwarded time and no dawn/dusk frame hitches.** Auto-exposure
  re-evaluates more often yet sends far less work to the render thread.
- **Garage and menus brighten faster on entry** (quicker scene detection).

### Internal
- Dropped the experimental high-beam latch (it could not be driven reliably from
  script in this build).

## [3.0.18]: 2026-06-27

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

## [3.0.17]: 2026-06-26

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

## [3.0.16]: 2026-06-25

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
- **Auto-headlights**, on/off timing works, but on some cars lamp meshes stay lit and
  pop-ups (e.g. AE86) don't actuate. Fix pending.
- **Pick an Engine.ini profile in the installer** for correct brightness/shadows/reflections.

## [3.0.15]: 2026-06-24

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
- **Auto-headlights**, on/off timing works, but on some cars the lamp meshes stay
  lit and pop-up headlights (e.g. AE86) don't actuate. Light-actuation fix pending.
- **Pick an Engine.ini profile in the installer.** Brightness, shadow, and
  glass-reflection issues are almost always a skipped Engine.ini step, not the mod.

## [3.0.14]: 2026-06-23

### Added
- **`Config.Weather.Enabled`** master switch, set `false` for time-of-day +
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
- **Alt+L / Alt+Shift+L** no longer error, rewired from the removed calibration
  nudge to `Shadows.Apply` (force re-apply shadow distance). Resolves the 3.0.13
  orphaned-keybind issue.

### Known Issues
- **Pick an Engine.ini profile in the installer.** Brightness, shadow-resolution/distance,
  and glass-reflection problems are almost always a skipped Engine.ini step or a
  custom/outdated file, not the mod.
- **Stars disabled by default**, course-load crash (`0xC0000005`); fix pending.
- **Auto-headlights**, on/off timing works, but on some cars the lamp meshes stay
  lit and pop-up headlights (e.g. AE86) don't actuate. Light-actuation fix pending.
- **Tunnels**, rain and lighting are wrong indoors (broken game map meshes; not fixable).
- **Wetness** (WIP), only road markings get wet, not the road surface (missing material).

## [3.0.13]: 2026-06-18

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
  etc.) into the modules does not take effect in-game yet, keep those in Engine.ini
  for now. (Code is in place behind `Config.Exposure.SetupCvars` /
  `Config.EnhancedFog.SetupCvars`; investigation continues.)
- **Alt+L / Alt+Shift+L shadow keybinds are orphaned** after the shadow revert:
  they call calibration functions that no longer exist and log an error if pressed.

## [3.0.12]: 2026-06-17

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
  course load) no longer spike shadow distance to maximum for a frame, non-positive
  reads are now rejected and the last good distance is kept.

### Known issues / in progress
- The adaptive `FOV_DISTANCE_TABLE` is still calibrated for game v1.1. Recalibration
  for v1.5 is pending in-game measurements (use the Alt+L / Alt+Shift+L tool).
- Stars: if the HD texture is not yet loaded at course-load time it may not swap in
  (real stars still enable with the default texture, with a warning logged); a
  deferred-retry can be added if needed.

---

## [3.0.11], prior
- Phase 9 & 10: Atmospheric enhancements (god rays, aurora, cloud shadows), auto
  headlights and brightness control.

## [3.0.10], prior
- Phase 8: Dawn/Dusk transitions (slow time, Tokyo tint).

## [3.0.9], prior
- Phase 6.5: Shadow FOV scaling system with lookup table.

## [3.0.8], prior
- Phase 7: Lightning & Enhanced Fog systems.

## [3.0.7], prior
- PA persistence fixes (Fix7), fresh file reads, invalid TOD validation.

## [3.0.0], prior
- Initial modular rewrite of Ultradynamic TXR V1.34.
