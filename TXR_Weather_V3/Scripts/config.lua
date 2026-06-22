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
    HDStars = true,  -- use the high-res Real Stars texture
    TexturePath = "/Game/UltraDynamicSky/Textures/Sky/Real_Stars.Real_Stars",
    Tiling = 1.0,    -- 1.0 = full-sky, no repeat
    Intensity = nil, -- nil = keep UDS default
}

-- ============== TRANSITIONS (dawn/dusk slow-time + Tokyo tint) ==============
Config.Transitions = {
    Enabled = true,
    SlowDawnStart = 500, SlowDawnEnd = 700,    -- 05:00 - 07:00
    SlowDuskStart = 1730, SlowDuskEnd = 1930,  -- 17:30 - 19:30
    SlowSpeed = 21.333,  -- speed during slow windows (40% of normal)
}

-- ============== KEYBINDS ==============
Config.Keybinds = {
    Enabled = true,
    CycleWeatherNext = { Key = "S", Modifiers = {"Alt"} },
    CycleWeatherPrev = { Key = "S", Modifiers = {"Alt", "Shift"} },
    ToggleTimeSpeed  = { Key = "T", Modifiers = {"Alt"} },   -- Normal/Fast/Pause
    ResetWeather     = { Key = "R", Modifiers = {"Alt"} },
    DebugForceWetness= { Key = "W", Modifiers = {"Alt"} },
    DebugForceDry    = { Key = "W", Modifiers = {"Alt", "Shift"} },
    ShadowDistanceUp = { Key = "L", Modifiers = {"Alt"} },
    ShadowDistanceDown = { Key = "L", Modifiers = {"Alt", "Shift"} },
    CycleHeadlights  = { Key = "Q", Modifiers = {"Alt"} },
    BrightnessUp     = { Key = "B", Modifiers = {"Alt"} },
    BrightnessDown   = { Key = "B", Modifiers = {"Alt", "Shift"} },
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
}

-- ============== HEADLIGHTS ==============
Config.Headlights = {
    Enabled = true,
    Mode = "auto",   -- auto | force_on | force_off
    OnTOD = 1830,    -- on after 18:30
    OffTOD = 630,    -- off after 06:30
    DefaultBrightnessLevel = 4,  -- 1=0.5x 2=1.0x 3=2.0x 4=3.0x 5=5.0x
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
    TimeOfDay   = true,
    CloudsFog   = true,
    Shadows     = true,
    Persistence = true,
    Transitions = true,
    Headlights  = true,
    Atmosphere  = true,
    Audio       = true,
    Stars       = false,  -- DISABLED: causes a course-load crash, fix pending
}

-- ============== VERSION ==============
Config.Version = {
    Major = 3, Minor = 0, Patch = 13,
    String = "3.0.13",
    Name = "TXR Weather Mod",
    FullName = "TXR Weather Mod v3.0.13",
}

return Config
