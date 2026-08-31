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

    -- Active presets: Clear_Skies, Partly_Cloudy, Cloudy, Overcast,
    -- Overcast_Heavy, Foggy, Rain_Light, Rain, Rain_Thunderstorm.
    -- (Snow/dust exist but are not in the cycle.)
    DefaultPreset = "Clear_Skies",
    DefaultTransitionTime = 5.0,  -- seconds
    FastTransitionTime = 2.0,     -- seconds (keybind cycling)
    ApplyDefaultOnLoad = true,    -- apply default preset on course load

    -- Order used by the Alt+S / Alt+Shift+S cycle keybinds (this list WINS
    -- over presets.lua's DEFAULT_CYCLE_ORDER; keep both in sync)
    PresetCycleOrder = {
        "Clear_Skies", "Partly_Cloudy", "Cloudy", "Overcast", "Overcast_Heavy",
        "Foggy", "Rain_Light", "Rain", "Rain_Thunderstorm",
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
        Clear_Skies       = 2.5,
        Partly_Cloudy     = 3.5,
        Cloudy            = 3.0,
        Overcast          = 2.0,
        Overcast_Heavy    = 1.5,
        Foggy             = 1.0,
        Rain_Light        = 2.0,
        Rain              = 1.5,
        Rain_Thunderstorm = 0.5,
    },

    -- Time-of-day weight MULTIPLIERS, applied on top of the base weight depending
    -- on the current period (day / night / dawn / dusk). A preset not listed for a
    -- period defaults to 1.0 (unchanged). Periods come from Config.TimeOfDay
    -- (day = ~08:00-18:00). Example below makes clear skies rare during the day and
    -- favors more dramatic skies, so daytime isn't boring.
    TimeWeights = {
        day = {
            Clear_Skies    = 0.15,  -- clear sky is rare while the sun is up
            Partly_Cloudy  = 1.0,
            Cloudy         = 1.5,
            Overcast       = 1.5,
            Overcast_Heavy = 1.5,
            Foggy          = 0.5,
        },
        -- night / dawn / dusk omitted = all multipliers 1.0 (use the base pool).
    },
}

-- ============== TIME OF DAY ==============
Config.TimeOfDay = {
    DefaultSpeed = 53.333,  -- normal speed (~30 min day cycle)
    FastSpeed = 640.0,      -- Alt+T fast-forward (~2.2 min full day)
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
    Enabled = true,

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
    Tiling = nil,    -- nil = keep UDS default
    Intensity = 3.0, -- star layer intensity (nil = UDS default)

    -- The rotating real-star 360 map with the Milky Way band (false = a
    -- static tiling star texture). Star visibility also depends on
    -- Config.Atmosphere.LightPollutionMax staying at or below 1.0.
    SimulateRealStars = true,

    -- Tiling-mode texture pan; irrelevant while SimulateRealStars=true.
    TilingStarSpeed = 0.0,

    -- Advanced star-compositing knobs; leave at defaults unless digging.
    CityGlowBoost = 1.0,       -- star opacity vs the night glow layer
    ColorBoost = 1.0,          -- star density (promotes fainter map stars)
}

-- ============== WIND DEBRIS ==============
-- UDW Niagara debris (leaves/dust) that appears when wind intensity is high (storms).
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
    -- 0-1: rays through natural cloud gaps (the density lever; 0 = none
    -- in TXR, since cloud coverage is never painted). Lower if the field
    -- feels busy, raise toward 1.0 if rays get too rare.
    IndividualClouds = 0.6,
    UsingSun = true,         -- sun as the ray source
    Debug = false,           -- periodic readback while enabled (one-shot at apply always logs)
    -- Plausibility gate (2026-07-28): sun shafts are forced OFF while any
    -- of these presets is active (solid deck / fog / rain = no visible sun
    -- to shaft) and return when the sky breaks up again.
    DisabledPresets = {
        "Overcast", "Overcast_Heavy", "Foggy",
        "Rain_Light", "Rain", "Rain_Thunderstorm",
    },
    -- Distance/geometry shaping (stock: depthFade 100000, spacing 50000).
    -- DepthFadeDistance pushes rays off nearby structures toward the
    -- distance; PointSpacing thins the field.
    MaxDistanceKm     = nil,
    DepthFadeDistance = 400000,  -- higher = rays sit further away
    PointSpacing      = 110000,  -- higher = sparser ray field
    RayLength         = nil,
    MaxRayLength      = nil,
}

