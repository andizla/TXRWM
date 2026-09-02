# TXR Weather Mod V3: complete feature inventory

Built from the code, not from the docs. Every entry was read out of the live
module and its config block, so this is what the mod actually does.

**Current as of 4.0.1 (2026-09-02).**

---

## 1. Time of day

- **Living 24 hour clock.** A full day passes in about 30 real minutes, so a
  single session drives through sunset, night and sunrise.
  `Config.TimeOfDay.DefaultSpeed = 53.333`
- **Fast forward at 12x.** Alt+T runs a full day in about 2.2 real minutes.
  `Config.TimeOfDay.FastSpeed = 640.0`
- **Pause.** A third Alt+T press freezes sun, shadows and sky where they are.
- **The clock cannot stall.** Every 3 seconds the mod confirms time is still
  advancing at the selected speed and restarts it if the game stalled it.
- **Time survives restarts.** Clock, speed mode and paused state are restored on
  the next course. `Config.Persistence.*`
- **Night only mode.** Dusk, night, dawn, then straight back to dusk, skipping
  daylight entirely. Opt in. `Config.TimeOfDay.NightOnly = false`
- **Short cycle (tuning aid).** Full length dawn and dusk with the flat day and
  night cores cut to about an hour each. Opt in.
  `Config.TimeOfDay.DebugShortCycle = false`
- **Starting time override.** Force a fixed hour on every course load. Ships off,
  and a saved state wins over it. `Config.TimeOfDay.StartingTOD = nil`

## 2. Dawn and dusk

- **Slow time sunrise and sunset.** Within 8 degrees of the horizon the clock
  drops to 40% speed, stretching a dusk to roughly 5 or 6 real minutes. Skipped
  during fast forward by design. `Config.Transitions.SlowFactor = 0.40`
- **Tokyo tint.** Sun light, horizon and cloud lighting warm toward orange with a
  pink cast in the horizon band, peaking exactly as the sun touches the horizon
  and fading out by 30 degrees up and 12 degrees down. Dawn uses a softer orange
  than dusk. `Config.Transitions.TintDayElev = 30.0 / TintNightElev = -12.0`
- **Both follow the real sun**, with a clock window as fallback, so they stay
  centred on the true sunrise and sunset in any season.

## 3. Real sun, real moon, seasons

- **Astronomically correct Tokyo sun.** Real solar simulation at Tokyo's
  coordinates: correct sunrise and sunset times, correct arc across the sky, DST
  forced off because Japan has none.
  `Config.RealSun.Latitude = 35.676 / Longitude = 139.650 / TimeZone = 9.0`
- **Seasons drift.** The game advances its own calendar at every in-game
  midnight, so sunrise and sunset walk through the year as you play. Each course
  entry re-lands the tuned date. `Config.RealSun.Year/Month/Day = 2026/7/25`
- **Fixed date pin.** Freeze the calendar so every course has an identical sun
  path. Opt in. `Config.RealSun.PinMonth / PinDay = nil`
- **Real moon.** Moon position and phase follow the same real ephemeris.
  `Config.RealSun.RealMoon = true`

## 4. Weather

- **Nine presets in the cycle:** Clear Skies, Partly Cloudy, Cloudy, Overcast,
  Heavy Overcast, Foggy, Light Rain, Rain, Thunderstorm.
  Five more (snow x3, dust x2) exist as data and are deliberately out of rotation.
- **Each preset is a full sky, not just a cloud number.** Cloud coverage, fog,
  precipitation intensity, particle count, thunder tier and a per preset colour
  grade. Overcast, Heavy Overcast and the three rain presets each cool and
  desaturate the sky so a closed deck never reads warm and sunny.
- **The sky lives inside a preset.** Slow cloud drift, micro jitter, restless
  dawn and dusk hours, a rolled-per-day mood and morning profiles modulate the
  active preset, bounded so it still reads as itself.
  `Config.CloudsFog.PresetLivingScale = 1.0`
- **Automatic weather scheduler.** A weighted random change every 3 to 8 minutes,
  blended over 40 seconds so weather turns rather than switches.
  `Config.Scheduler.MinIntervalSeconds = 180 / MaxIntervalSeconds = 480`
