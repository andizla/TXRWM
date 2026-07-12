-- TXR Weather Mod v3.0
-- config.lua: all user-configurable settings
-- See readme.md for full explanations; comments here are kept brief.

local Config = {}

-- Set true for distribution builds (caps log verbosity at INFO).
Config.IS_RELEASE_BUILD = true

-- ============== LOGGING ==============
Config.Logging = {
    EnableFileLogging = true,
    MinLevel = Config.IS_RELEASE_BUILD and "INFO" or "DEBUG",  -- DEBUG | INFO | WARN | ERROR
    EnableConsoleLogging = true,  -- also log to the UE4SS console
    HeartbeatInterval = 30,       -- seconds; 0 to disable
}

-- ============== WEATHER ==============
Config.Weather = {
    -- Master switch. false = no weather at all (presets/rain/cycling off),
    -- leaving time-of-day + visuals running. For "ToD only" setups.
    Enabled = true,

    -- Presets: Clear_Skies, Partly_Cloudy, Cloudy, Overcast, Foggy,
    -- Rain_Light, Rain, Rain_Thunderstorm, Snow_Light, Snow, Snow_Blizzard,
    -- Sand_Dust_Calm, Sand_Dust_Storm
    DefaultPreset = "Clear_Skies",
    DefaultTransitionTime = 5.0,  -- seconds
    FastTransitionTime = 2.0,     -- seconds (keybind cycling)
    ApplyDefaultOnLoad = true,    -- apply default preset on course load

    -- Order used by the Alt+S / Alt+Shift+S cycle keybinds
    PresetCycleOrder = {
        "Clear_Skies", "Partly_Cloudy", "Cloudy", "Overcast", "Foggy",
        "Rain_Light", "Rain", "Rain_Thunderstorm",
    },
}

-- ============== SCHEDULER (Phase 11: random preset scheduler) ==============
-- Auto-changes weather to a weighted-random preset on a randomized interval.
-- All changes route through Weather.Apply (stable rain/dry/clouds/fog pipeline).
-- A manual change (Alt+S/Alt+R) or persistence restore re-arms the timer, so the
-- scheduler never instantly overrides a deliberate pick. Respects Weather.Enabled.
Config.Scheduler = {
    Enabled = true,             -- master switch for AUTO changes (Alt+P works regardless)
    MinIntervalSeconds = 180,   -- shortest hold on a preset (3 min)
    MaxIntervalSeconds = 480,   -- longest hold on a preset (8 min)
    TransitionSeconds = 40.0,   -- blend time for scheduled changes (smooth)

    -- Set false to keep the scheduler from ever picking precipitation presets
    -- (rain/snow/dust). Does not affect manual Alt+S cycling, only the auto
    -- scheduler and Alt+P.
    AllowPrecipitation = true,

    -- Base weighted pool. Higher = more likely. Any PRESET_DATA name is valid;
    -- snow/dust are omitted by default (Tokyo expressway vibe). Set 0 to exclude.
    Weights = {
        Clear_Skies       = 4.0,
        Partly_Cloudy     = 4.0,
        Cloudy            = 3.0,
        Overcast          = 2.0,
        Foggy             = 1.0,
        Rain_Light        = 2.0,
        Rain              = 1.0,
        Rain_Thunderstorm = 0.5,
    },

    -- Time-of-day weight MULTIPLIERS, applied on top of the base weight depending
    -- on the current period (day / night / dawn / dusk). A preset not listed for a
    -- period defaults to 1.0 (unchanged). Periods come from Config.TimeOfDay
    -- (day = ~08:00-18:00). Example below makes clear skies rare during the day and
    -- favors more dramatic skies, so daytime isn't boring.
    TimeWeights = {
        day = {
            Clear_Skies   = 0.15,  -- clear sky is rare while the sun is up
            Partly_Cloudy = 1.0,
            Cloudy        = 1.5,
            Overcast      = 1.5,
            Foggy         = 0.5,
        },
        -- night / dawn / dusk omitted = all multipliers 1.0 (use the base pool).
    },
}

-- ============== TIME OF DAY ==============
Config.TimeOfDay = {
    DefaultSpeed = 53.333,  -- normal speed (~30 min day cycle)
    FastSpeed = 640.0,      -- Alt+T fast-forward (~2.2 min full day; was 320)
    StartingTOD = nil,      -- 0-2400, or nil to not override
    DawnStart = 600, DawnEnd = 800,    -- 06:00-08:00
    DuskStart = 1800, DuskEnd = 2000,  -- 18:00-20:00

    -- Night-only cycle: dusk -> night -> dawn -> straight back to dusk, skipping
    -- the day entirely. Once time passes NightOnlySkipFrom (dawn has played out),
    -- it jumps to NightOnlySkipTo and continues from there. Everything else
    -- (weather, exposure, headlights) follows the clock as normal.
    NightOnly = false,
    NightOnlySkipFrom = 800,   -- day begins here (= DawnEnd, so dawn plays in full)
    NightOnlySkipTo   = 1715,  -- land here (dusk slow-time window starts 17:30)

    -- Debug short cycle (exposure tuning aid): full-length dawn and dusk, but
    -- the flat day and night cores are cut to about an hour each via TOD jumps.
    -- Takes precedence over NightOnly. Turn off for normal play.
    DebugShortCycle = false,
    ShortCycleDaySkipFrom   = 830,   -- play day 07:30-08:30, then jump...
    ShortCycleDaySkipTo     = 1630,  -- ...to 16:30 (dusk lens ramp starts 16:50)
    ShortCycleNightSkipFrom = 2230,  -- play night 21:30-22:30, then jump...
    ShortCycleNightSkipTo   = 420,   -- ...to 04:20 (pre-dawn ramp starts 04:40)
}