-- ============== TRANSITIONS (dawn/dusk slow-time + Tokyo tint) ==============
Config.Transitions = {
    Enabled = true,

    -- Slow window keyed to the SUN: active while the sun's elevation is
    -- inside [SlowElevMin, SlowElevMax] degrees, so it stays centered on
    -- the actual sunrise/sunset in any season. +/-8 deg is roughly 40-45
    -- real minutes either side of the sun event.
    SlowElevMax = 8.0,
    SlowElevMin = -8.0,

    -- Clock-window FALLBACK, used only when sun elevation is unavailable
    -- (LightCycle module off, or the first seconds after a course load).
    SlowDawnStart = 500, SlowDawnEnd = 700,    -- 05:00-07:00
    SlowDuskStart = 1730, SlowDuskEnd = 1930,  -- 17:30-19:30

    -- Tokyo tint window, also SUN-KEYED: strength peaks at the sun event
    -- (elevation 0 = the actual sunrise/sunset, any season) and fades
    -- linearly to zero at these elevations. One pair serves dawn and dusk.
    -- The old clock shape remains the no-elevation fallback.
    TintDayElev = 30.0,     -- gone by this elevation on the day side
    TintNightElev = -12.0,  -- gone by this elevation on the night side

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
    ShadowDistanceUp = { Key = "L", Modifiers = {"Alt"} },
    ShadowDistanceDown = { Key = "L", Modifiers = {"Alt", "Shift"} },
    CycleHeadlights    = { Key = "Q", Modifiers = {"Alt"} },          -- manual headlights on/off (garage too); auto is config-only
    BrightnessUp     = { Key = "B", Modifiers = {"Alt"} },
    BrightnessDown   = { Key = "B", Modifiers = {"Alt", "Shift"} },
    -- Exposure trim + dark look: live during a photo session AND in the
    -- plain garage (no photomode needed there). Session and garage keep
    -- separate values; both reset when their context ends.
    PhotoExposureUp   = { Key = "E", Modifiers = {"Alt"} },          -- brighter
    PhotoExposureDown = { Key = "E", Modifiers = {"Alt", "Shift"} }, -- darker
    PhotoDarkLook     = { Key = "G", Modifiers = {"Alt"} },          -- crushed low-key toggle

    -- Rain-spot datapoint key: press at any wrong-rain spot (raining
    -- under cover, dry in the open); the logged mesh names feed
    -- Config.RainCollision.TargetPatterns.
    NoteRainSpot = { Key = "N", Modifiers = {"Alt"} },
    LeakTestToggle = { Key = "J", Modifiers = {"Alt"} },  -- leak-hunt: clear + low sun + frozen clock (toggle)
    -- Slab editor keys (leak-fix authoring): dev builds only; inert in
    -- release builds, where systems/slab_editor.lua is absent.
    SlabTunerToggle      = { Key = "J", Modifiers = {"Alt", "Shift"} },
    SlabSpawnHere        = { Key = "Y", Modifiers = {"Alt"} },
    SlabPadSelectNearest = { Key = "NUMPAD7" },
    SlabPadParamNext     = { Key = "NUMPAD8" },
    SlabPadClone         = { Key = "NUMPAD9" },
    SlabPadDec           = { Key = "NUMPAD4" },
    SlabPadConfirm       = { Key = "NUMPAD5" },
    SlabPadInc           = { Key = "NUMPAD6" },
    SlabPadSpawn         = { Key = "NUMPAD1" },
    SlabPadParamPrev     = { Key = "NUMPAD2" },
    SlabPadDelete        = { Key = "NUMPAD3" },
    SlabPadJump          = { Key = "NUMPAD0" },     -- spawn a SOLID pitched ramp 12m ahead ;D
    SlabPadRayClone      = { Key = "NUMPADDOT" },   -- clone whatever the camera points at

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

    -- Star visibility nudge: the stars' rendered luminance CLAMPS below a
    -- lifted night sky, so this dials the NIGHT SKY GLOW background.
    -- Alt+K = glow DOWN 0.1 (stars cut through more), Alt+Shift+K = glow
    -- UP. Lines land in tuning_feedback.log (grep "StarTune"); settle the
    -- crossover, then bake it into Config.Atmosphere.NightSkyGlowMax.
    StarIntensityUp   = { Key = "K", Modifiers = {"Alt"} },
    StarIntensityDown = { Key = "K", Modifiers = {"Alt", "Shift"} },
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

    -- Cap the PA clock at normal speed: continue mode carries the COURSE
    -- time speed, so an Alt+T fast-forward keeps racing the clock while
    -- you sit in the PA menu. true = clamp back to TimeOfDay.DefaultSpeed
    -- on PA entry (fast mode resumes when you drive out).
    ForceNormalSpeed = false,
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

    -- How much the living sky (drift, jitter, dawn/dusk turbulence, the day
    -- mood and the morning profile) modulates a weather PRESET. 1.0 = full,
    -- 0 = flat preset values (the pre-2026-08-26 behaviour, when this
    -- modulation only ran with weather disabled and the sky sat still).
    -- The deviation is capped internally so a preset stays recognisable.
    PresetLivingScale = 1.0,

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
    LogActorDiscovery = true,
}

