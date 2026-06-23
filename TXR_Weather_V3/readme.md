\# Ultradynamic-TXR Devbuild



Check config and keybinds for info



\# TXR Weather Mod V3 Developer Reference

\## Modular Rewrite of Ultradynamic TXR V1.34 Weather System



\*\*Last Updated:\*\* December 20, 2025



\---



\## Table of Contents

1\. \[Current Status](#1-current-status)

2\. \[Stable Systems - Do Not Modify](#2-stable-systems--do-not-modify)

3\. \[Known Issues](#3-known-issues)

4\. \[Feature Status](#4-feature-status)

5\. \[Keybinds](#5-keybinds)

6\. \[Phase Plan](#6-phase-plan)

7\. \[File Structure](#7-file-structure)

8\. \[Actor Discovery](#8-actor-discovery)

9\. \[Weather Control API](#9-weather-control-api)

10\. \[Time Control API](#10-time-control-api)

11\. \[Wetness \& Puddles System](#11-wetness--puddles-system)

12\. \[Lightning System](#12-lightning-system)

13\. \[Enhanced Fog System](#13-enhanced-fog-system)

14\. \[Shadow System](#14-shadow-system)

14.5. \[Headlights System](#145-headlights-system)

15\. \[Atmospheric Properties](#15-atmospheric-properties)

16\. \[Weather Presets Reference](#16-weather-presets-reference)

17\. \[Sound System](#17-sound-system)

18\. \[Event Dispatchers](#18-event-dispatchers)

19\. \[Persistence System](#19-persistence-system)

20\. \[Lua Integration Patterns](#20-lua-integration-patterns)

21\. \[Phase Details](#21-phase-details)

22\. \[Excluded Features](#22-excluded-features)



\---



\## 1. Current Status



| Metric | V1.34 | V3 Current |

|--------|-------|------------|

| Total Lines | 6,771 | \~3,800 |

| Files | 9 | 22 |

| Core Features | 30+ | \~28 implemented |

| Completion | 100% | \~85% |



\---



\## 2. Stable Systems - Do Not Modify



⚠️ These systems required extensive debugging and are now working correctly. \*\*Do not touch this code:\*\*



| System | Location | Notes |

|--------|----------|-------|

| Rain Particles | `weather.lua` | 6-day debug effort, works flawlessly |

| Dry Enforcement | `weather.lua` | Integrated dry watchdog/hard kill |

| Hard Kill Precip | `weather.lua` | Stops particles on dry presets |

| Niagara Activation | `weather.lua` | Direct component manipulation via FindAllOf |

| PA Persistence | `persistence.lua` | File-based state restore (Fix7) |

| Shadow FOV Scaling | `shadows.lua` | Lookup table from extensive testing |



\---



\## 3. Known Issues

> **Pick an Engine.ini profile in the installer** (Photomode / Optimizations only / Minimal, each
> with or without exposure). Every profile includes the cvars the mod relies on. Brightness, shadow
> resolution/distance, and glass-reflection problems are almost always a skipped Engine.ini step or
> a custom/outdated file, **not** the mod.
>
> Current major issues: **screen-space / material weather effects** (screen droplets, frost,
> wetness/puddles) do not render in TXR (the game doesn't composite UDW's post-process and the road
> materials lack UDW's functions) and are not Lua-fixable; **tunnel rain** can't be occluded from Lua
> (tunnels have no overhead collision to trace); **auto-headlights** timing works, but on some cars
> the lamp meshes stay lit and pop-up headlights (e.g. AE86) don't actuate. (Stars: fixed and
> re-enabled in 3.0.15.)



\### 3.1 Rain Particles After PA Exit

\- Rain particles don't appear until manual weather cycle

\- UDW doesn't create Niagara components immediately after map load

\- Retry mechanism exists (50 attempts) but components don't exist yet

\- This is a UDW timing limitation, not easily fixable

\- Weather preset and all other settings restore correctly

\- \*\*DO NOT MODIFY\*\* rain particle code - it works during normal gameplay



\### \~\~3.2 Fog Too Weak\~\~ ✅ FIXED (Phase 7)

\- \*\*Fixed:\*\* `enhanced\_fog.lua` now adjusts `Scale Fog Density` on UDS

\- Volumetric fog enabled for all profiles (required for weather system)



\### 3.3 Shadow Disappearance at Low FOV

\- CSM frustum culling causes shadows to disappear at low FOV (photo mode zoom)

\- Also affected by sun angle and camera direction relative to sun

\- \*\*Workaround:\*\* `shadows.lua` dynamically scales shadow distance based on FOV

\- Lookup table derived from extensive testing (FOV 10-120)

\- Not a perfect fix but maintains shadows at all FOV levels



\### 3.4 Wetness/Puddles Not Visible (Phase 6 WIP)

\- Wetness simulation logic works correctly

\- Puddle coverage values write to UDW successfully

\- Visual puddles don't appear in-game

\- Module disabled by default (`Config.Wetness.Enabled = false`)

\- Requires further investigation of UDW's internal accumulation system



\---



\## 4. Feature Status



\### 4.1 Implemented (from V1.34)



| Feature | Status | Location |

|---------|--------|----------|

| Rain/Particle System | ✅ STABLE | `weather.lua` |

| Config System | ✅ Done | `config.lua` |

| Morning Mood System | ✅ Done | `clouds\_fog.lua` |

| PA Freeze | ✅ Done | `main.lua`, `persistence.lua` |

| Persistence (save/load) | ✅ Done | `persistence.lua` |

| Weather Presets (13) | ✅ Done | `presets.lua` |

| Keybinds | ✅ Done | `keybinds.lua` |

| Dry Watchdog / Hard Kill / Rainfix | ✅ STABLE | `weather.lua` |

| Lightning System | ✅ Done | `lightning.lua` |

| Enhanced Fog | ✅ Done | `enhanced\_fog.lua` |

| Shadow FOV Scaling | ✅ Done | `shadows.lua` |

| Dawn/Dusk Transitions | ✅ Done | `transitions.lua` |

| Atmospheric Enhancements | ✅ Done | `atmosphere.lua` |

| Headlight System | ✅ Done | `headlights.lua` |

| Weather Audio | ✅ Done | `audio.lua` |

| HD Stars (night sky) | ✅ Done | `stars.lua` |



\### 4.2 In Progress



| Feature | Status | Location |

|---------|--------|----------|

| Wetness/Puddles | ⚠️ WIP (disabled) | `wetness.lua` |



\### 4.3 Missing from V1.34



| Feature | Priority | Phase |

|---------|----------|-------|

| Tokyo Morning Preset Injection | Low | 11 |

| Console Commands (dn.\*) | Low | 12 |



\---



\## 5. Keybinds



\### 5.1 Working



| Keybind | Function |

|---------|----------|

| Alt+S | Cycle weather preset (next) |

| Alt+Shift+S | Cycle weather preset (previous) |

| Alt+P | Random weather preset now (scheduler) |

| Alt+Shift+P | Force clear weather |

| Alt+T | Cycle time speed |

| Alt+R | Reset weather |

| Alt+L | Raise flat shadow distance (calibration, logs FOV+distance) |

| Alt+Q | Cycle headlight mode (auto/on/off) |

| Alt+B | Cycle headlight brightness up (0.5x → 1x → 2x → 3x → 5x) |

| Alt+Shift+B | Cycle headlight brightness down |

| Alt+Shift+L | Lower flat shadow distance (calibration, logs FOV+distance) |

| Alt+W | Force wetness (if wetness module enabled) |

| Alt+Shift+W | Force dry (if wetness module enabled) |



\### 5.2 Missing



| Keybind | Function | Phase |

|---------|----------|-------|

| Alt+D | Previous preset (alternate) | 12 |

| Alt+V | Toggle VEAO Photomode | 14 |



\---



\## 6. Phase Plan



\### 6.1 Complete



| Phase | Name | Features |

|-------|------|----------|

| 1 | Foundation | Logging, utils, state, config |

| 2 | Actor Discovery | UDS/UDW finding, world tag detection, lifecycle hooks |

| 3 | Weather Control | 13 presets, Change Weather API, Niagara particles |

| 4 | Time Control | Normal/Fast/Paused, baseline enforcement |

| 5 | Persistence \& Clouds | File save/load, cloud coverage, fog density, morning mood, PA persistence |

| 7 | Lightning \& Fog Fix | Lightning enable via UDW manager, enhanced fog via UDS Scale Fog Density |

| 6.5 | Shadow System | FOV-based shadow distance scaling, auto-update on tick |

| 8 | Dawn/Dusk Transitions | Slow time windows (500-700, 1730-1930), Tokyo tint colors |

| 9 | Atmospheric Enhancements | God rays, aurora at night, cloud shadows, second cloud layer |

| 10 | Headlights \& Audio | Auto headlights (time-based), brightness control (BP\_CarLightSpriteComponent), weather audio (UDW) |



\### 6.2 In Progress



| Phase | Name | Status | Notes |

|-------|------|--------|-------|

| 6 | Wetness System | ⚠️ WIP | Logic works, visuals don't appear. Disabled by default. |



\### 6.3 Planned



| Phase | Name | Features | New Keybinds |

|-------|------|----------|--------------|

| 11 | Mood \& Randomization | Day mood variation, random preset scheduler, tokyo morning injection | Alt+P, Alt+Shift+P |

| 12 | Polish \& Debug | Console commands (dn.\*), remaining keybinds, HD stars | Alt+D, Alt+B |

| 13 | VEAO Integration | Autoexposure based on time/available light | - |

| 14 | VEAO engine.ini Port | Graphical enhancements with separate photomode toggle | Alt+V |



\---



\## 7. File Structure



```

TXR\_Weather\_V3/

├── Scripts/

│   ├── main.lua              -- Core loop, hooks, PA handling

│   ├── config.lua            -- User settings

│   ├── core/

│   │   ├── logging.lua       -- Log system

│   │   ├── state.lua         -- Global state management

│   │   └── utils.lua         -- Helpers

│   ├── systems/

│   │   ├── actors.lua        -- UDS/UDW discovery and access

│   │   ├── weather.lua       -- Weather control (STABLE - DO NOT MODIFY)

│   │   ├── presets.lua       -- Preset definitions and values

│   │   ├── time\_of\_day.lua   -- Time control

│   │   ├── clouds\_fog.lua    -- Cloud/fog dynamics, morning mood

│   │   ├── persistence.lua   -- Save/load state

│   │   ├── keybinds.lua      -- Input handling

│   │   ├── lightning.lua     -- Lightning control (Phase 7)

│   │   ├── enhanced\_fog.lua  -- Enhanced fog density (Phase 7)

│   │   ├── shadows.lua       -- Shadow distance: flat or FOV-adaptive (Phase 6.5)

│   │   ├── transitions.lua   -- Dawn/Dusk slow time \& tint (Phase 8)

│   │   ├── atmosphere.lua    -- God rays, aurora, cloud shadows (Phase 9)

│   │   ├── headlights.lua    -- Auto headlight control (Phase 10)

│   │   ├── audio.lua         -- Weather audio control (Phase 10)

│   │   ├── stars.lua         -- HD real-stars night sky (Phase 12)

│   │   └── wetness.lua       -- Wetness/puddles (Phase 6 - WIP, disabled)

│   └── visuals/

│       └── (future modules)

├── Logs/                     -- Auto-created

├── last\_state.txt            -- Auto-created persistence file

├── DEV\_REFERENCE.md          -- This file

└── enabled.txt               -- Required for UE4SS

```



\### Files to Create (Future Phases)



```

├── systems/

│   ├── scheduler.lua      # Phase 11 (NEW)

│   └── console.lua        # Phase 12 (NEW)

```



\---



\## 8. Actor Discovery



\### Primary Actors

```lua

\-- Ultra Dynamic Sky (UDS) - Time, sun, moon, clouds, atmosphere

local UDS = FindFirstOf("Ultra\_Dynamic\_Sky\_C")



\-- Ultra Dynamic Weather (UDW) - Rain, snow, fog, wetness, lightning

local UDW = FindFirstOf("Ultra\_Dynamic\_Weather\_C")

```



\### Actor Class Paths (from dump lines 1574, 10326)

```

/Game/UltraDynamicSky/Blueprints/Ultra\_Dynamic\_Sky.Ultra\_Dynamic\_Sky\_C

/Game/UltraDynamicSky/Blueprints/Ultra\_Dynamic\_Weather.Ultra\_Dynamic\_Weather\_C

```



\### TXR-Specific Sky Actor

```lua

\-- TXR wraps UDS in a course-specific blueprint

local TXRSky = FindFirstOf("BP\_Course\_UltraDynamicSky\_C")



\-- Get UDW component from sky actor

local UDW = TXRSky\["Ultra Dynamic Weather"]

```



\---



\## 9. Weather Control API



\### Primary Function: Change Weather (dump line 14446-14448)

```lua

\-- Function signature:

\-- Change Weather(New Weather Type, Time To Transition To New Weather (Seconds))

\--   New Weather Type: ObjectProperty (UDS\_Weather\_Settings\_C reference)

\--   Time To Transition: DoubleProperty (seconds)



\-- Load preset asset

local presetPath = "/Game/UltraDynamicSky/Blueprints/Weather\_Effects/Weather\_Presets/Rain.Rain"

local preset = StaticFindObject(presetPath)



\-- Call Change Weather

local changeWeatherFunc = UDW\["Change Weather"]

changeWeatherFunc(preset, 5.0)  -- 5 second transition

```



\### Weather State Query Functions (dump lines 13495-13500)

```lua

\-- Currently Raining (returns bool via "Yes" output parameter)

local isRaining = UDW\["Currently Raining"](UDW)



\-- Currently Snowing (returns bool via "Yes" output parameter)  

local isSnowing = UDW\["Currently Snowing"](UDW)



\-- Get Display Name for Current Weather (dump line 13095)

\-- Returns: As String (StrProperty), As Enumerator (ByteProperty)

local weatherName = UDW\["Get Display Name for Current Weather"](UDW)

```



\### Direct Weather Properties (UDW)



| Property | Type | Range | Dump Line |

|----------|------|-------|-----------|

| `Cloud Coverage` | Double | 0-10 | 10404 |

| `Rain` | Double | 0-10 | 10406 |

| `Snow` | Double | 0-10 | 10412 |

| `Thunder/Lightning` | Double | 0-10 | 10410 |

| `Wind Intensity` | Double | 0-10 | 10414 |

| `Fog` | Double | 0-10 | 10408 |

| `Dust` | Double | 0-10 | 10416 |

| `Weather Speed` | Double | 0.1-10 | 10401 |



\### Manual Override Flags (UDW)

Each weather property has a manual override flag:

```lua

UDW\["Cloud Coverage - Manual Override"] = true  -- line 10405

UDW\["Rain - Manual Override"] = true            -- line 10407

UDW\["Thunder/Lightning - Manual Override"] = true -- line 10411

\-- etc.

```



\---



\## 10. Time Control API



\### Primary Time Property (UDS, dump line 1582)

```lua

\-- EXACT NAME: "Time of Day" (lowercase "of")

\-- Range: 0-2400 (0=midnight, 600=6AM, 1200=noon, 1800=6PM)

local currentTOD = UDS\["Time of Day"]

UDS\["Time of Day"] = 1200  -- Set to noon

```



\### Time Speed Control (UDS)

```lua

\-- Simulation Speed (dump line 1855)

\-- 1.0 = real-time base, higher = faster, 0 = paused

UDS\["Simulation Speed"] = 1.6667  -- Normal game speed

UDS\["Simulation Speed"] = 0.0     -- Pause time

UDS\["Simulation Speed"] = 0.6667  -- Slow (for transitions)



\-- Night speed multiplier (dump line 1859)

UDS\["Simulation Speed Night Multiplier"] = 1.0

```



\### Time Window Properties (UDS)

| Property | Type | Default | Dump Line |

|----------|------|---------|-----------|

| `Dawn Time` | Double | 600.0 | 1652 |

| `Dusk Time` | Double | 1800.0 | 1653 |

| `Day Length` | Double | 30.0 | - |

| `Night Length` | Double | 15.0 | - |



\---



\## 11. Wetness \& Puddles System



> ⚠️ \*\*Phase 6 WIP\*\* - Module exists but disabled by default (`Config.Wetness.Enabled = false`)

> 

> \*\*Status:\*\* Simulation logic works correctly, values write to UDW, but visual puddles don't appear in-game. Requires investigation of UDW's internal accumulation triggers.



\### Wetness Properties (UDW)



| Property | Type | Range | Default | Dump Line |

|----------|------|-------|---------|-----------|

| `Material Wetness` | Double | 0-1 | 0 | 10418 |

| `Max Material Wetness` | Double | 0-1 | 1.0 | 10499 |

| `Wetness Coverage Duration` | Double | seconds | 30.0 | 10508 |

| `Wetness Dry Duration` | Double | seconds | 90.0 | 10509 |



\### Puddle Properties (UDW)



| Property | Type | Range | Default | Dump Line |

|----------|------|-------|---------|-----------|

| `Puddle Coverage` | Double | 0-1 | 0.26 | 10597 |

| `Puddle Sharpness` | Double | 0-100 | 40 | 10602 |



\### Water Level (UDS, dump line 2140)

```lua

UDS\["Water Level"] = 0.0  -- Global water height offset

```



\### Enable Wetness Module

```lua

\-- In config.lua

Config.Wetness = {

&#x20;   Enabled = true,  -- Set to true to enable

}

```



\---



\## 12. Lightning System



> ✅ \*\*Phase 7 Complete\*\* - Implemented in `systems/lightning.lua`



\### Enable/Disable (UDW)



| Property | Type | Dump Line |

|----------|------|-----------|

| `Spawn Lightning Flashes` | Bool | 10469 |

| `Enable Obscured Lightning` | Bool | 10488 |



\### Intensity Controls (UDW)



| Property | Type | Default | Dump Line |

|----------|------|---------|-----------|

| `Thunder/Lightning` | Double | 0-10 | 10410 |

| `Thunder/Lightning - Manual Override` | Bool | - | 10411 |

| `Lightning Flash Frequency` | Double | 14.0 | 10470 |



\### Implementation (lightning.lua)

```lua

\-- Enable lightning for thunderstorm preset

Lightning.SetIntensity(10.0)  -- Sets Thunder/Lightning and enables flashes



\-- Or via preset

Lightning.EnableFromPreset(presetData)  -- Reads thunderIntensity from preset

```



\---



\## 13. Enhanced Fog System



> ✅ \*\*Phase 7 Complete\*\* - Implemented in `systems/enhanced\_fog.lua`



\### The Problem

The `Fog` property on UDW (0-10) only sets a weather state target. The actual fog density is computed by UDS using multipliers that weren't being adjusted.



\### The Solution

`enhanced\_fog.lua` adjusts UDS rendering properties based on fog intensity profiles. \*\*Volumetric fog must be enabled for the weather system to function properly.\*\*



\### UDS Properties (Rendering Control)



| Property | Type | Notes |

|----------|------|-------|

| `Scale Fog Density` | Double | \*\*THE KEY MULTIPLIER\*\* |

| `Base Fog Density` | Double | Baseline density |

| `Use Volumetric Fog` | Bool | \*\*REQUIRED\*\* for weather system |



\### Implementation (enhanced\_fog.lua)

```lua

\-- Apply fog from preset

EnhancedFog.ApplyFromPreset(presetData)  -- Reads fog value and selects profile



\-- Or set directly

EnhancedFog.Apply(5.0)  -- Applies "heavy" profile

```



\---



\## 14. Shadow System



> ✅ \*\*Phase 6.5 Complete\*\* - Implemented in `systems/shadows.lua`



\### The Problem

Cascaded Shadow Map (CSM) frustum culling causes shadows to disappear at low FOV values (photo mode zoom). The required shadow distance depends on:

1\. Current FOV

2\. Sun elevation angle  

3\. Camera direction relative to sun



No single CVAR or function parameter was found to directly fix the frustum alignment issue.



\### The Solution

> **Note (v3.0.13):** The 3.0.12 flat/adaptive rework was **reverted**. Its
> version-robust `applyDistance` scanned and wrote *every* `DirectionalLightComponent`
> via `FindAllOf`, which crashes the game on v1.5. The active implementation is the
> original **adaptive FOV → distance lookup table** below. `Config.Shadows` is
> currently inert (the restored module does not read it). The flat-mode / calibration
> details below are kept as historical reference for a future re-attempt.

`shadows.lua` applies a shadow distance from the FOV → distance lookup table below
(derived from extensive testing on game **v1.1**), auto-updated every tick. It writes
the sun light found via `UDS.Sun_LightComponent`. On newer game versions the table
may drift; recalibration is a future task.



\### FOV-Distance Lookup Table

Tested values with \~5000 headroom:



| FOV | Distance | FOV | Distance | FOV | Distance |

|-----|----------|-----|----------|-----|----------|

| 10 | 152000 | 50 | 126000 | 90 | 81000 |

| 20 | 149000 | 60 | 116000 | 100 | 69000 |

| 30 | 143000 | 70 | 104000 | 110 | 58000 |

| 40 | 135000 | 80 | 93000 | 120 | 45000 |



\### DirectionalLightComponent Functions Used



| Function | Purpose |

|----------|---------|

| `SetDynamicShadowDistanceMovableLight` | Sets shadow distance for movable lights |

| `SetDynamicShadowDistanceStationaryLight` | Sets shadow distance for stationary lights |

| `SetCascadeDistributionExponent` | Set to 3.0 for more near-camera resolution |



\### Functions Tested But Not Used

These were tested but either made values worse or had no effect:

\- `SetShadowDistanceFadeoutFraction`

\- `SetShadowSourceAngleFactor`

\- `SetShadowAmount`

\- `SetShadowCascadeBiasDistribution`

\- `SetCascadeTransitionFraction`

\- `SetDynamicShadowCascades`

\- Various `r.Shadow.\*` CVARs



\### Implementation (shadows.lua)

```lua

\-- Auto-updates every tick based on current FOV

Shadows.Update()



\-- Force apply (called by keybind)

Shadows.Apply()



\-- Get current state

local status = Shadows.GetStatus()

\-- Returns: {distance, fov, initialized}

```



\### Keybinds

\- \*\*Alt+L\*\* - Raise flat shadow distance by `Config.Shadows.CalibrationStep` (logs FOV + distance)

\- \*\*Alt+Shift+L\*\* - Lower flat shadow distance (logs FOV + distance)



Note: The flat-mode rework was reverted; the active shadow system is the original adaptive FOV table. Alt+L / Alt+Shift+L now force a re-apply of the shadow distance (via `Shadows.Apply`) - handy if shadows look off after a transition. (They previously drove a calibration nudge that no longer exists.)



\---



\## 14.5. Headlights System



> ✅ \*\*Phase 10 Complete\*\* - Implemented in `systems/headlights.lua`



\### Features

\- \*\*Auto Mode\*\*: Headlights turn on/off based on time of day (default: on at TOD < 500 or > 1800)

\- \*\*Force Modes\*\*: Override to always-on or always-off via Alt+Q cycling

\- \*\*Brightness Control\*\*: Adjustable brightness multiplier via BP\_CarLightSpriteComponent



\### Brightness Levels

| Level | Multiplier | Description |

|-------|------------|-------------|

| 1 | 0.5x | Dim |

| 2 | 1.0x | Default game |

| 3 | 2.0x | Bright |

| 4 | 3.0x | Very Bright (mod default) |

| 5 | 5.0x | Max |



\### Key Components

| Component | Purpose |

|-----------|---------|

| `BP\_HeadLightComponent\_C` | SpotLight component with Normal\_intensity/hibeam\_intensity blueprint vars |

| `BP\_CarLightSpriteComponent\_C` | Controls visual glow/bloom via SetIntensity() material parameter |



\### Implementation Notes

\- Brightness uses `BP\_CarLightSpriteComponent\_C:SetIntensity(multiplier)` which sets a material scalar parameter

\- Components not available immediately at map load - uses deferred retry (up to 50 ticks)

\- Toggle visibility off/on after SetIntensity to force refresh

\- Default brightness 3.0x applies automatically when headlights first turn on



\### Keybinds

\- \*\*Alt+Q\*\* - Cycle headlight mode (auto → force\_on → force\_off → auto)

\- \*\*Alt+B\*\* - Cycle brightness up

\- \*\*Alt+Shift+B\*\* - Cycle brightness down



\### API

```lua

Headlights.CycleMode()           -- Returns new mode string

Headlights.SetMode(mode)         -- "auto", "force\_on", "force\_off"

Headlights.GetMode()             -- Returns current mode

Headlights.AreHeadlightsOn()     -- Returns boolean

Headlights.CycleBrightnessUp()   -- Returns level, multiplier

Headlights.CycleBrightnessDown() -- Returns level, multiplier

Headlights.GetStatus()           -- Returns full status table

```



\---



\## 15. Atmospheric Properties



\### Aurora System (UDS)



| Property | Type | Default | Dump Line |

|----------|------|---------|-----------|

| `Use Auroras` | Bool | false | 1639 |

| `Aurora Intensity` | Double | - | 1640 |

| `Aurora Speed` | Double | 0.15 | 1641 |



\### Cloud Shadows (UDS)



| Property | Type | Default | Dump Line |

|----------|------|---------|-----------|

| `Use Cloud Shadows` | Bool | true | 1632 |

| `Cloud Shadows Intensity When Sunny` | Double | 0.7 | 1633 |



\### Stars System (UDS)



| Property | Type | Dump Line |

|----------|------|-----------|

| `Stars Intensity` | Double | 1628 |

| `Simulate Real Stars` | Bool | 1846 |



\---



\## 16. Weather Presets Reference



\### Available Presets



| Preset Name | Full Asset Path |

|-------------|-----------------|

| `Clear\_Skies` | `/Game/UltraDynamicSky/Blueprints/Weather\_Effects/Weather\_Presets/Clear\_Skies.Clear\_Skies` |

| `Partly\_Cloudy` | `/Game/UltraDynamicSky/Blueprints/Weather\_Effects/Weather\_Presets/Partly\_Cloudy.Partly\_Cloudy` |

| `Cloudy` | `/Game/UltraDynamicSky/Blueprints/Weather\_Effects/Weather\_Presets/Cloudy.Cloudy` |

| `Overcast` | `/Game/UltraDynamicSky/Blueprints/Weather\_Effects/Weather\_Presets/Overcast.Overcast` |

| `Foggy` | `/Game/UltraDynamicSky/Blueprints/Weather\_Effects/Weather\_Presets/Foggy.Foggy` |

| `Rain\_Light` | `/Game/UltraDynamicSky/Blueprints/Weather\_Effects/Weather\_Presets/Rain\_Light.Rain\_Light` |

| `Rain` | `/Game/UltraDynamicSky/Blueprints/Weather\_Effects/Weather\_Presets/Rain.Rain` |

| `Rain\_Thunderstorm` | `/Game/UltraDynamicSky/Blueprints/Weather\_Effects/Weather\_Presets/Rain\_Thunderstorm.Rain\_Thunderstorm` |

| `Snow\_Light` | `/Game/UltraDynamicSky/Blueprints/Weather\_Effects/Weather\_Presets/Snow\_Light.Snow\_Light` |

| `Snow` | `/Game/UltraDynamicSky/Blueprints/Weather\_Effects/Weather\_Presets/Snow.Snow` |

| `Snow\_Blizzard` | `/Game/UltraDynamicSky/Blueprints/Weather\_Effects/Weather\_Presets/Snow\_Blizzard.Snow\_Blizzard` |

| `Sand\_Dust\_Calm` | `/Game/UltraDynamicSky/Blueprints/Weather\_Effects/Weather\_Presets/Sand\_Dust\_Calm.Sand\_Dust\_Calm` |

| `Sand\_Dust\_Storm` | `/Game/UltraDynamicSky/Blueprints/Weather\_Effects/Weather\_Presets/Sand\_Dust\_Storm.Sand\_Dust\_Storm` |



\---



\## 17. Sound System



\### Sound Control Properties (UDW)



| Property | Type | Default | Dump Line |

|----------|------|---------|-----------|

| `Enable Weather Sound Effects` | Bool | true | 10550 |

| `Rain Volume` | Double | 1.0 | 10551 |

| `Wind Volume` | Double | 1.0 | 10555 |



\---



\## 18. Event Dispatchers



\### Weather State Events (UDW)



| Dispatcher | Fires When | Dump Line |

|------------|------------|-----------|

| `Started Raining` | Rain begins | 10665 |

| `Started Snowing` | Snow begins | 10666 |

| `Finished Raining` | Rain stops | 10667 |

| `Finished Snowing` | Snow stops | 10668 |



\---



\## 19. Persistence System



\### File Format



File: `last\_state.txt`



```

tod=1234.56

cloud=5.00

fog=1.50

preset=Rain

speed=53.333

```



\### Key Functions



```lua

Persistence.Save(reason)     -- Save current state

Persistence.LoadRaw()        -- Load from file (fresh read)

Persistence.Restore()        -- Apply loaded state

```



\---



\## 20. Lua Integration Patterns



\### Safe Property Access

```lua

local function SafeGet(actor, prop, default)

&#x20;   if not actor then return default end

&#x20;   local valid = false

&#x20;   pcall(function() valid = actor:IsValid() end)

&#x20;   if not valid then return default end

&#x20;   

&#x20;   local success, value = pcall(function() return actor\[prop] end)

&#x20;   return success and value or default

end



local function SafeSet(actor, prop, value)

&#x20;   if not actor then return false end

&#x20;   local valid = false

&#x20;   pcall(function() valid = actor:IsValid() end)

&#x20;   if not valid then return false end

&#x20;   

&#x20;   local success = pcall(function() actor\[prop] = value end)

&#x20;   return success

end

```



\### Weather Change Pattern

```lua

local function ChangeWeather(udwActor, presetName, transitionSeconds)

&#x20;   transitionSeconds = transitionSeconds or 3.0

&#x20;   

&#x20;   local path = string.format(

&#x20;       "/Game/UltraDynamicSky/Blueprints/Weather\_Effects/Weather\_Presets/%s.%s",

&#x20;       presetName, presetName

&#x20;   )

&#x20;   

&#x20;   local preset = nil

&#x20;   pcall(function() preset = StaticFindObject(path) end)

&#x20;   

&#x20;   if not preset then return false end

&#x20;   

&#x20;   local changeFunc = udwActor\["Change Weather"]

&#x20;   if not changeFunc then return false end

&#x20;   

&#x20;   local ok = pcall(function()

&#x20;       changeFunc(preset, transitionSeconds)

&#x20;   end)

&#x20;   

&#x20;   return ok

end

```



\---



\## 21. Phase Details



\### 21.1 Phase 6: Wetness System (WIP)



Status: Logic implemented, visuals not working. Disabled by default.



```lua

\-- Enable in config.lua

Config.Wetness = {

&#x20;   Enabled = true,

}

```



\### 21.2 Phase 6.5: Shadow System ✅ COMPLETE



Implemented in `systems/shadows.lua`. FOV-based shadow distance scaling with lookup table.



\### 21.3 Phase 7: Lightning \& Fog ✅ COMPLETE



Implemented in `systems/lightning.lua` and `systems/enhanced\_fog.lua`.



\### 21.4 Phase 8: Dawn/Dusk Transitions (Planned)



Target: \~400 lines | New file: `systems/transitions.lua`



```lua

SlowWindowDawnStart = 500   -- 05:00

SlowWindowDawnEnd   = 700   -- 07:00

SlowWindowDuskStart = 1730  -- 17:30

SlowWindowDuskEnd   = 1930  -- 19:30



OVERRIDE\_SLOW\_SPEED = 0.6667  -- UDS/s during transitions

```



\---



\## 22. Excluded Features



| Feature | Reason |

|---------|--------|

| Additional dry watchdogs | Rain system stable, would break it |

| Rain attach mode changes | World-space particles work correctly |

| Rainfix enhancements | Current implementation is solid |



\---



\## Quick Reference Card



\### Most Used Properties



```lua

\-- TIME (UDS)

UDS\["Time of Day"]           -- 0-2400

UDS\["Simulation Speed"]      -- 0+ (0=pause, 1=normal)



\-- WEATHER (UDW)  

UDW\["Cloud Coverage"]        -- 0-10

UDW\["Rain"]                  -- 0-10

UDW\["Thunder/Lightning"]     -- 0-10

UDW\["Fog"]                   -- 0-10



\-- FOG (UDS)

UDS\["Scale Fog Density"]     -- THE KEY MULTIPLIER

UDS\["Use Volumetric Fog"]    -- REQUIRED for weather system



\-- SHADOW (DirectionalLightComponent via UDS.Sun\_LightComponent)

sunLight:SetDynamicShadowDistanceMovableLight(distance)

sunLight:SetCascadeDistributionExponent(3.0)



\-- LIGHTNING (UDW)

UDW\["Spawn Lightning Flashes"]    -- true/false

```



\### Key Functions



```lua

\-- Change weather preset

UDW\["Change Weather"](preset, transitionSeconds)



\-- Shadow system

Shadows.Update()   -- Auto-called on tick

Shadows.Apply()    -- Manual refresh



\-- Lightning

Lightning.SetIntensity(10.0)



\-- Enhanced fog

EnhancedFog.Apply(5.0)

```



\---



\## Development Notes



1\. \*\*DO NOT TOUCH\*\* rain particle/dry enforcement systems - they are stable after 6-day debug

2\. \*\*DO NOT TOUCH\*\* shadow FOV lookup table - derived from extensive testing

3\. Use `Change Weather` API function for preset changes (not direct property writes)

4\. Always set Manual Override flags before writing weather properties

5\. Lightning system is built into UDW - enabled via `lightning.lua`

6\. \*\*Volumetric fog must be enabled\*\* for the weather system to function properly

7\. Shadow system auto-updates on tick - no manual intervention needed during gameplay

8\. Wetness module disabled by default due to visual issues



\---



\## Version History



\- \*\*v3.0.15\*\* - Phase 11: random weather scheduler (weighted pool + time-of-day weights + precip toggle; Alt+P / Alt+Shift+P); city glow (light pollution + night sky glow, night-ramped); dawn/dusk slow-time is now fraction-based (`Config.Transitions.SlowFactor`); Stars re-enabled and the course-load crash fixed (game-thread `Static Properties - Stars` + settle gate, no off-thread texture write); orphaned the non-working screen-droplets + tunnel-rain experiments

\- \*\*v3.0.14\*\* - `Config.Weather.Enabled` master switch; installer + Engine.ini profile selector; config slimmed; removed runtime CVAR migration (cvars ship in Engine.ini)

\- \*\*v3.0.13\*\* - Phase 13: Exposure module (VEAO port) + `Config.Exposure`; fixed course-load crash by disabling the Stars module (off-thread asset load + object-property write corrupted UE4SS reflection); reverted the 3.0.12 shadow rework to the original adaptive table (the `FindAllOf` blanket apply crashed on v1.5); added `core/cvars.lua` and per-module `Config.ModuleToggles`
\- \*\*v3.0.12\*\* - Phase 12: HD Stars module; shadow system rework (flat/adaptive modes, v1.5-robust apply, invalid-FOV guard, live Alt+L calibration); performance pass (throttled log flush, console-log flag honored, cached camera/module lookups, fewer redundant per-tick writes)

\- \*\*v3.0.11\*\* - Phase 9 \& 10: Atmospheric Enhancements, Auto Headlights and brightness control

\- \*\*v3.0.10\*\* - Phase 8: Dawn/Dusk transitions (slow time, Tokyo tint)

\- \*\*v3.0.9\*\* - Phase 6.5: Shadow FOV scaling system with lookup table

\- \*\*v3.0.8\*\* - Phase 7: Lightning \& Enhanced Fog systems

\- \*\*v3.0.7\*\* - PA persistence fixes (Fix7), fresh file reads, invalid TOD validation

\- \*\*v3.0.0\*\* - Initial modular rewrite



\---



\*\*END OF DEVELOPER REFERENCE\*\*