-- ============== WETNESS (WIP) ==============
-- The experimental DLWE/material road-wetness system (visual). NOT the grip system.
Config.Wetness = {
    Enabled = false,
}

-- ============== DYNAMIC WET GRIP (gameplay) ==============
-- Tire grip drops as the road gets wet (rain/snow) and recovers as it dries. Reads UDW
-- "Rain" (0-10) and drives it into the GLOBAL tire degradation table
-- (DT_TireDegradationInfo). Because every car's tire model reads that table, this affects
-- ALL cars (the player AND the AI rivals) and works in PA rival battles. Grip rates are
-- scaled from the cached dry baseline, so it never compounds and fully recovers to stock
-- when it stops raining. Braking is NOT affected (the degradation table has no braking
-- entry). The global-tire-table grip approach is credited to Chrystales. See
-- systems/wet_grip.lua.
Config.WetGrip = {
    Enabled = true,    -- master switch for the dynamic wet grip effect

    -- Grip multipliers at FULL wetness (heaviest rain). 1.0 = unchanged, lower = less
    -- grip. Grip interpolates from 1.0 (bone dry) down to these floors. Lateral
    -- (cornering) grip is usually hit a little harder than longitudinal. Applies to every
    -- car, so the AI gets just as slippery as you do.
    MinGripMult     = 0.80,  -- forward traction floor (longitudinal grip rates)
    MinSideGripMult = 0.72,  -- cornering grip floor (lateral grip rates)

    -- UDW precipitation (0-10) at/above this counts as "fully wet" (max grip loss). TXRWM
    -- writes Rain=5 (light), 7 (rain), 10 (thunderstorm), so 7.0 = full slick in a normal
    -- downpour. Lower it to reach full slickness in lighter rain.
    PrecipForFullWet = 7.0,
    SnowCounts = false,      -- treat snow as slippery too (uses max of rain and snow)
    SnowWeight = 1.0,        -- scale snow's contribution (1.0 = same as rain, 0 = ignore)

    -- Wet up fast, dry slowly: the road stays slick a while after the rain stops.
    -- Rough seconds to reach most of the way to the new wetness target.
    WetRiseSeconds = 8.0,
    DrySeconds     = 45.0,

    UpdateMs = 250,    -- how often wet grip recomputes / re-applies
    -- Diagnostic: logs live precip, wetness and the grip factors written to the table
    -- (throttled ~2s). Flip true, drive/PA-race in the rain, read the log (grep "WetGrip"),
    -- then back to false.
    Debug = false,
}

-- ============== STARS ==============
Config.Stars = {
    Enabled = true,
    -- Enabling "Simulate Real Stars" makes UDS use its own built-in 360-degree
    -- real-star map; we no longer swap the texture ourselves (that off-thread
    -- object write was the old course-load crash). Apply is deferred past BeginPlay.
    Tiling = nil,    -- nil = keep UDS default
    Intensity = 3.0, -- nil = keep UDS default (1.5 -> 3.0 2026-07-06: "stars quite dim")
}

-- ============== WIND DEBRIS ==============
-- UDW Niagara debris (leaves/dust) that appears when wind intensity is high (storms).
-- Default OFF while in testing; set Enabled=true.
Config.WindDebris = {
    Enabled = true,
    SpawnCount = nil,  -- nil = UDW default
    Debug = false,     -- log a readback (~3s) while enabled; set false once diagnosed
}

-- ============== MOON ==============
-- Moon appearance: realistic phases (not a flat full disc), optional phase change
-- over time, and a Scale knob for a bigger, cinematic moon. Sky-rendered, works in TXR.
Config.Moon = {
    Enabled = true,
    RenderPhases = true,    -- realistic phases instead of a full disc
    PhaseOverTime = true,   -- phase advances night to night (set false to pin Phase)
    Phase = nil,            -- 0-1 to force a phase (e.g. 0.2 crescent); needs PhaseOverTime=false
    Scale = 1.25,            -- nil = UDS default; bump (e.g. 1.5) for a bigger atmospheric moon
    Contrast = nil,         -- nil = UDS default
}

-- ============== VOLUMETRIC LIGHT RAYS ==============
-- UDS god-ray shafts through gaps in the cloud cover (Niagara additive cards, like
-- rain, so it renders in TXR). Shows in daytime under broken/overcast cloud. IndividualClouds
-- > 0 casts rays through NATURAL gaps so they show without painting cloud coverage.
Config.LightRays = {
    Enabled = true,
    Intensity = nil,         -- nil = UDS default
    IndividualClouds = 1.0,  -- 0-1: rays through natural cloud gaps (0 = painted gaps only)
    UsingSun = true,         -- sun as the ray source
    Debug = false,           -- periodic readback while enabled (one-shot at apply always logs)
}

