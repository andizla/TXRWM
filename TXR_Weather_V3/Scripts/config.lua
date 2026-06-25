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
    TransitionSeconds = 20.0,   -- blend time for scheduled changes (smooth)

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
            Foggy         = 1.2,
        },
        -- night / dawn / dusk omitted = all multipliers 1.0 (use the base pool).
    },
}

-- ============== TIME OF DAY ==============
Config.TimeOfDay = {
    DefaultSpeed = 53.333,  -- normal speed (~30 min day cycle)
    FastSpeed = 160.0,      -- Alt+T fast-forward
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
    CycleHeadlights    = { Key = "Q", Modifiers = {"Alt"} },          -- manual headlights on/off (auto is config-only)
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
    PresetTransitionSeconds = 5.0,

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
    --   "force_on"  = manual, default on  (Alt+Q toggles on/off, also in the garage).
    --   "force_off" = manual, default off (Alt+Q toggles on/off, also in the garage).
    -- The manual on/off state + brightness persist across restarts; "auto" does not
    -- get overridden by the persisted state.
    Mode = "auto",

    -- Auto mode tracks the Exposure module's interpolated brightness (lens proxy:
    -- ~0.78 bright day .. ~30 deep night) instead of a fixed clock, so the lamps
    -- follow available light and stay in sync if you retune exposure. The On/Off
    -- pair is a hysteresis band (On > Off) to stop flicker around the threshold.
    OnLens  = 6.0,   -- turn ON once brightness-lens rises above this (getting dark)
    OffLens = 3.5,   -- turn OFF once it falls below this (getting light)

    DefaultBrightnessLevel = 3,  -- 1=0.5x 2=1.0x 3=2.0x 4=3.0x 5=5.0x

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
-- 48 slots of 30 min across 00:00-24:00 (TOD 0..2400); garage forces night (slot 0).
-- Requires the exposure cvars in engine.ini (shipped minimal ini / installer).
Config.Exposure = {
    Enabled = true,
    SlotCount = 48,
    SlotSizeTOD = 50.0,           -- 50 TOD units = 30 min
    UpdateIntervalSeconds = 2.0,  -- slot re-evaluation rate

    -- Per-slot cvars driven by the module
    CvarSky  = "r.SkylightIntensityMultiplier",
    CvarLeak = "r.Lumen.SkylightLeaking.ReflectionAverageAlbedo",
    CvarLens = "r.EyeAdaptation.LensAttenuation",

    -- [1..48] = { sky, leak, lens }. Index 1 = 00:00-00:30.
    Slots = {
        -- NIGHT CORE
        [ 1] = { sky = 1.005, leak = 0.050, lens = 30.00 }, -- 00:00-00:30
        [ 2] = { sky = 1.005, leak = 0.050, lens = 30.00 }, -- 00:30-01:00
        [ 3] = { sky = 1.005, leak = 0.050, lens = 30.00 }, -- 01:00-01:30
        [ 4] = { sky = 1.005, leak = 0.050, lens = 30.00 }, -- 01:30-02:00
        [ 5] = { sky = 1.005, leak = 0.050, lens = 30.00 }, -- 02:00-02:30
        [ 6] = { sky = 1.005, leak = 0.050, lens = 30.00 }, -- 02:30-03:00
        [ 7] = { sky = 1.005, leak = 0.050, lens = 30.00 }, -- 03:00-03:30
        [ 8] = { sky = 1.005, leak = 0.050, lens = 30.00 }, -- 03:30-04:00
        -- PRE-DAWN
        [ 9] = { sky = 1.005, leak = 0.050, lens = 30.00 }, -- 04:00-04:30
        [10] = { sky = 1.005, leak = 0.050, lens = 30.00 }, -- 04:30-05:00
        [11] = { sky = 1.005, leak = 0.050, lens = 30.00 }, -- 05:00-05:30
        [12] = { sky = 0.500, leak = 0.050, lens = 25.00 }, -- 05:30-06:00
        -- DAWN TRANSITION
        [13] = { sky = 0.050, leak = 0.050, lens =  3.78 }, -- 06:00-06:30
        [14] = { sky = 0.050, leak = 0.050, lens =  3.78 }, -- 06:30-07:00
        [15] = { sky = 0.050, leak = 0.050, lens =  2.78 }, -- 07:00-07:30
        -- DAY
        [16] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 07:30-08:00
        [17] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 08:00-08:30
        [18] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 08:30-09:00
        [19] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 09:00-09:30
        [20] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 09:30-10:00
        [21] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 10:00-10:30
        [22] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 10:30-11:00
        [23] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 11:00-11:30
        [24] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 11:30-12:00
        [25] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 12:00-12:30
        [26] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 12:30-13:00
        [27] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 13:00-13:30
        [28] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 13:30-14:00
        [29] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 14:00-14:30
        [30] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 14:30-15:00
        [31] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 15:00-15:30
        [32] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 15:30-16:00
        [33] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 16:00-16:30
        [34] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 16:30-17:00
        [35] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 17:00-17:30
        [36] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 17:30-18:00
        -- LATE AFTERNOON -> EVENING
        [37] = { sky = 0.005, leak = 0.050, lens =  0.78 }, -- 18:00-18:30
        [38] = { sky = 0.005, leak = 0.050, lens =  1.00 }, -- 18:30-19:00
        [39] = { sky = 0.005, leak = 0.050, lens =  3.00 }, -- 19:00-19:30
        [40] = { sky = 0.005, leak = 0.050, lens =  5.00 }, -- 19:30-20:00
        [41] = { sky = 0.050, leak = 0.050, lens = 10.00 }, -- 20:00-20:30
        [42] = { sky = 0.500, leak = 0.050, lens = 15.00 }, -- 20:30-21:00
        -- NIGHT CORE
        [43] = { sky = 0.500, leak = 0.050, lens = 15.00 }, -- 21:00-21:30
        [44] = { sky = 1.005, leak = 0.050, lens = 30.00 }, -- 21:30-22:00
        [45] = { sky = 1.005, leak = 0.050, lens = 30.00 }, -- 22:00-22:30
        [46] = { sky = 1.005, leak = 0.050, lens = 30.00 }, -- 22:30-23:00
        [47] = { sky = 1.005, leak = 0.050, lens = 30.00 }, -- 23:00-23:30
        [48] = { sky = 1.005, leak = 0.050, lens = 30.00 }, -- 23:30-24:00
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
    Major = 3, Minor = 0, Patch = 17,
    String = "3.0.17",
    Name = "TXR Weather Mod",
    FullName = "TXR Weather Mod v3.0.17",
}

return Config