-- ============== ATMOSPHERE (god rays, aurora, cloud shadows) ==============
Config.Atmosphere = {
    Enabled = true,
    EnableCloudShadows = true,
    EnableGodRays = true,
    -- Auroras CANNOT render in TXR: the aurora texture was stripped from
    -- the game's cooked content. Leave false.
    EnableAurora = false,
    -- Second cloud layer = high cirrus above the cumulus. Very cinematic,
    -- but a significant GPU cost and a past crash suspect: enable
    -- deliberately for one test session before adopting.
    EnableSecondCloudLayer = false,

    -- City glow (Tokyo night ambiance): light pollution + night sky glow.
    -- Ramped on the SUN'S ELEVATION (season-proof; the old clock window is
    -- the fallback): rises from StartElev at the horizon to full at
    -- FullElev, then holds a plateau all night (real city glow does not
    -- dim toward midnight). Light pollution lights cloud bases from below
    -- (warm sodium amber by default); night sky glow keeps the night sky
    -- from going pitch black.
    EnableCityGlow = true,
    CityGlowStartElev = 0.0,   -- glow begins as the sun crosses the horizon
    CityGlowFullElev = -8.0,   -- full glow by the end of twilight
    -- KEEP LightPollutionMax AT OR BELOW 1.0: the sky material dims
    -- stars as pollution rises, and above 1.0 the star math inverts and
    -- stars render as dark dots. 0.5-0.7 = city feel WITH stars.
    -- NightSkyGlow is NOT in the star formula: raise NightSkyGlowMax
    -- freely for the night look, it cannot hurt stars.
    LightPollutionMax = 0.6,
    NightSkyGlowMax = 1.0,     -- glow is star-safe (not in the formula);
                               -- raise toward 1.5 freely for the night
                               -- feel. Alt+K still nudges it live.
    -- Colors are LinearColor {R,G,B,A}; defaults live in atmosphere.lua. Uncomment to override:
    -- LightPollutionColor = {R = 1.00, G = 0.55, B = 0.25, A = 1.0},
    -- NightSkyGlowColor   = {R = 0.45, G = 0.50, B = 0.65, A = 1.0},

    -- God rays = the sun's screen-space light-shaft bloom. The pairs
    -- interpolate on SUN ELEVATION (X = high sun, Y = low sun); stock is
    -- Max Brightness 0.35->0.25, Bloom Threshold 1.30->0.35, Bloom Scale
    -- 0.30->0.225. The THRESHOLD is the main tuning knob (which pixels
    -- seed a streak): step DOWN if rays never appear in clear weather,
    -- UP if they seed off buildings and bright sky. Bloom Scale is
    -- streak length. Always keep Y below X.
    SunShaftBrightnessMult = 1.0,          -- 1.0 = stock brightness pair
    SunShaftBloomThreshold = {X = 6.0, Y = 2.5},
    SunShaftBloomScale = {X = 0.15, Y = 0.10},   -- half stock = shorter streaks
    SunShaftTint = {R = 1.00, G = 0.92, B = 0.80, A = 1.0},

    -- WEATHER GATE: no god rays under a solid deck (UDS never works that
    -- out itself). Scales the rays by the mod's own cloud coverage
    -- (0-10): full at or below ClearCloud, none at or above
    -- OvercastCloud, smoothstep between. Foggy keeps its rays on
    -- purpose: shafts through haze are the real thing. false = rays in
    -- every weather.
    GodRayWeatherGate = true,
    GodRayGateClearCloud = 3.0,
    GodRayGateOvercastCloud = 5.5,

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

    -- Global sky/lighting grade. Saturation is absolute (stock 1.0).
    -- Contrast is a MULTIPLIER on its stock 0.1 (NOT 1.0-centered).
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

    -- Cloud render quality (ray-march sample scales; GPU cost rises with
    -- these; raise deliberately).
    ViewSampleQualityMult   = 1.5,
    ShadowSampleQualityMult = 1.5,

    -- Cloud movement mood
    CloudSpeedMult          = 0.60, -- slower, statelier drift
    CloudsMoveWithTimeOfDay = true, -- clouds stay coherent during Alt+T timelapses

    Debug = false,  -- extra per-property logging while tuning
}