-- ============== TRANSITIONS (dawn/dusk slow-time + Tokyo tint) ==============
Config.Transitions = {
    Enabled = true,

    -- Slow window keyed to the SUN (2026-07-07): active while the sun's
    -- elevation is inside [SlowElevMin, SlowElevMax] degrees, so it stays
    -- centered on the actual sunrise/sunset wherever the drifting in-game date
    -- puts them (the date advances every in-game midnight; fixed clock
    -- windows aim at the wrong sky within days of play). +/-8 deg is roughly
    -- 40-45 real minutes either side of the sun event; it covers the whole
    -- measured light collapse (which the old 17:30-19:30 window ENDED at).
    SlowElevMax = 8.0,
    SlowElevMin = -8.0,

    -- Clock-window FALLBACK, used only when sun elevation is unavailable
    -- (LightCycle module off, or the first seconds after a course load).
    SlowDawnStart = 500, SlowDawnEnd = 700,    -- 05:00-07:00
    SlowDuskStart = 1730, SlowDuskEnd = 1930,  -- 17:30-19:30

    -- Time speed during dawn/dusk as a FRACTION of normal. Lower = slower, so the
    -- window lingers longer in real time. 0.40 = original feel (~5.7 min dusk).
    -- NOTE: slow-time applies at NORMAL speed only (fast-forward is exempt).
    SlowFactor = 0.40,
}

-- ============== KEYBINDS ==============
Config.Keybinds = {
    Enabled = true,
    CycleWeatherNext = { Key = "S", Modifiers = {"Alt"} },
    CycleWeatherPrev = { Key = "S", Modifiers = {"Alt", "Shift"} },
    ToggleTimeSpeed  = { Key = "T", Modifiers = {"Alt"} },   -- Normal/Fast/Pause
    ResetWeather     = { Key = "R", Modifiers = {"Alt"} },
    RandomPreset     = { Key = "P", Modifiers = {"Alt"} },          -- scheduler: random preset now
    ForceClear       = { Key = "P", Modifiers = {"Alt", "Shift"} }, -- force Clear Skies
    DebugForceWetness= { Key = "W", Modifiers = {"Alt"} },
    DebugForceDry    = { Key = "W", Modifiers = {"Alt", "Shift"} },
    ShadowDistanceUp = { Key = "L", Modifiers = {"Alt"} },
    ShadowDistanceDown = { Key = "L", Modifiers = {"Alt", "Shift"} },
    CycleHeadlights    = { Key = "Q", Modifiers = {"Alt"} },          -- manual headlights on/off (garage too); auto is config-only
    BrightnessUp     = { Key = "B", Modifiers = {"Alt"} },
    BrightnessDown   = { Key = "B", Modifiers = {"Alt", "Shift"} },
    -- DEV: UDS exposure-bias liveness test (+2 EV on all five knobs, press
    -- again to restore). Unbound for release; uncomment to re-enable.
    -- ExposureDebugOverlay = { Key = "H", Modifiers = {"Alt"} },

    -- Manual rain suppression: toggles the rain/snow particles off/on at the
    -- component level (weather state untouched; it keeps "raining"). The
    -- tunnel system drives the same mechanism automatically.
    PrecipSuppressTest = { Key = "J", Modifiers = {"Alt"} },

    -- Exposure tuning feedback: press when the picture looks wrong; logs time,
    -- weather, and the exposure values in effect (grep the log for "ExposureTune").
    ExposureTooDark   = { Key = "D", Modifiers = {"Alt"} },
    ExposureTooBright = { Key = "D", Modifiers = {"Alt", "Shift"} },
    -- Skylight tuning session (flat-paint hunt): Alt raises by Tune.Step,
    -- Alt+Shift lowers. Overrides stick across slot flips until SkylightReset.
    -- Confirm logs TOD + weather + the three values (grep for "SkylightTune").
    SkylightAlbedoUp   = { Key = "Z", Modifiers = {"Alt"} },          -- r.Lumen.SkylightLeaking.ReflectionAverageAlbedo
    SkylightAlbedoDown = { Key = "Z", Modifiers = {"Alt", "Shift"} },
    SkylightRoughUp    = { Key = "X", Modifiers = {"Alt"} },          -- r.Lumen.SkylightLeaking.Roughness
    SkylightRoughDown  = { Key = "X", Modifiers = {"Alt", "Shift"} },
    SkylightMultUp     = { Key = "C", Modifiers = {"Alt"} },          -- r.SkylightIntensityMultiplier
    SkylightMultDown   = { Key = "C", Modifiers = {"Alt", "Shift"} },
    SkylightConfirm    = { Key = "V", Modifiers = {"Alt"} },          -- log the datapoint
    SkylightReset      = { Key = "V", Modifiers = {"Alt", "Shift"} }, -- drop overrides, back to slot curve
}

-- ============== PA (PARKING AREA) ==============
-- The PA scene lives inside the outgame world but has its own working sky
-- and weather. Stock, it is CANNED: always night (TOD 19:50, heavy cloud).
--   "continue": carry your course weather and time of day into the PA and
--               keep the clock running at your course time speed (default)
--   "freeze":   carry the course state, then freeze time while in the PA
--   "stock":    leave the canned PA night alone (pre-3.4 behavior)
Config.PA = {
    Mode = "continue",
}

-- ============== PERSISTENCE ==============
Config.Persistence = {
    Enabled = true,
    AutoSaveInterval = 30,  -- seconds; 0 to disable
    RestoreOnLoad = true,
    SaveFileName = "last_state.txt",
}

