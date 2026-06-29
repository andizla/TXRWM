-- TXR Weather Mod v3.0
-- config.lua - all user-configurable settings
-- See readme.md for full explanations; comments here are kept brief.

local Config = {}

-- Set true for distribution builds.
Config.IS_RELEASE_BUILD = false

-- ============== LOGGING ==============
Config.Logging = {
    EnableFileLogging = true,
    MinLevel = "DEBUG",           -- DEBUG | INFO | WARN | ERROR
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
    -- (rain/snow/dust). Useful while the in-tunnel rain issue persists. Does not
    -- affect manual Alt+S cycling - only the auto scheduler and Alt+P.
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
    FastSpeed = 320.0,      -- Alt+T fast-forward
    StartingTOD = nil,      -- 0-2400, or nil to not override
    DawnStart = 600, DawnEnd = 800,    -- 06:00 - 08:00
    DuskStart = 1800, DuskEnd = 2000,  -- 18:00 - 20:00
}

-- ============== WETNESS (WIP) ==============
Config.Wetness = {
    Enabled = false,
}

-- ============== STARS ==============
Config.Stars = {
    Enabled = true,
    -- Enabling "Simulate Real Stars" makes UDS use its own built-in 360-degree
    -- real-star map; we no longer swap the texture ourselves (that off-thread
    -- object write was the old course-load crash). Apply is deferred past BeginPlay.
    Tiling = nil,    -- nil = keep UDS default
    Intensity = 1.5, -- nil = keep UDS default
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
    Scale = 1.5,            -- nil = UDS default; bump (e.g. 1.5) for a bigger atmospheric moon
    Contrast = nil,         -- nil = UDS default
}

-- ============== VOLUMETRIC LIGHT RAYS ==============
-- UDS god-ray shafts through gaps in the cloud cover (Niagara additive cards, like
-- rain - renders in TXR). Shows in daytime under broken/overcast cloud. IndividualClouds
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
    SlowDawnStart = 500, SlowDawnEnd = 700,    -- 05:00 - 07:00
    SlowDuskStart = 1730, SlowDuskEnd = 1930,  -- 17:30 - 19:30
    -- Time speed during dawn/dusk as a FRACTION of normal. Lower = slower, so the
    -- window lingers longer in real time. 0.40 = original feel (~5.7 min dusk).
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
    -- Exposure tuning feedback: press when the picture looks wrong; logs time,
    -- weather, and the exposure values in effect (grep the log for "ExposureTune").
    ExposureTooDark   = { Key = "D", Modifiers = {"Alt"} },
    ExposureTooBright = { Key = "D", Modifiers = {"Alt", "Shift"} },
}

-- ============== PERSISTENCE ==============
Config.Persistence = {
    Enabled = true,
    AutoSaveInterval = 30,  -- seconds; 0 to disable
    RestoreOnLoad = true,
    ForceReloadStateOnCourseEnter = true,  -- restore exact snapshot on course enter
    SaveFileName = "last_state.txt",
}

-- ============== CLOUDS AND FOG ==============
Config.CloudsFog = {
    Enabled = true,
    CloudAutoEnabled = true,
    FogAutoEnabled = true,

    CloudMin = 0.5, CloudMax = 3.0,  -- 0-10 scale
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
    EnableAurora = true,
    EnableSecondCloudLayer = true,

    -- City glow (Tokyo night ambiance): light pollution + night sky glow, ramped
    -- in at night. Light pollution lights cloud bases from below (warm sodium
    -- amber by default); night sky glow keeps the night sky from going pitch black.
    EnableCityGlow = true,
    LightPollutionMax = 1.0,   -- peak light-pollution intensity at deep night (tune to taste)
    NightSkyGlowMax = 0.5,     -- peak ambient night-sky glow
    -- Colors are LinearColor {R,G,B,A}; defaults live in atmosphere.lua. Uncomment to override:
    -- LightPollutionColor = {R = 1.00, G = 0.55, B = 0.25, A = 1.0},
    -- NightSkyGlowColor   = {R = 0.45, G = 0.50, B = 0.65, A = 1.0},
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
    Mode = "force_on",

    -- Auto mode tracks the Exposure module's interpolated brightness (lens proxy:
    -- ~0.78 bright day .. ~30 deep night) instead of a fixed clock, so the lamps
    -- follow available light and stay in sync if you retune exposure. The On/Off
    -- pair is a hysteresis band (On > Off) to stop flicker around the threshold.
    OnLens  = 6.0,   -- turn ON once brightness-lens rises above this (getting dark)
    OffLens = 3.5,   -- turn OFF once it falls below this (getting light)

    DefaultBrightnessLevel = 3,  -- 1=0.5x 2=1.0x 3=2.0x 4=3.0x 5=5.0x

    -- Light-button gesture (keyboard + controller; reads the hi-beam input state, so
    -- device-agnostic). Acted on release by how long the light button was held:
    --   <= GestureTapMaxSeconds   -> headlights ON  (a short press / tap)
    --   >= GestureOffHoldSeconds  -> headlights OFF (a deliberate hold)
    -- Manual mode only (auto is untouchable).
    GestureTapMaxSeconds  = 1.0,
    GestureOffHoldSeconds = 2.0,

    -- Fallback ONLY when the Exposure module is disabled/unavailable (no lens signal).
    OnTOD = 1900,    -- on after 19:00
    OffTOD = 600,    -- off after 06:00
}