-- ============== REAL SUN (EXPERIMENT) ==============
-- Real-world solar simulation. The module ALWAYS logs the sky's stock
-- Simulation values once per course (grep "RealSun", the Phase 0 probe).
-- With Enabled=true it also switches UDS to Simulate Real Sun/Moon for the
-- coordinates and pinned date below: astronomically correct
-- sunrise/sunset times and sun path.
Config.RealSun = {
    Enabled = true,       -- real-sun simulation (see date policy below)

    -- Leave true. false = UDS's classic sun path, which is DEAD in
    -- TXR's cook (2026-08-24 field test: no sun at all and the sky
    -- barely reacts to TOD; the game was authored night-only around
    -- the simulation). Leak-sun reproducibility is handled by Alt+J
    -- re-asserting the pinned date instead (keybinds leak toggle).
    SimulateSun = true,

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

-- ============== VIGNETTE (hide HUD vignette) ==============
-- Hide TXR's in-game HUD vignette (the darkened corner frame) for a cleaner,
-- photographic look. Pure UI-widget toggle on TXR's own HUD (no game files).
-- ON by default; set Enabled = false to keep the vanilla HUD frame.
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

    -- While a photo session is open: freeze time of day (UDS Animate Time
    -- of Day off; sun and shadows hold still through composing and long
    -- shutters). Restores on close; a manual Alt+T pause is respected
    -- either way.
    FreezeTime = true,

    -- Photomode exposure = MANUAL METERING (r.EyeAdaptation.MethodOverride
    -- 3 for the session, restored on close). Manual is the only mode where
    -- the aperture physically drives exposure (every emulation attempt
    -- failed: the applied f-stop is not readable anywhere). The manual
    -- level comes from the 3.4.0 sun-elevation curve below.
    ManualExposure = true,

    -- The 3.4.0 cvar curve, verbatim (elevation anchors in degrees; +90
    -- zenith, 0 horizon; piecewise-linear, clamped flat outside the ends):
    -- lens = r.EyeAdaptation.LensAttenuation (3D-scene EV trim) = the
    -- manual exposure level. The sky column is reference data only (not
    -- applied). Time is frozen in photomode, so each session gets one
    -- steady value.
    ManualCurve = {
        { elev =  30, sky = 0.100, lens =  1.0 },   -- day core
        { elev =  15, sky = 0.105, lens =  1.25 },
        { elev =   9, sky = 0.130, lens =  1.8 },   -- late golden hour
        { elev =   6, sky = 0.155, lens =  2.2 },
        { elev =   2, sky = 0.270, lens =  2.7 },   -- sun on the towers
        { elev =   0, sky = 0.420, lens =  3.8 },   -- sunset/sunrise moment
        { elev =  -3, sky = 0.860, lens =  5.5 },   -- civil twilight
        { elev =  -5, sky = 0.950, lens =  9.0 },
        { elev =  -7, sky = 1.000, lens = 17.0 },
        { elev = -10, sky = 1.050, lens = 27.0 },   -- night
    },

    -- Garage / PA-menu sessions (artificial light, no sun): the fixed
    -- 3.4.0 garage values (Sky = reference data, like the curve's sky
    -- column; only Lens applies).
    ManualGarage = { Sky = 1.005, Lens = 30.0 },

    -- Covered sessions: opening photomode under a road-data roof uses
    -- this fixed indoor lens instead of the sun curve (a lit bore does
    -- not follow the sun). Raise if bore shots read dark, lower if they
    -- blow out. nil = off (sun curve everywhere).
    CoveredLens = 14.0,

    -- Live exposure trim inside a photo session (Alt+E brighter,
    -- Alt+Shift+E darker): each press multiplies/divides the session's
    -- lens level by this step. Session-scoped (fresh session = neutral);
    -- every press logs the resulting level, so field use doubles as
    -- calibration telemetry for the curve/garage/covered values above.
    NudgeStep = 1.25,

    -- Alt+G "dark look" toggle inside a photo session: forces this lens
    -- regardless of the sun/garage/covered branch (crushed low-key;
    -- underglow and emissives pop). The nudge applies on top.
    DarkLook = { Lens = 30.0 },

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

    -- GARAGE SHOW-FLOOR LIGHTS: keep the displayed car's
    -- headlights ON for the whole garage visit (pairs with
    -- Config.LightCycle.GarageDark). State-checked re-assert every ~2.5s
    -- covers vehicle swaps; Alt+Q still toggles manually (auto-on re-arms
    -- within one window). Set false for the stock lights-off garage.
    GarageAlwaysOn = true,

    -- Forced-ON contexts for auto mode: real tunnel bores (road-data cover;
    -- lone overpasses deliberately do NOT flash the lights) and wet weather
    -- presets. When the context ends, the elevation logic takes back over.
    AutoOnInTunnel = true,
    AutoOnInRain = true,

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
-- Weather sound (rain/wind/thunder loops on cooked UDS sound assets).
Config.Audio = {
    Enabled = true,
    EnableRain = true, EnableWind = true, EnableThunder = true,
    RainVolume = 1.0, WindVolume = 0.8, ThunderVolume = 1.0,

    -- Thunder/Lightning level below which only DISTANT rumbles play (Rain
    -- runs 4 = distant only; Thunderstorm runs 10 = distant + close mix;
    -- Light Rain carries no thunder at all).
    CloseThunderMin = 7.0,
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

    -- DARK GARAGE look: every garage visit starts from the tuned
    -- low-key show floor (the Alt+G dark lens with an Alt+E trim
    -- baseline on top). Alt+G / Alt+E still adjust live during the
    -- visit. The installer asks; set false for the stock brightness.
    GarageDark = {
        Enabled = true,
        NudgeSteps = -33,
    },

    -- EXPOSURE POLICY: the stock pipeline runs untouched apart from the
    -- skylight-leak kill (Config.Tunnels.KillVolumeSkylightLeak) and the
    -- look overrides below. Shaping ships neutral; tune from Alt+D data
    -- (Logs/tuning_feedback.log).

    -- EV bias vs sun elevation (0 = stock). Auto-exposure meters shaded
    -- scenes to mid-grey (flat and washed); a negative bias sinks the
    -- frame toward a low-key photographic look. Ships about 2/3 stop
    -- under by day, easing off through dusk so nights don't
    -- double-darken. Tune with Alt+D / Alt+Shift+D.
    BiasCurve = {
        { elev =  30, bias = -0.6 },
        { elev =   8, bias = -0.6 },
        { elev =   3, bias = -0.6 },
        { elev =   0, bias = -0.5 },
        { elev =  -3, bias = -0.4 },
        { elev =  -6, bias = -0.3 },
        { elev = -10, bias = -0.3 },
    },

    LeakAlbedo = 0.07,  -- r.Lumen.SkylightLeaking.ReflectionAverageAlbedo

    -- Global r.SkylightIntensityMultiplier baseline (the Alt+C cvar).
    -- With the volume leak dead, Lumen bounce carries the ambient and
    -- the direct skylight runs near-floor. 1.0 = engine default.
    SkylightMultiplier = 0.10,

    -- UDS night floors. Mult scales the stock value; nil = leave stock.
    AbsentBrightnessMult = 1.0,    -- "Directional Lights Absent Brightness" (stock 1.5)
    NightCloudyBrightness = nil,   -- "Extra Night Brightness When Cloudy" (stock 0.0)
    OvercastBrightnessNight = nil, -- "Overcast Brightness (Night)" (stock 0.2)

    -- Stop the course skylights from lighting TRANSLUCENTS
    -- (bAffectTranslucentLighting=false, once per course). The translucency
    -- probe grid is too coarse to occlude sky through tunnel ceilings, so
    -- glass and taillight lenses catch a milky leaked-sky sheen under
    -- roofs. Glass is specular-dominated, so losing sky diffuse on it is
    -- near-invisible in the open; opaque surfaces keep their normal
    -- Lumen-occluded skylight either way. Zero GPU cost.
    KillSkylightTranslucentLighting = true,

    SunVectorSign = -1,  -- UDS sun vector = light direction; implementation constant
    SunriseTOD = 600, SunsetTOD = 1930,  -- pseudo-elevation fallback events

    -- Auto-exposure adaptation speeds (f-stops/second; stock 3/1, nil =
    -- stock). Asymmetric like eyes: adapting to BRIGHT (tunnel exits) is
    -- fast or the exit blows out; adapting to DARK stays slower and
    -- cinematic.
    AdaptSpeedUp = 6.0,
    AdaptSpeedDown = 2.0,

    -- POST-PROCESS LOOK OVERRIDES: FPostProcessSettings fields written once
    -- per course onto the course sky's main PP component (wins conflicts
    -- with the game's second PP comp). Numbers/bools direct; vectors as
    -- {X=,Y=,Z=,W=}. Verified by "PP one-shots readback" overrides_held.
    -- Remove a line = stock.
    PostProcess = {
        BloomIntensity = 0.2,                       -- game runs 0.75
        VignetteIntensity = 0.0,                    -- game runs 0.4
        LumenSceneDetail = 2.0,                     -- game runs 1
        LumenFinalGatherLightingUpdateSpeed = 2.0,
        LumenReflectionsScreenTraces = true,        -- keep true
        -- Shadow contrast: the game LIFTS unlit areas two ways, film toe
        -- 0.3 (UE default 0.55) and local-exposure shadow scale 0.7 (a
        -- regional lift that tracks auto-exposure). Neutralizing both
        -- darkens shadows without moving mid-tones.
        FilmToe = 0.55,
        LocalExposureShadowContrastScale = 1.0,     -- game runs 0.7
        LocalExposureHighlightContrastScale = 1.0,  -- game runs 0.8
        -- With the frame sitting darker (BiasCurve), a touch of
        -- saturation keeps color alive in the shade.
        ColorSaturation = { X = 1.05, Y = 1.05, Z = 1.05, W = 1.0 },
        -- Highlight rolloff: the game runs shoulder 0.7 (UE default 0.26),
        -- a hard bright ramp that clips skies to white. Softer shoulder =
        -- skies keep their tone like the reference shots. Raise toward 0.7
        -- if bright scenes start reading dull.
        FilmShoulder = 0.45,
        -- Slight near-black lift: gain on the shadows region
        -- keeps true black anchored while opening the darkest surfaces a
        -- touch. Same lever the game's own BP_HDR grading comp uses (it
        -- runs 1.5 for HDR displays). Step by 0.05 to taste.
        ColorGainShadows = { X = 1.05, Y = 1.05, Z = 1.05, W = 1.0 },
    },

    -- DISPLAY PROFILE. The game lifts shadows 1.5x and global 1.2x for HDR
    -- displays only (BP_HDR enables its grading component when the display
    -- outputs HDR). The look above (BiasCurve + PostProcess) is tuned on an
    -- HDR screen ON TOP of that lift; on SDR output it reads crushed and
    -- clipped. "auto" reads the live HDR state once per session and, on
    -- SDR, swaps in the SDR tables below. Force with "hdr" or "sdr".
    -- The active profile is logged ("Display profile") and stamped into
    -- every Alt+D feedback line.
    DisplayProfile = "auto",

    -- SDR replacements (used only when the SDR profile is active). Keys
    -- REPLACE their Config.LightCycle counterparts wholesale. First guess,
    -- to be iterated from SDR-tester Alt+D data: the shadow-deepening
    -- fields (FilmToe, LocalExposure scales, ColorGainShadows) are simply
    -- absent, stock game values apply; the bias curve runs half depth by
    -- day easing to neutral at night (the SDR tester's night feedback was
    -- too-dark at -0.3).
    SDR = {
        PostProcess = {
            BloomIntensity = 0.2,
            VignetteIntensity = 0.0,
            LumenSceneDetail = 2.0,
            LumenFinalGatherLightingUpdateSpeed = 2.0,
            -- Mirrored from the HDR table (see the note there: false was the
            -- wrong call, the artifact is in the surface cache).
            LumenReflectionsScreenTraces = true,
            ColorSaturation = { X = 1.05, Y = 1.05, Z = 1.05, W = 1.0 },
            FilmShoulder = 0.45,
        },
        BiasCurve = {
            { elev =  30, bias = -0.3 },
            { elev =   8, bias = -0.3 },
            { elev =   3, bias = -0.3 },
            { elev =   0, bias = -0.25 },
            { elev =  -3, bias = -0.15 },
            { elev =  -6, bias = 0.0 },
            { elev = -10, bias = 0.0 },
        },
    },

    -- Skylight tuning keybinds (Alt+Z/X/C, Alt+V, Alt+Shift+V)
    Tune = { Step = 0.05, RoughnessBaseline = 1.0 },
}