-- ============== CLOUDS AND FOG ==============
Config.CloudsFog = {
    Enabled = true,
    CloudAutoEnabled = true,
    FogAutoEnabled = true,

    CloudMin = 0.5, CloudMax = 4.5,  -- 0-10 scale (4.5 allows real cumulus fields;
                                     -- was 3.0, which biased daytime toward near-clear)
    FogMin = 0.0, FogMax = 1.5,      -- 0-10 scale

    CloudSmoothingSeconds = 30.0,
    FogSmoothingSeconds = 45.0,
    PresetTransitionSeconds = 10.0,

    -- Long-term drift
    CloudDriftAmplitude = 0.4, CloudDriftPeriod = 180.0,
    CloudJitterAmplitude = 0.15, CloudJitterPeriod = 25.0,
    FogDriftAmplitude = 0.25, FogPhaseShift = 0.35,

    -- Day mood (varies cloud/fog day-to-day)
    MoodEnabled = true,
    MoodSmoothingSeconds = 60.0,
    MoodCloudScale = 0.5, MoodFogScale = 0.2,

    -- Morning weather profiles
    MorningProfilesEnabled = true,
    MorningProfileWeights = { clear = 0.3, partial = 0.4, overcast = 0.2, foggy = 0.1 },
    MorningStartOffset = 0, MorningEndOffset = 200, MorningBlendEdge = 50,
    ResumeRandomizeAfterMorning = true,
}

-- ============== ACTOR DISCOVERY ==============
Config.ActorDiscovery = {
    MaxRetries = 30,
    RetryInterval = 0.5,           -- seconds
    PeriodicCheckInterval = 2.0,   -- seconds, when not on course
}

-- ============== MAIN LOOP ==============
Config.MainLoop = {
    TickIntervalMs = 125,    -- 8 ticks/sec
    LogEveryNLoops = 200,    -- ~25s at 8Hz
}

-- ============== DEBUG ==============
Config.Debug = {
    VerboseLogging = false,
    LogPropertyAccess = false,
    LogActorDiscovery = true,
    LogWeatherTransitions = true,
}

-- ============== ATMOSPHERE (god rays, aurora, cloud shadows) ==============
Config.Atmosphere = {
    Enabled = true,
    EnableCloudShadows = true,
    EnableGodRays = true,
    -- Auroras CANNOT render in TXR: the 2D aurora texture (Aurora_Clouds) was
    -- stripped from the game's cooked content (runtime-verified 2026-07-02).
    -- The machinery is kept for a future content-pipeline route; leave false.
    EnableAurora = false,
    -- Second cloud layer = high cirrus above the cumulus (the real v1.5 property is
    -- "Two Layers"; the old name was a silent no-op, so this only STARTED working
    -- when that was fixed). Very cinematic, but the docs warn it raises cloud
    -- rendering cost significantly. DISABLED 2026-07-03: prime suspect for the
    -- driving-session GPU crashes that started the night it first really turned on
    -- (D3D12 device fault). Re-enable deliberately for ONE test session if you want
    -- to confirm or clear it.
    EnableSecondCloudLayer = false,

    -- City glow (Tokyo night ambiance): light pollution + night sky glow, ramped
    -- in at night. Light pollution lights cloud bases from below (warm sodium
    -- amber by default); night sky glow keeps the night sky from going pitch black.
    EnableCityGlow = true,
    LightPollutionMax = 1.5,   -- peak light-pollution intensity at deep night
                               -- (1.0 -> 1.5 2026-07-07: night-floor lift first
                               -- pass toward the real-Tokyo city-glow reference)
    NightSkyGlowMax = 1.5,     -- peak ambient night-sky glow (0.5 -> 1.5 2026-07-06, night-feel test)
    -- Colors are LinearColor {R,G,B,A}; defaults live in atmosphere.lua. Uncomment to override:
    -- LightPollutionColor = {R = 1.00, G = 0.55, B = 0.25, A = 1.0},
    -- NightSkyGlowColor   = {R = 0.45, G = 0.50, B = 0.65, A = 1.0},

    -- God rays = the sun's screen-space light-shaft bloom (EnableGodRays above).
    -- UDS stores max brightness as a (clear, overcast) pair; the multiplier scales
    -- both ends. Tint is slightly warm for a cinematic shaft color.
    SunShaftBrightnessMult = 1.3,
    SunShaftTint = {R = 1.00, G = 0.92, B = 0.80, A = 1.0},

    -- Cloud shadow softness (sunny/overcast), scaled up from stock for soft
    -- dappled light rolling over the track instead of hard-edged blotches.
    CloudShadowSoftnessMult = 1.3,
}

-- ============== RAINBOW ==============
-- UDW's rainbow. Rendered on a world MESH (not a post-process), so it shows in TXR.
-- UDW decides WHEN it's visible from the live weather state: there must be rain (or
-- fog) feeding it, the camera must be in direct sun (not under overcast), and the
-- sun low enough. So it appears naturally as rain clears toward the sun; you won't
-- see it in every weather, which is intended. We just enable it; UDW drives strength.
Config.Rainbow = {
    Enabled = true,
    MaxStrength = nil,      -- nil = UDW default cap (0-1). Lower for a subtler arc.
    MaskAboveClouds = nil,  -- nil = UDW default (visibility above the cloud layer)
    MaskBelowWater = nil,   -- nil = UDW default
}