- **Daytime is deliberately less sunny.** Clear skies are multiplied to 0.15
  weight while the sun is up, cloud decks to 1.5, so daytime is not boring.
  `Config.Scheduler.TimeWeights.day`
- **It never repeats the current weather** and never stomps a manual pick: any
  change you make re-arms the full interval.
- **Precipitation lockout.** Keep the scheduler dry while manual cycling still
  reaches rain. `Config.Scheduler.AllowPrecipitation = true`
- **Rain starts when the course does.**
- **Weather persists** across restarts and through the Parking Area.

## 5. Weather audio

- **Three layers: rain loop, wind loop, thunder one-shots.**
- **Volumes track intensity, not the preset name.** Rain volume rises with rain
  strength and re-evaluates about once a second, so a 40 second transition into
  rain has the loop swelling with it.
- **Wind is independent of rain**, driven by live wind intensity, so you hear
  wind under a clear or overcast sky.
- **Thunder tiers.** Light Rain carries no thunder at all, Rain plays distant
  rumbles only, Thunderstorm mixes distant rumbles with occasional close cracks
  (11 distant variants, 6 close). `Config.Audio.CloseThunderMin = 7.0`

## 6. Sky and atmosphere

- **Real star night sky with the Milky Way**, rotating with the sky.
  `Config.Stars.SimulateRealStars = true`, `Intensity = 3.0`
- **Tokyo city glow.** Amber light pollution lighting the cloud bases from below
  plus a cool night sky glow floor, ramped on sun elevation and held flat all
  night (real city glow does not dim toward midnight).
  `Config.Atmosphere.LightPollutionMax = 0.6`, `NightSkyGlowMax = 1.0`
- **Light pollution is hard clamped at 1.0 in code.** Above it the sky material
  inverts the star maths and stars render as black dots.
- **God rays** with a warm tint, raised seeding threshold so rays come off the sky
  rather than off buildings, and shortened streaks.
- **God ray weather gate.** The base game fires full strength shafts under a
  closed overcast; the mod scales them on live cloud coverage, full below 3.0,
  off above 5.5, and keeps them on in fog on purpose because shafts through haze
  are the real thing. `Config.Atmosphere.GodRayWeatherGate = true`