-- ============== TUNNELS (covered-road detection + GI fix) ==============
-- Covered = the car's road-data tunnel attribute (roof bit; exact
-- dev-authored boundaries, catches every real bore) OR a roof trace (lone
-- overpasses, which the road data does not mark). The covered flag drives
-- the fog damp, forced headlights in bores and photomode covered
-- metering. This block also clears the course volumes' authored
-- skylight-leak override (the boundary lighting flip). Rain occlusion
-- lives in Config.RainCollision since 3.8.0.
-- Leak-hunt mode (Alt+J toggle): clear weather + this pinned time of
-- day + a frozen clock, for checking sun leaks (0..2400 UDS clock;
-- 1820 = the campaign's calibrated leak sun ON THE PINNED DATE, which
-- the toggle re-asserts, so the value cannot drift stale).
Config.LeakTest = {
    Time = 1820,
}

-- Slab editor (systems/slab_editor.lua): the covered-road leak-fix
-- authoring tool. DEV BUILDS ONLY: release zips omit the module file,
-- so this block is inert in normal installs.
Config.SlabEditor = {
    -- Editor follows the photomode session (the free camera IS the
    -- authoring viewpoint): open on entry, close on exit (which saves
    -- the rows). Edge-triggered, so a manual Alt+Shift+J close inside
    -- a session sticks until the next session. NOTE: an open editor
    -- renders every slab, so turn this off for clean photos near a
    -- fixed leak site.
    OnPhotomode = true,
}