-- ============== AUDIO ==============
Config.Audio = {
    Enabled = true,
    EnableRain = true, EnableWind = true, EnableThunder = true,
    RainVolume = 1.0, WindVolume = 0.8, ThunderVolume = 1.0,
}

-- ============== AUTO-EXPOSURE (TOD -> Lumen/eye-adaptation, ex-VEAO) ==============
-- 144 slots of 10 min across 00:00-24:00 (TOD 0..2400); garage forces night (slot 0).
-- Requires the exposure cvars in engine.ini (shipped minimal ini / installer).
Config.Exposure = {
    Enabled = true,
    SlotCount = 144,
    SlotSizeTOD = 2400 / 144,    -- 16.667 TOD units = 10 min
    UpdateIntervalSeconds = 0.5,  -- slot re-evaluation rate. Kept low so exposure
                                  -- tracks fast time (Alt+T 320x advances ~18 TOD/2s,
                                  -- which lagged ~11 game-min per update at the old 2.0).
                                  -- Flat day/night re-evals are near-free (unchanged
                                  -- values skip the cvar push); only transitions emit.

    -- Per-slot cvars driven by the module
    CvarSky  = "r.SkylightIntensityMultiplier",
    CvarLeak = "r.Lumen.SkylightLeaking.ReflectionAverageAlbedo",
    CvarLens = "r.EyeAdaptation.LensAttenuation",

    -- [1..144] = { sky, leak, lens }. Index 1 = 00:00-00:10. Curves interpolated
    Slots = {
        -- NIGHT CORE
        [  1] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 00:00-00:10
        [  2] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 00:10-00:20
        [  3] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 00:20-00:30
        [  4] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 00:30-00:40
        [  5] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 00:40-00:50
        [  6] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 00:50-01:00
        [  7] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 01:00-01:10
        [  8] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 01:10-01:20
        [  9] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 01:20-01:30
        [ 10] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 01:30-01:40
        [ 11] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 01:40-01:50
        [ 12] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 01:50-02:00
        [ 13] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 02:00-02:10
        [ 14] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 02:10-02:20
        [ 15] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 02:20-02:30
        [ 16] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 02:30-02:40
        [ 17] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 02:40-02:50
        [ 18] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 02:50-03:00
        [ 19] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 03:00-03:10
        [ 20] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 03:10-03:20
        [ 21] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 03:20-03:30
        [ 22] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 03:30-03:40
        [ 23] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 03:40-03:50
        [ 24] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 03:50-04:00
        [ 25] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 04:00-04:10
        [ 26] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 04:10-04:20
        [ 27] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 04:20-04:30
        [ 28] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 04:30-04:40
        [ 29] = { sky = 0.9700, leak = 0.050, lens = 28.00 }, -- 04:40-04:50
        [ 30] = { sky = 0.9350, leak = 0.050, lens = 26.00 }, -- 04:50-05:00
        -- DAWN TRANSITION (night -> day)
        [ 31] = { sky = 0.9000, leak = 0.050, lens = 24.00 }, -- 05:00-05:10
        [ 32] = { sky = 0.8000, leak = 0.050, lens = 20.67 }, -- 05:10-05:20
        [ 33] = { sky = 0.7000, leak = 0.050, lens = 17.33 }, -- 05:20-05:30
        [ 34] = { sky = 0.6000, leak = 0.050, lens = 14.00 }, -- 05:30-05:40
        [ 35] = { sky = 0.4833, leak = 0.050, lens = 11.00 }, -- 05:40-05:50
        [ 36] = { sky = 0.3667, leak = 0.050, lens =  8.00 }, -- 05:50-06:00
        [ 37] = { sky = 0.2500, leak = 0.050, lens =  5.00 }, -- 06:00-06:10
        [ 38] = { sky = 0.2067, leak = 0.050, lens =  4.17 }, -- 06:10-06:20
        [ 39] = { sky = 0.1633, leak = 0.050, lens =  3.33 }, -- 06:20-06:30
        [ 40] = { sky = 0.1200, leak = 0.050, lens =  2.50 }, -- 06:30-06:40
        [ 41] = { sky = 0.1067, leak = 0.050, lens =  2.27 }, -- 06:40-06:50
        [ 42] = { sky = 0.0933, leak = 0.050, lens =  2.03 }, -- 06:50-07:00
        [ 43] = { sky = 0.0800, leak = 0.050, lens =  1.80 }, -- 07:00-07:10
        [ 44] = { sky = 0.0633, leak = 0.050, lens =  1.53 }, -- 07:10-07:20
        [ 45] = { sky = 0.0467, leak = 0.050, lens =  1.27 }, -- 07:20-07:30
        [ 46] = { sky = 0.0300, leak = 0.050, lens =  1.00 }, -- 07:30-07:40
        [ 47] = { sky = 0.0233, leak = 0.050, lens =  0.90 }, -- 07:40-07:50
        [ 48] = { sky = 0.0167, leak = 0.050, lens =  0.80 }, -- 07:50-08:00
        [ 49] = { sky = 0.0100, leak = 0.050, lens =  0.70 }, -- 08:00-08:10
        [ 50] = { sky = 0.0083, leak = 0.050, lens =  0.68 }, -- 08:10-08:20
        [ 51] = { sky = 0.0067, leak = 0.050, lens =  0.67 }, -- 08:20-08:30
        -- DAY
        [ 52] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 08:30-08:40
        [ 53] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 08:40-08:50
        [ 54] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 08:50-09:00
        [ 55] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 09:00-09:10
        [ 56] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 09:10-09:20
        [ 57] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 09:20-09:30
        [ 58] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 09:30-09:40
        [ 59] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 09:40-09:50
        [ 60] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 09:50-10:00
        [ 61] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 10:00-10:10
        [ 62] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 10:10-10:20
        [ 63] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 10:20-10:30
        [ 64] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 10:30-10:40
        [ 65] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 10:40-10:50
        [ 66] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 10:50-11:00
        [ 67] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 11:00-11:10
        [ 68] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 11:10-11:20
        [ 69] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 11:20-11:30
        [ 70] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 11:30-11:40
        [ 71] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 11:40-11:50
        [ 72] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 11:50-12:00
        [ 73] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 12:00-12:10
        [ 74] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 12:10-12:20
        [ 75] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 12:20-12:30
        [ 76] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 12:30-12:40
        [ 77] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 12:40-12:50
        [ 78] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 12:50-13:00
        [ 79] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 13:00-13:10
        [ 80] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 13:10-13:20
        [ 81] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 13:20-13:30
        [ 82] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 13:30-13:40
        [ 83] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 13:40-13:50
        [ 84] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 13:50-14:00
        [ 85] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 14:00-14:10
        [ 86] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 14:10-14:20
        [ 87] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 14:20-14:30
        [ 88] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 14:30-14:40
        [ 89] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 14:40-14:50
        [ 90] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 14:50-15:00
        [ 91] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 15:00-15:10
        [ 92] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 15:10-15:20
        [ 93] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 15:20-15:30
        [ 94] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 15:30-15:40
        [ 95] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 15:40-15:50
        [ 96] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 15:50-16:00
        [ 97] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 16:00-16:10
        [ 98] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 16:10-16:20
        [ 99] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 16:20-16:30
        [100] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 16:30-16:40
        [101] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 16:40-16:50
        [102] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 16:50-17:00
        [103] = { sky = 0.0050, leak = 0.050, lens =  0.65 }, -- 17:00-17:10
        [104] = { sky = 0.0133, leak = 0.050, lens =  0.73 }, -- 17:10-17:20
        [105] = { sky = 0.0217, leak = 0.050, lens =  0.82 }, -- 17:20-17:30
        -- DUSK -> EVENING (brightened; rises earlier after sundown)
        [106] = { sky = 0.0300, leak = 0.050, lens =  0.90 }, -- 17:30-17:40
        [107] = { sky = 0.0500, leak = 0.050, lens =  1.60 }, -- 17:40-17:50
        [108] = { sky = 0.0700, leak = 0.050, lens =  2.30 }, -- 17:50-18:00
        [109] = { sky = 0.0900, leak = 0.050, lens =  3.00 }, -- 18:00-18:10
        [110] = { sky = 0.1333, leak = 0.050, lens =  4.50 }, -- 18:10-18:20
        [111] = { sky = 0.1767, leak = 0.050, lens =  6.00 }, -- 18:20-18:30
        [112] = { sky = 0.2200, leak = 0.050, lens =  7.50 }, -- 18:30-18:40
        [113] = { sky = 0.2967, leak = 0.050, lens =  9.67 }, -- 18:40-18:50
        [114] = { sky = 0.3733, leak = 0.050, lens = 11.83 }, -- 18:50-19:00
        [115] = { sky = 0.4500, leak = 0.050, lens = 14.00 }, -- 19:00-19:10
        [116] = { sky = 0.5267, leak = 0.050, lens = 16.00 }, -- 19:10-19:20
        [117] = { sky = 0.6033, leak = 0.050, lens = 18.00 }, -- 19:20-19:30
        [118] = { sky = 0.6800, leak = 0.050, lens = 20.00 }, -- 19:30-19:40
        [119] = { sky = 0.7433, leak = 0.050, lens = 21.67 }, -- 19:40-19:50
        [120] = { sky = 0.8067, leak = 0.050, lens = 23.33 }, -- 19:50-20:00
        [121] = { sky = 0.8700, leak = 0.050, lens = 25.00 }, -- 20:00-20:10
        [122] = { sky = 0.9033, leak = 0.050, lens = 26.00 }, -- 20:10-20:20
        [123] = { sky = 0.9367, leak = 0.050, lens = 27.00 }, -- 20:20-20:30
        [124] = { sky = 0.9700, leak = 0.050, lens = 28.00 }, -- 20:30-20:40
        [125] = { sky = 0.9807, leak = 0.050, lens = 28.50 }, -- 20:40-20:50
        [126] = { sky = 0.9913, leak = 0.050, lens = 29.00 }, -- 20:50-21:00
        [127] = { sky = 1.0020, leak = 0.050, lens = 29.50 }, -- 21:00-21:10
        [128] = { sky = 1.0030, leak = 0.050, lens = 29.67 }, -- 21:10-21:20
        [129] = { sky = 1.0040, leak = 0.050, lens = 29.83 }, -- 21:20-21:30
        -- NIGHT CORE
        [130] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 21:30-21:40
        [131] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 21:40-21:50
        [132] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 21:50-22:00
        [133] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 22:00-22:10
        [134] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 22:10-22:20
        [135] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 22:20-22:30
        [136] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 22:30-22:40
        [137] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 22:40-22:50
        [138] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 22:50-23:00
        [139] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 23:00-23:10
        [140] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 23:10-23:20
        [141] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 23:20-23:30
        [142] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 23:30-23:40
        [143] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 23:40-23:50
        [144] = { sky = 1.0050, leak = 0.050, lens = 30.00 }, -- 23:50-24:00
    },
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
    Stars       = true,   -- re-enabled 2026-06-24 with the safe bool+Static-Properties+settle-gate rewrite
}

-- ============== VERSION ==============
Config.Version = {
    Major = 3, Minor = 0, Patch = 19,
    String = "3.0.19",
    Name = "TXR Weather Mod",
    FullName = "TXR Weather Mod v3.0.19",
}

return Config