-- ============== SPACE LAYER (nebula in the night sky) ==============
-- UDS Space Layer: a faint Nebula band rendered INTO the sky material (like the
-- stars/moon), plus a space-glow control. UDS fades it by day/night itself, so it
-- only shows at night. It composites via DBuffer decals (the installer's Engine.ini
-- profile sets r.DBuffer=1; the module also requests it at runtime as a fallback).
-- Stylistic (real Tokyo skies are light-polluted); keep the intensity modest or set
-- Enabled=false if you prefer a plain night sky.
Config.SpaceLayer = {
    Enabled = true,
    RenderNebula = true,
    NebulaIntensity = 1.6,      -- nil = UDS default; modest so it reads as faint depth
    NebulaNoiseScale = nil,     -- nil = UDS default
    NebulaColor1 = nil,         -- LinearColor {R,G,B,A}; nil = UDS default
    NebulaColor2 = nil,
    NebulaColor3 = nil,
    BrightnessNight = nil,      -- nil = UDS default (Space Layer Brightness at night)
    BrightnessDay = nil,        -- nil = UDS default (usually ~0; hidden by day)
    SpaceGlowBrightness = nil,  -- nil = UDS default
    SetDBuffer = true,          -- set r.DBuffer 1 at runtime (needed for compositing)
}

-- ============== CINEMATIC SKY (daytime clouds + atmosphere grade) ==============
-- Cinematic daytime: richer volumetric-cloud shading, stronger golden hour,
-- visible cirrus wisps, higher cloud render quality (photo-mode zoom) and a lazier
-- cloud drift. Applied once per course (settle-gated, game thread) then baked with
-- UDS's own Static Properties calls, the proven stars/nebula/moon pattern.
--
-- Knobs whose internal scale is undocumented are MULTIPLIERS on the value UDS
-- spawned with (the sky actor is recreated per course, so this never compounds);
-- 1.0 = leave stock. Saturation/Contrast are absolute 1.0-centered values.
-- Original -> tuned pairs are logged on every apply (grep "CinematicSky").
Config.CinematicSky = {
    Enabled = true,

    -- Global sky/lighting grade. Saturation is absolute (stock confirmed 1.0 in
    -- the apply log). Contrast is a MULTIPLIER: its stock is 0.1, NOT 1.0-centered
    -- (an absolute 1.06 here meant ~10x contrast, the 2026-07-03 blowout bug).
    Saturation   = 1.15,  -- richer sky + lighting color
    ContrastMult = 1.10,  -- 0.1 -> 0.11; keep subtle, exposure does the heavy lifting

    -- Volumetric cloud look (multipliers on stock)
    ExtinctionMult        = 1.25,  -- denser, darker cloud cores (dramatic cumulus)
    DetailNoiseMult       = 1.20,  -- crisper cloud edge detail (helps photo-mode zoom)
    MultiscatterMult      = 1.20,  -- stronger silver-lining glow with sun behind cloud
    AmbientLightMult      = 0.90,  -- a touch less flat ambient fill = more cloud shape
    AmbientSaturationMult = 1.15,  -- more color in the cloud ambient light

    -- Cloud wisps (high cirrus streaks rendered behind the volumetric layer)
    WispsOpacityMult       = 1.35, -- more visible cirrus (clear + cloudy opacities)
    WispsColorIntensityMult= 1.20,
    WispsSunBrightnessMult = 1.50, -- cirrus catches fire near the sun (golden hour)

    -- Sky atmosphere (only applied if UDS controls the atmosphere; gated at runtime)
    OvercastLuminanceMult = 1.25,  -- overcast days stay luminous instead of gray mush
    RayleighDesatMult     = 0.70,  -- keep more blue in the sky under cloud
    SunsetIntensityMult   = 1.35,  -- stronger sunset/sunrise absorption colors

    -- Cloud render quality (ray-march sample scales; GPU cost rises with these).
    -- STOCK since 2026-07-03: crashes kept coming with raised samples + the second
    -- cloud layer, so ALL new GPU load is rolled back to isolate the cause. The
    -- cinematic look above (extinction/multiscatter/wisps/grade) is material-param
    -- cheap and stays. Raise these again only after a clean session or two.
    ViewSampleQualityMult   = 1.0,
    ShadowSampleQualityMult = 1.0,

    -- Cloud movement mood
    CloudSpeedMult          = 0.60, -- slower, statelier drift
    CloudsMoveWithTimeOfDay = true, -- clouds stay coherent during Alt+T timelapses

    Debug = false,  -- extra per-property logging while tuning
}