Config.GapWalls = {
    -- The shipping half: spawn the authored leak-fix slabs.
    Enabled = true,
    -- Debug: render the slabs (gray boxes) so placement can be checked
    -- by eye at any sun state. Tuner-selected slabs render regardless.
    Visible = false,
    -- THE SITE LIST LIVES IN data/gap_slabs.lua (the campaign will be
    -- large; config is user knobs and resets on update). Rows added
    -- here APPEND on top of the data file: an extension hook for
    -- experiments, ships empty.
    Slabs = {},
}

Config.Tunnels = {
    Enabled = true,

    -- Rain handling moved OUT of this module in 3.8.0: rain now collides
    -- with real geometry (Config.RainCollision), so the old particle-hiding
    -- kill and its overpass roof trace stay OFF. The machinery is kept as
    -- a fallback; setting TunnelRainKill true re-arms it (and restores the
    -- fast 0.25s poll cadence it needs for portal reactions).
    -- Covered-road detection itself is always LIVE via the road-data
    -- attribute (a cheap property read): it feeds the fog damp below,
    -- headlights AutoOnInTunnel and the photomode CoveredLens.
    TunnelRainKill = false,     -- hide precipitation on covered road
    TunnelRainLookahead = 1.2,  -- seconds of travel the roof trace probes ahead

    -- Fog on covered road: global fog is blind to ceilings, so foggy
    -- weather reads as a white wall inside bores. Scale Fog Density is
    -- multiplied by this while the road data says roofed. 0.0 = no fog at
    -- all under a roof; 1.0 = damp off.
    CoveredFogMult = 0.0,
    -- Seconds the damp HOLDS after the road data says open. Covered
    -- galleries have short open gaps (ginza/C1); without the hold the
    -- fog wall flashed back in every gap and lagged the re-entry. A real
    -- exit restores fog this many seconds past the portal. 0 = release
    -- on the next poll (the old instant behavior).
    CoveredFogHold = 5.0,

    -- Clear the authored LumenSkylightLeaking=1.0 override on all course
    -- volumes (it flooded covered sections with flat sky ambient at every
    -- volume edge). Armed line logs leakCleared=N.
    KillVolumeSkylightLeak = true,

    -- Roof trace for lone overpasses: downward Visibility leg for deck
    -- tops + upward leg for tunnel linings. Shorten the trace if rain dies
    -- under tall gantries.
    OverpassRainKill = false,    -- NO-RAIN BUILD: trace off (see note above)
    OverpassTraceLength = 5000,  -- units (50 m)

    -- Trace-cover release hold (uncovered polls) so girder gaps don't
    -- strobe rain; road-data cover releases on the first uncovered poll.
    RainClearPolls = 4,

    -- Poll cadence: fast while it can rain, relaxed when dry.
    PollSecondsRain = 0.25,
    PollSecondsDry = 1.0,
}