- **Volumetric cloud light rays.** Separate shafts stabbing through natural gaps
  in the cloud deck, gated off in the six overcast/fog/rain presets, pushed out
  toward the distance so they do not fire off nearby buildings. (These render as
  mesh cards through the same path as rain and debris, which is why they show in
  TXR; UDS's separate Niagara cloud-ray system stays dormant in this game.)
- **Cloud shadows** rolling over the track, softened 30% above stock for dappled
  light rather than hard blotches.
- **Moon** with real phases, phase advancing night to night, and 25% larger than
  stock. `Config.Moon.Scale = 1.25`
- **Rainbows**, mesh rendered so they actually show in TXR. UDW decides when:
  rain or fog feeding it, camera in direct sun, sun low enough.
- **Wind debris**, leaves and dust scaling with wind intensity.
- **Cinematic daytime sky.** Denser darker cloud cores, stronger silver lining,
  crisper edge detail, more visible cirrus that lights up near the sun at golden
  hour, richer colour, luminous overcast, more blue kept under cloud, stronger
  sunsets, 40% slower cloud drift, and timelapse coherent cloud movement so a
  fast forward reads as a real timelapse. `Config.CinematicSky`
- **Second cloud layer** (high cirrus deck). Opt in, real GPU cost.
  `Config.Atmosphere.EnableSecondCloudLayer = false`

## 7. Fog

- **Five fog profiles** selected by the preset, from crisp air to near white-out,
  each with its own density, volumetric distance and extinction.
- **Fog is thicker at night** by up to 2.3x, because the exposure pipeline
  brightens night scenes and washes fog out.
- **Tall fog in heavy weather.** Heavy and extreme profiles lower the height
  falloff so fog climbs the buildings instead of hugging the road, and every
  lighter profile restores the course stock value.
- **No fog under roofs.** Global fog is blind to ceilings, so foggy weather
  otherwise reads as a white wall inside every bore.
  `Config.Tunnels.CoveredFogMult = 0.0`
- **Gapped gallery hold.** New in 4.0.0. Fog only returns after 5 seconds of
  continuously open road, so the short gaps in Ginza and C1 no longer flash the
  fog wall back in every gap. `Config.Tunnels.CoveredFogHold = 5.0`

## 8. Lightning

- **Flashes on Thunderstorm only.** Rain carries thunder 4, deliberately below
  the flash threshold, so it rumbles without flashing.
- **Flashes light the world**, not just the sky: road, buildings and your car
  light up, plus diffuse in-cloud flashes with no visible bolt.

## 9. Tunnels and covered road

- **Covered detection from the game's own road data.** Every road point carries a
  "roofed" attribute the developers authored, so the mod flips exactly at the
  portal line and catches every real bore.
- **True interior lighting.** All 33 course post-process volumes ship with a
  skylight leak override that flooded covered sections with flat sky ambient and
  visibly changed the world's brightness at every volume edge. The mod clears it,
  so tunnels read as interiors and no boundary flips the lighting.
- **No sky sheen on glass under roofs.** Course skylights are stopped from
  lighting translucent surfaces, removing the milky film on windscreens and
  taillight lenses inside tunnels.
  `Config.LightCycle.KillSkylightTranslucentLighting = true`
- **Headlights force on in real bores** but deliberately not under lone
  overpasses, so you never get a flash of lights passing a bridge.
- **Photo mode meters for indoors** when a session opens under a roof.

## 10. Rain that behaves

- **Native rain occlusion.** Rain collides with the real tunnel, bridge and
  overpass geometry and resumes past the portal, from the game's own particle
  physics.
- **Invisible to everything else.** The occluders answer rain traces only, so AI
  rivals, the camera, physics and every game query behave exactly as stock.
- **No original game file is modified.** The runtime half is property flips on
  already loaded objects. Since 4.0.0 the mod also installs two additive patch
  paks into the game's Content\Paks (section 19); those are the mod's own
  files layered over the game's data, and deleting them restores stock exactly.
- **Streamed areas are covered too**, on a rolling cadence while wet, plus an
  immediate pass the moment you go under any cover, so a first approach to a
  bridge is already dry. `Config.RainCollision.ReapplySeconds = 20.0`
- **Your car sheds rain on its own paint.** Rain lands on the real body panels
  (bonnet, bumpers, skirts, spoiler, windows) with native splashes on the actual
  roofline, per car, automatically sized, and the oversized hitbox shells are
  pushed out of the way so splashes do not float above the roof.
  `Config.RainCollision.PlayerCarBody = true`

## 11. Shadows

- **Sun no longer pours through tunnel and bridge decks.** Vanilla decks cast
  one-sided shadows, so low sun passed through the roof and landed as bright
  pools on covered road. The mod flips the roster (linings, interior sets, decks,
  walls, kerbs, sidewalks, aprons, exterior walls) to two-sided casting.
- **City buildings cast shadows in daylight.** New in 4.0.0. TXR ships buildings
  with shadow casting off (it is a night game) and re-asserts that on every
  course load, so the mod re-enables it every time. This is a visible city-wide
  change: towers lay shadows across the streets instead of the city being flatly
  lit. `Config.RainCollision.ForceCastShadow = true`
- **Covered road seam blockers.** Covered galleries leak low sun through seams
  with no faces at all, which no flag or material can close. Invisible
  shadow-only blockers stand on hand-measured seam lines, with no collision so
  you drive through the spot exactly as before. **112 sites** ship as of 4.0.0
  (up from six in 3.10.0), and sites can follow road grade and bank.
  `Config.GapWalls`, list in `Scripts/data/gap_slabs.lua`
- **Adaptive shadow distance.** Shadow distance is scaled to the current field of
  view from a calibrated 111 entry table, so shadows survive photo mode zoom
  instead of vanishing when you frame a long lens shot. Also concentrates shadow
  resolution near the camera.

## 12. Lighting and exposure

- **Darker, photographic exposure keyed to the sun.** About two thirds of a stop
  under during the day, easing back at night so nights do not double darken, on
  the sun's real elevation rather than the clock. `Config.LightCycle.BiasCurve`
- **Weather no longer re-meters the frame.** The sky's own cloudy, foggy and
  dusty exposure offsets are zeroed once per course.
- **Asymmetric eye adaptation.** Fast into bright (6 stops/sec) so a tunnel exit
  does not blow out, slow into dark (2 stops/sec) for a cinematic settle.
- **Post-process look layer** written once per course: bloom cut to a quarter of
  stock, screen vignette off, deeper film toe, softer highlight shoulder,
  the game's regional shadow lifting neutralised, slight saturation lift, slight
  near-black gain, higher Lumen scene detail and faster Lumen updates.
  `Config.LightCycle.PostProcess`
- **HDR and SDR display profiles.** The game applies a hidden shadow-lifting
  grade on HDR output only, so the mod detects the display each session and on
  SDR drops the shadow-deepening half and halves the bias curve.
- **Skylight controls.** Global sky ambient at a tenth of engine default so flat
  sky-lit surfaces stop looking like cardboard, with the ambient coming from
  bounced light instead. `Config.LightCycle.SkylightMultiplier = 0.10`

## 13. Headlights

- **Auto mode on the real sun.** On at 1 degree below the horizon, off at 0.5
  above, the gap being hysteresis so they never flicker at dusk. Season proof.
  `Config.Headlights.OnElev = -1.0 / OffElev = 0.5`
- **Forced on in tunnels and in bad weather** (rain, snow, dust).
- **Animated pop-ups** raise and lower through the game's own routine, on course
  and in the garage.
- **Five brightness levels** (0.5x, 1x, 2x, 3x, 5x), baked from a cached stock
  value so they never compound. `Config.Headlights.DefaultBrightnessLevel = 3`
- **Brightness applies to every car**, each gated on that car's own light state,
  so AI rivals get the same lamps while cars running dark stay dark.
- **High beam flash keeps your brightness.** The game recomputes lamp intensity on
  a flash; the mod re-applies your level immediately and again 0.6s later.
- **Tail lamps follow** the headlights, and the flat sprite glare is suppressed.
- **Light button tap/hold gesture**, keyboard and controller alike: tap for on,
  2 second hold for off, manual modes only.
- **State persists** across restarts (brightness always, on/off in manual modes).
- **Garage show floor lights** stay on for the whole visit, re-checked every 2.5
  seconds so a car you swap to lights up within a moment.

## 14. Driving

- **Dynamic wet grip.** Grip falls as the road wets and returns as it dries,
  always scaled from a cached bone-dry baseline so it never compounds.
- **Separate cornering and traction floors**: 0.80x forward, 0.72x lateral, so the
  car loses its bite in corners slightly before it loses drive.
- **Wets up fast, dries out slow** (8 second rise, 45 second dry), so the road
  stays greasy well after the rain stops.
- **Every car including the AI**, because it drives the global tire table, and it
  keeps working in Parking Area rival battles.
- **Braking is not affected**, only the six grip rates.
- **Wider alignment sliders.** Camber, toe, ride height, wheel offset and tire
  width run to 3x their stock range, the garage car previews the true unclamped
  value live as you drag, and saved out-of-range values are re-applied on spawn
  because the game stores extremes but refuses to apply them on load. Locked rows
  stay locked and nothing is unlocked. `Config.Tuning.RangeMultiplier = 3.0`

## 15. Photo mode

- **Camera unlocked**: no collision (fly through geometry and off the track), no
  distance cap, far wider orbit pan.
- **Zoom range widened** by rewriting the in-game FOV slider's own range to
  0.25 through 140, so the normal on-screen control reaches extreme telephoto and
  ultra wide with no new keys. Steps get finer below FOV 10 where zoom grows
  exponentially. `Config.PhotoMode.FovSliderMin/Max`
- **Free camera flies 2.5x faster**, and rotation speed scales with zoom so tight
  framing is not twitchy, with a floor so extreme zoom never freezes.
- **Time freezes for the session.** Sun and shadows hold still through composing
  and long exposures, and since 4.0.0 the freeze retries if the shoot opens
  mid-scene-swap, where the first write could silently miss. A clock you paused
  yourself stays paused on exit.
- **Weather holds still too**, and stays held 30 seconds after you close.
- **Manual metering** so the aperture genuinely drives exposure, with the level
  set from the sun's elevation on a ten point curve.
- **Covered and garage sessions get fixed levels** instead of the sun curve,
  because a lit bore does not track the sun.
- **Photo mode vignette reset** to effectively off each time the menu opens.
- **Live exposure trim and dark look** on keys, session scoped.

## 16. Garage

- **Dark garage.** Every visit opens on a tuned low-key show floor look with the
  headlights on, so cars read as lit objects in a dark room. Installer asks.
  `Config.LightCycle.GarageDark`
- **Adjustable live without photo mode.** Alt+G toggles the look and Alt+E trims
  it while you browse; values reset when you leave so every visit starts the
  same.

## 17. Parking Area

- **Your weather and clock continue into the PA** instead of the canned stock
  night (fixed 19:50, heavy cloud, fog). Three modes: continue (default), freeze,
  stock. `Config.PA.Mode = "continue"`
- **The PA fights back and the mod wins.** The scene re-cans its own clock about
  a minute after the carry lands and can silently reset the timescale to a real
  time crawl; the mod watches once a second and restores both.

## 18. Quality of life and support

- **HUD vignette removal.** Removes the darkened corner frame the game draws
  during play. It is a HUD widget, not a render setting, so Engine.ini cannot
  touch it. ON by default. `Config.Vignette.Enabled = true`
- **Everything persists**: time, weather, cloud, fog, speed, pause, headlight
  mode and brightness. Atomic saves with a rolling backup, so an Alt+F4 or a
  crash mid-write falls back to the backup instead of losing the lot.
- **TXRWM_GrabLogs.** One double-click packs mod logs, the UE4SS log, crash
  dumps, engine crash reports, your config and a manifest into a zip on the
  Desktop. Run it before relaunching.
- **Engine hookup watchdog.** If the rare UE4SS side failure silently stops the
  mod's game-thread work, you get a loud warning naming what stopped.
- **Tuning feedback side channel.** Alt+D, Alt+K, Alt+N and the skylight keys all
  append one-line datapoints to `Logs/tuning_feedback.log`, a small persistent
  file you can send instead of full session logs.

## 19. Shipped pak files (new in 4.0.0)

- **TXRWM_RoadShadows_P** (2.9 MB): pre-bakes two-sided shadow casting into about
  1523 road and tunnel mesh components, so covered sections are correctly shaded
  from the first frame with nothing running.
- **TXRWM_Collision_P** (291 MB): pre-bakes complex-as-simple collision onto 268
  mesh assets. Since 4.0.1 the mod writes that flag itself at every course
  load, so rain occlusion no longer depends on this pak; it is optional.
- Both install into the game's Content\Paks as additive patch paks. No original
  game file is modified or replaced, deleting them restores stock exactly, and
  both need re-baking after a game update. The installer offers them as a
  separate download; declining is fine, the mod then does the collision work at
  runtime as 3.x always did.

---

## 20. Keybinds

| Key | Action |
|-----|--------|
| Alt+S / Alt+Shift+S | Cycle weather preset next / previous |
| Alt+P / Alt+Shift+P | Random weather now / force Clear Skies |
| Alt+R | Reset weather to default |
| Alt+T | Time speed: normal, fast, pause |
| Alt+Q | Headlights on/off (manual modes; garage toggles the display car) |
| Alt+B / Alt+Shift+B | Headlight brightness up / down |
| Alt+E / Alt+Shift+E | Exposure trim brighter / darker (photo session and garage) |
| Alt+G | Dark look toggle (photo session and garage) |
| Alt+L / Alt+Shift+L | Re-apply FOV-matched shadow distance (both keys identical now) |
| Alt+D / Alt+Shift+D | Report too dark / too bright, logs a datapoint |
| Alt+Z / Alt+Shift+Z | Skylight leak albedo up / down |
| Alt+X / Alt+Shift+X | Skylight leak roughness up / down |
| Alt+C / Alt+Shift+C | Skylight intensity up / down |
| Alt+V / Alt+Shift+V | Log a skylight datapoint / reset skylight overrides |
| Alt+K / Alt+Shift+K | Night sky glow down (more stars) / up |
| Alt+N | Rain spot report at your position |
| Alt+J | Leak hunt: clear skies, pinned low sun, frozen clock, scheduler held |

Dev builds only (the slab editor file is omitted from release zips, so these keys
do not exist in a normal install): Alt+Shift+J, Alt+Y, and the numpad grid.

Not a keybind: the car's own light button carries the tap/hold headlight gesture.