-- ============== REAL SUN (EXPERIMENT) ==============
-- Real-world solar simulation. The module ALWAYS logs the sky's stock
-- Simulation values once per course (grep "RealSun", the Phase 0 probe).
-- With Enabled=true it also switches UDS to Simulate Real Sun/Moon for the
-- coordinates and pinned date below: astronomically correct sunrise/sunset
-- times and sun path. NOTE: the exposure slot curve is tuned for the stock
-- sun path; expect dawn/dusk timing shifts on dates far from late July
-- (Tokyo sunset ~18:50, the closest match to the current curve).
Config.RealSun = {
    Enabled = true,       -- flip true to run the experiment

    Latitude  = 35.676,    -- Tokyo
    Longitude = 139.650,
    TimeZone  = 9.0,       -- UTC+9 (DST is forced off; Japan has none)
    RealMoon  = true,      -- also simulate real moon position and phase

    -- Pinned date (the sun path depends on it; nil = leave the sky's own date)
    Year = 2026, Month = 7, Day = 25,

    -- World-space direction of north, degrees (nil = leave stock; UDS default
    -- north is +X). Calibrate by watching where the sun actually sets.
    NorthYaw = nil,

    -- ---- Date policy (independent of Enabled above) ----
    -- The stock game advances the calendar every in-game midnight, so the
    -- season (and sunrise/sunset times) drift as you play (the game persists
    -- this across sessions itself). Set PinMonth+PinDay to force a fixed date
    -- once per course instead (PinYear optional). nil = let the seasons drift.
    PinYear = nil, PinMonth = nil, PinDay = nil,

}

-- ============== VIGNETTE (hide HUD vignette, opt-in) ==============
-- Hide TXR's in-game HUD vignette (the darkened corner frame) for a cleaner,
-- photographic look. Pure UI-widget toggle on TXR's own HUD (no game files). Default
-- OFF: it removes a vanilla HUD element, so it's opt-in.
Config.Vignette = {
    Enabled = true,
    Hide = true,    -- true = hide the vignette (set false to force it visible)
}

-- ============== PHOTO MODE UNLOCKER ==============
-- Removes the restrictions on TXR's Advanced Photo Mode free camera (folded in from
-- the standalone PhotoModeUnlocked mod, which is kept on disk but disabled). Pure
-- runtime reflection, no game files touched. Only does anything while photo mode is
-- open. ON by default (it's purely additive and self-gating).
Config.PhotoMode = {
    Enabled = true,

    -- Let the camera pass through geometry and leave the track (disables the
    -- free-camera collision sphere and the spring-arm collision pull-in).
    DisableCameraCollision = true,

    -- Remove the cap on how far the free camera can fly from the car. MaxDistance is a
    -- (large) fallback cap still applied in case a code path reads it. Units = cm
    -- (100 = 1 m); 5,000,000 = 50 km.
    RemoveDistanceLimit = true,
    MaxDistance        = 5000000.0,
    MaxDistanceHeight  = 5000000.0,

    -- Raise the orbit (non-free) photo camera's left/right + up/down pan limits.
    RaiseOrbitLimits = true,
    OrbitMaxLeftRight = 1000000.0,
    OrbitMaxUpDown    = 1000000.0,

    -- FOV / zoom: widen the in-game photo-mode FOV slider so the normal zoom control
    -- goes further (no keybinds). MoveCapture applies the slider value WITHOUT
    -- re-clamping, so raising the slider's Min/Max IS the limit removal.
    WidenFovSlider = true,
    FovSliderMin = 0.25,   -- new minimum / zoom-in limit (the widget rejects <= 0)
    FovSliderMax = 140.0,  -- new maximum (zoom OUT / wide angle)
    FovStep      = 1.0,    -- normal nudge step (FOV at/above FovFineBelow)
    FovStepFine  = 0.25,   -- finer step when zoomed in (FOV below FovFineBelow)
    FovFineBelow = 10.0,   -- use the fine step below this FOV (it zooms in exponentially)
    -- The FOV slider is matched by its internal ListKey "FOV" (the on-screen "Zoom" name
    -- is localized display text and unreliable to match). DebugSliders logs every slider's
    -- key + range once, flip true for one confirming test, then back to false.
    FovSliderMatch = "fov",
    DebugSliders   = false,

    -- The photo-mode "Vignette" slider ships at 40; force it to a sane default once each
    -- time the menu opens (you can still raise it again afterward).
    ResetVignette = true,
    VignetteValue = 0.01,        -- ~off (0 itself can misbehave; 0.01 is imperceptible)
    VignetteMatch = "vignette",  -- match the vignette slider by its key/label

    -- Free-camera fly speed (vanilla is very slow). Vanilla is cached once so the
    -- multiplier never compounds across camera respawns. 1.0 = vanilla.
    SetMovementSpeed = true,
    MovementSpeedMult = 2.5,

    -- Camera rotation gets twitchy zoomed in (a tiny FOV magnifies every wobble), so
    -- scale rotation sensitivity with FOV: full speed at/above RotationRefFov,
    -- proportionally slower below, with a floor so extreme zoom never fully freezes.
    ScaleRotationWithFov = true,
    RotationRefFov = 60.0,
    RotationMinScale = 0.02,

    ReassertMs = 200,  -- how often the unlocks are re-applied while photo mode is open

    -- Diagnostic for the "long exposure drops some unlocks until you move" case. When
    -- true, logs (throttled ~2s) whether the re-assert loop keeps firing under the
    -- slow-mo AND reads back the live collision/distance limits before re-writing them,
    -- so we can tell if the game is re-enabling them every frame (a race) vs the loop
    -- stalling. Leave false for normal play; flip true only when reproducing.
    Debug = false,
}

-- ============== HEADLIGHTS ==============
Config.Headlights = {
    Enabled = true,
    -- AUTO vs MANUAL is set HERE only (there is no runtime auto-toggle keybind):
    --   "auto"      = exposure-driven on/off (Alt+Q manual toggle is ignored).
    --   "force_on"  = manual, default on  (Alt+Q toggles on/off).
    --   "force_off" = manual, default off (Alt+Q toggles on/off).
    -- The manual on/off state + brightness persist across restarts; "auto" does not
    -- get overridden by the persisted state. In the garage, Alt+Q toggles the
    -- displayed car's lights (pop-ups animate there too).
    Mode = "auto",

    -- Auto mode keys on the SUN'S ELEVATION in degrees (season-proof; the
    -- game's date drifts, so a clock would aim wrong within days). Lamps come
    -- ON once the sun sinks to OnElev (dusk) and go OFF once it climbs past
    -- OffElev (dawn); the gap is the hysteresis band. The crossings match the
    -- previously tuned lens thresholds (ON ~ where TXR's own auto lights up).
    OnElev  = -1.0,
    OffElev = 0.5,

    DefaultBrightnessLevel = 3,  -- 1=0.5x 2=1.0x 3=2.0x 4=3.0x 5=5.0x

    -- Light-button gesture (keyboard + controller; reads the hi-beam input state, so
    -- device-agnostic). Acted on release by how long the light button was held:
    --   <= GestureTapMaxSeconds   -> headlights ON  (a short press / tap)
    --   >= GestureOffHoldSeconds  -> headlights OFF (a deliberate hold)
    -- Manual mode only (auto is untouchable).
    GestureTapMaxSeconds  = 1.0,
    GestureOffHoldSeconds = 2.0,

    -- Clock fallback when no sun elevation is available.
    OnTOD = 1900,    -- on after 19:00
    OffTOD = 600,    -- off after 06:00
}

-- ============== AUDIO ==============
Config.Audio = {
    Enabled = true,
    EnableRain = true, EnableWind = true, EnableThunder = true,
    RainVolume = 1.0, WindVolume = 0.8, ThunderVolume = 1.0,
}

-- ============== TUNING SLIDER RANGE (garage alignment tab) ==============
-- Widens the alignment sliders (camber/toe/ride height/wheel offset) to
-- RangeMultiplier x their stock range, and re-asserts saved out-of-range values
-- on car spawn (the game stores them but won't apply extremes on load itself).
-- Locked rows are skipped; this does NOT unlock parts/settings.
Config.Tuning = {
    Enabled = true,
    RangeMultiplier = 3.0,  -- 3x stock range each way; 1.0 = stock (inactive)
    SkipLockedRows = true,
    ReapplyOnLoad = true,   -- re-assert saved alignment on course load + garage display
    Debug = false,          -- log alignment rows, slider probes + widened ranges
}

-- ============== LIGHT CYCLE (exposure + look) ==============
-- Stock auto-exposure runs; this module can bias it via UDS's Exposure Bias
-- knobs from the sun's REAL elevation (season-proof), applies the per-course
-- post-process look overrides, and holds the cvar layer at engine-neutral
-- (the UDS-less garage is the one cvar-driven look). Tune with Alt+D /
-- Alt+Shift+D; feedback lines carry sun_elev + the applied EV.
Config.LightCycle = {
    Enabled = true,
    UpdateIntervalSeconds = 1.0,  -- update cadence; writes are change-gated

    -- Diagnostic: push neutral cvars only, no shaping (raw UDS light).
    DiagnosticNeutralCvars = false,

    -- EXPOSURE POLICY: the stock pipeline runs untouched apart from the
    -- skylight-leak kill (Config.Tunnels.KillVolumeSkylightLeak) and the
    -- look overrides below. Shaping ships neutral; tune from Alt+D data
    -- (Logs/tuning_feedback.log).

    -- EV bias vs sun elevation (0 = stock). Anchor shape: day / golden
    -- hour / sunset / blue hour / civil twilight / night.
    BiasCurve = {
        { elev =  30, bias = 0.0 },
        { elev =   8, bias = 0.0 },
        { elev =   3, bias = 0.0 },
        { elev =   0, bias = 0.0 },
        { elev =  -3, bias = 0.0 },
        { elev =  -6, bias = 0.0 },
        { elev = -10, bias = 0.0 },
    },

    LeakAlbedo = 0.07,  -- r.Lumen.SkylightLeaking.ReflectionAverageAlbedo

    -- UDS night floors. Mult scales the stock value; nil = leave stock.
    AbsentBrightnessMult = 1.0,    -- "Directional Lights Absent Brightness" (stock 1.5)
    NightCloudyBrightness = nil,   -- "Extra Night Brightness When Cloudy" (stock 0.0)
    OvercastBrightnessNight = nil, -- "Overcast Brightness (Night)" (stock 0.2)

    -- Clear the game's Curve_ExposureCompensation per course. Keep false:
    -- the stock curve reads right with the skylight leak dead.
    KillExposureCompCurve = false,

    SunVectorSign = -1,  -- UDS sun vector = light direction; implementation constant
    SunriseTOD = 600, SunsetTOD = 1930,  -- pseudo-elevation fallback events

    -- Auto-exposure adaptation speeds (f-stops/second; stock 3/1, nil =
    -- stock). Asymmetric like real eyes: adapting to BRIGHT (SpeedUp, e.g.
    -- exiting a tunnel) is fast or the exit blows out white; adapting to
    -- DARK (SpeedDown) stays slow and cinematic.
    AdaptSpeedUp = 3.0,
    AdaptSpeedDown = 0.35,

    -- POST-PROCESS LOOK OVERRIDES: FPostProcessSettings fields written once
    -- per course onto the course sky's main PP component (wins conflicts
    -- with the game's second PP comp). Numbers/bools direct; vectors as
    -- {X=,Y=,Z=,W=}. Verified by "PP one-shots readback" overrides_held.
    -- Remove a line = stock.
    PostProcess = {
        BloomIntensity = 0.2,                       -- game runs 0.75
        VignetteIntensity = 0.0,                    -- game runs 0.4
        ScreenSpaceReflectionQuality = 100.0,       -- game runs 50
        ScreenSpaceReflectionMaxRoughness = 0.4,    -- game runs 0.6
        LumenSceneDetail = 2.0,                     -- game runs 1
        LumenFinalGatherLightingUpdateSpeed = 2.0,
        -- Shadow contrast: the game LIFTS unlit areas two ways, film toe
        -- 0.3 (UE default 0.55) and local-exposure shadow scale 0.7 (a
        -- regional lift that tracks auto-exposure). Neutralizing both
        -- darkens shadows without moving mid-tones.
        FilmToe = 0.55,
        LocalExposureShadowContrastScale = 1.0,     -- game runs 0.7
        LocalExposureHighlightContrastScale = 1.0,  -- game runs 0.8
    },

    -- Skylight tuning keybinds (Alt+Z/X/C, Alt+V, Alt+Shift+V)
    Tune = { Step = 0.05, RoughnessBaseline = 1.0 },
}

-- ============== TUNNELS (covered road: rain hide + GI fix) ==============
-- Covered = the car's road-data tunnel attribute (roof bit; exact
-- dev-authored boundaries, catches every real bore) OR a roof trace (lone
-- overpasses, which the road data does not mark). Covered = precipitation
-- components HIDDEN (they keep simulating; weather state untouched;
-- restore = unhide, instant). Also clears the course volumes' authored
-- skylight-leak override (the boundary lighting flip).
Config.Tunnels = {
    Enabled = true,

    -- Research reference for the ProbePPVolumes ENTER/EXIT classification
    -- lines; no longer drives the rain logic.
    TunnelVolumes = {
        "9C6B0021494DE9FA01_1223679167",  -- Takebashi east
        "9C6B0021494DE9FA01_1415472168",  -- Takebashi west
        "PostProcessVolume_20",           -- long C1 (Miyakezaka JCT)
        "PostProcessVolume_19",           -- Kasumigaseki
        "PostProcessVolume_24",           -- Ginza (C1 inner)
    },
    TunnelAutoByBias = true,

    TunnelRainKill = true,      -- hide precipitation on covered road
    TunnelRainLookahead = 1.2,  -- seconds of travel the roof trace probes ahead

    -- Fog on covered road: global fog is blind to ceilings, so foggy
    -- weather reads as a white wall inside bores. Scale Fog Density is
    -- multiplied by this while the road data says roofed. 0.0 = no fog at
    -- all under a roof; 1.0 = damp off.
    CoveredFogMult = 0.0,

    -- Clear the authored LumenSkylightLeaking=1.0 override on all course
    -- volumes (it flooded covered sections with flat sky ambient at every
    -- volume edge). Armed line logs leakCleared=N.
    KillVolumeSkylightLeak = true,

    -- Roof trace for lone overpasses: downward Visibility leg for deck
    -- tops + upward leg for tunnel linings. Shorten the trace if rain dies
    -- under tall gantries.
    OverpassRainKill = true,
    OverpassTraceLength = 5000,  -- units (50 m)
    OverpassDebug = false,       -- throttled "Roof trace debug" lines

    -- Trace-cover release hold (uncovered polls) so girder gaps don't
    -- strobe rain; road-data cover releases on the first uncovered poll.
    RainClearPolls = 4,

    -- Poll cadence: fast while it can rain, relaxed when dry.
    PollSecondsRain = 0.25,
    PollSecondsDry = 1.0,

    -- Research: revive the PP-volume ENTER/EXIT classification lines.
    ProbePPVolumes = false,
}

-- ============== MODULE TOGGLES ==============
-- Per-module on/off. false = the module's handle is nil-ed in main.lua, so its
-- tick/setup never runs. (Actors/Presets/Keybinds are core and not toggleable.)
Config.ModuleToggles = {
    Weather     = true,
    Scheduler   = true,
    TimeOfDay   = true,
    CloudsFog   = true,
    Shadows     = true,
    Persistence = true,
    Transitions = true,
    Headlights  = true,
    Atmosphere  = true,
    Audio       = true,
    WindDebris  = true,
    LightRays   = true,
    Moon        = true,
    Stars       = true,
    Rainbow     = true,   -- mesh-rendered rainbow (UDW drives visibility)
    SpaceLayer  = true,   -- night-sky nebula
    CinematicSky= true,   -- daytime cloud/atmosphere grade (see Config.CinematicSky)
    LightCycle  = true,   -- sun-elevation exposure (see Config.LightCycle)
    Tunnels     = true,   -- covered-road rain kill (see Config.Tunnels)
    RealSun     = true,   -- real-sun probe + experiment (see Config.RealSun)
    Vignette    = true,   -- hide the HUD vignette (see Config.Vignette)
    PhotoMode   = true,   -- photo mode free-camera unlocks
    WetGrip     = true,   -- dynamic wet grip
    Tuning      = true,   -- alignment slider-range widening (see Config.Tuning)
}

-- ============== VERSION ==============
Config.Version = {
    Major = 3, Minor = 5, Patch = 0,
    String = "3.5.0",
    Name = "TXR Weather Mod",
    FullName = "TXR Weather Mod v3.5.0",
}

return Config