-- ============== RAIN COLLISION ==============
-- Native rain occlusion on the game's real geometry, pure Lua. The pass
-- flips ONLY the meshes that matter (tunnel linings + interior sets +
-- overpass decks, matched by asset path) rain-solid, as STEALTH BODIES:
-- Ignore-all responses + Block on the rain channel alone, so the AI and
-- every other game query never see them. Re-runs on a cadence while wet
-- so streamed-in cells get flipped too.
Config.RainCollision = {
    Enabled = true,
    -- Advanced: when false, the pass does enablement + responses only
    -- and relies on pak-baked collision flags.
    CtfWrite = false,
    PlayerCarProbe = false,  -- diagnostic; leave false
    -- Player-car rain collision: the tight body mesh blocks the rain
    -- channel only, so the car sheds rain with native splashes on the
    -- actual roofline (the game keeps seeing the car normally).
    PlayerCarBody = true,
    -- Buildings ship CastShadow=FALSE and the game RE-ASSERTS it at
    -- load, so pak-baking the flag does nothing (PROVEN by the clean
    -- 2026-08-25 A/B: pilot pak + every runtime path silenced = still
    -- shadowless). This runtime force-cast is THE building-shadow
    -- mechanism, permanently. COUPLINGS: the force block runs inside
    -- the FixShadowLeak pass (FixShadowLeak=false kills building
    -- shadows too), and the two-sided flip enables casting BY ITSELF,
    -- so a real building A/B must ALSO remove "BUIL" from
    -- ShadowFixPatterns below.
    ForceCastShadow = true,
    -- ECollisionChannel index for rain particle traces (3 = Visibility).
    Channel = 3,
    -- Lua patterns matched against mesh asset paths; matching meshes
    -- become rain-solid stealth bodies. HARD CONSTRAINT: mass collision
    -- enablement breaks the AI, so this list stays narrow. Extend ONLY
    -- from confirmed rain-through evidence (Alt+N mesh names), one
    -- family at a time. Naming: SMsr_c1_<sec><tnl|_br|_wc|_wl|_wr> =
    -- lining, bridge/deck, walls; interior sets live under Mesh_tn.
    TargetPatterns = {
        "tnl", "Mesh_tn", "_br%.", "_br$",
    },
    -- Patterns for the tunnel sun-leak SHADOW flip only (two-sided
    -- shadow casting, no collision), so breadth is safe here. Anchored
    -- with %. or $ so they cannot over-match. Families: _wc/_wl/_wr
    -- walls, _br decks, _s kerbs, _a aprons, w_ext exterior walls.
    ShadowFixPatterns = {
        "tnl", "Mesh_tn", "_br%.", "_br$",
        "_wc%.", "_wc$", "_wl%.", "_wl$", "_wr%.", "_wr$",
        "_kb%.", "_kb$",
        "_s%.", "_s$",
        "w_ext",
        -- Aprons, SMsr-prefixed so props (pylons) cannot match.
        "SMsr_[%w_]*_a%.", "SMsr_[%w_]*_a$",
        -- BUILDINGS: SMsb_*_BUIL_* ship CastShadow=false and the game
        -- re-asserts it at load (bake route dead, proven 2026-08-25);
        -- this entry + ForceCastShadow re-enable casting every world.
        "BUIL",
    },
    ReapplySeconds = 20.0,  -- streamed-cell re-pass cadence while wet
    SettleSeconds = 3.0,    -- course-arm settle before the first pass
    Debug = false,          -- log quiet periodic no-op passes too

    -- TUNNEL SUN-LEAK FIX: the game's tunnel and bridge decks cast
    -- shadows ONE-SIDED (a vanilla artifact), so low sun lands on the
    -- road inside covered sections. The pass flips matched meshes to
    -- two-sided shadow casting (chunked, no hitch). A lit kerb can
    -- remain where a section has no outer wall at all: that is missing
    -- geometry, not a flag. A/B by course reload. NOTE: this pass also
    -- hosts ForceCastShadow and the "BUIL" building-shadow entry above;
    -- false disables city building shadows as well.
    FixShadowLeak = true,
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
    WindDebris  = true,
    LightRays   = true,
    Moon        = true,
    Stars       = true,
    Rainbow     = true,   -- mesh-rendered rainbow (UDW drives visibility)
    CinematicSky= true,   -- daytime cloud/atmosphere grade (see Config.CinematicSky)
    LightCycle  = true,   -- sun-elevation exposure (see Config.LightCycle)
    Tunnels     = true,   -- covered-road rain kill (see Config.Tunnels)
    RainCollision = true, -- native rain occlusion (see Config.RainCollision)
    RealSun     = true,   -- real-sun probe + experiment (see Config.RealSun)
    Vignette    = true,   -- hide the HUD vignette (see Config.Vignette)
    PhotoMode   = true,   -- photo mode free-camera unlocks
    WetGrip     = true,   -- dynamic wet grip (see Config.WetGrip)
    Audio       = true,   -- weather sound (see Config.Audio)
    Tuning      = true,   -- alignment slider-range widening (see Config.Tuning)
}

-- ============== GT (game-thread marshal queue) ==============
Config.GT = {
    -- Single-flight game-thread marshal queue (core/gt.lua): all
    -- module marshals ride ONE drained ExecuteInGameThread action at
    -- a time, near-eliminating the shared-registry ref churn behind
    -- the UE4SS "Ref was not function" hook-death/abort family.
    -- false = raw per-call marshals (the old behavior), for comparison.
    SingleFlight = true,
}

-- ============== VERSION ==============
-- Bump String only; FullName derives from it.
Config.Version = {
    String = "4.0.0",
}
Config.Version.FullName = "TXR Weather Mod v" .. Config.Version.String

return Config
