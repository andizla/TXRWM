-- TXR Weather Mod v3.0
-- config.lua - all user-configurable settings
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
    FastSpeed = 640.0,      -- Alt+T fast-forward (~2.2 min full day; was 320)
    StartingTOD = nil,      -- 0-2400, or nil to not override
    DawnStart = 600, DawnEnd = 800,    -- 06:00 - 08:00
    DuskStart = 1800, DuskEnd = 2000,  -- 18:00 - 20:00

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

    -- Wet up fast, dry slowly - the road stays slick a while after the rain stops.
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
    LightPollutionMax = 1.0,   -- peak light-pollution intensity at deep night (tune to taste)
    NightSkyGlowMax = 0.5,     -- peak ambient night-sky glow
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
-- sun low enough. So it appears naturally as rain clears toward the sun - you won't
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
-- UDS's own Static Properties calls - the proven stars/nebula/moon pattern.
--
-- Knobs whose internal scale is undocumented are MULTIPLIERS on the value UDS
-- spawned with (the sky actor is recreated per course, so this never compounds);
-- 1.0 = leave stock. Saturation/Contrast are absolute 1.0-centered values.
-- Original -> tuned pairs are logged on every apply (grep "CinematicSky").
Config.CinematicSky = {
    Enabled = true,

    -- Global sky/lighting grade. Saturation is absolute (stock confirmed 1.0 in
    -- the apply log). Contrast is a MULTIPLIER: its stock is 0.1, NOT 1.0-centered
    -- (an absolute 1.06 here meant ~10x contrast - the 2026-07-03 blowout bug).
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

-- ============== VIGNETTE (hide HUD vignette, opt-in) ==============
-- Hide TXR's in-game HUD vignette (the darkened corner frame) for a cleaner,
-- photographic look. Pure UI-widget toggle on TXR's own HUD (no game files). Default
-- OFF - it removes a vanilla HUD element, so it's opt-in.
Config.Vignette = {
    Enabled = true,
    Hide = true,    -- true = hide the vignette (set false to force it visible)
}

-- ============== PHOTO MODE UNLOCKER ==============
-- Removes the restrictions on TXR's Advanced Photo Mode free camera (folded in from
-- the standalone PhotoModeUnlocked mod, which is kept on disk but disabled). Pure
-- runtime reflection - no game files touched. Only does anything while photo mode is
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
    MovementSpeedMult = 2.0,

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

-- ============== TUNING SLIDER RANGE (garage alignment tab) ==============
-- Widens the alignment sliders (camber/toe/ride height/wheel offset) to
-- RangeMultiplier x their stock range, and re-asserts saved out-of-range values
-- on car spawn (the game stores them but won't apply extremes on load itself).
-- Locked rows are skipped - this does NOT unlock parts/settings.
Config.Tuning = {
    Enabled = true,
    RangeMultiplier = 3.0,  -- 3x stock range each way; 1.0 = stock (inactive)
    SkipLockedRows = true,
    ReapplyOnLoad = true,   -- re-assert saved alignment on course load + garage display
    Debug = false,          -- log alignment rows, slider probes + widened ranges
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

    -- Skylight tuning keybinds (Alt+Z/X/C, see Config.Keybinds)
    Tune = {
        Step = 0.05,               -- nudge size per keypress
        CvarRough = "r.Lumen.SkylightLeaking.Roughness",
        RoughnessBaseline = 1.0,   -- engine.ini boot value; keep in sync.
                                   -- 1.0 = max (roughness is 0-1, engine clamps;
                                   -- 10 looks identical). Baselined 2026-07-03.
    },

    -- Per-weather lens multiplier. The slot curve is tuned for clear skies;
    -- overcast/rain scenes are much darker at the same TOD (2026-07-04 feedback:
    -- Overcast was too dark even at the lens=30 night cap). Applied on top of
    -- the interpolated lens, smoothed so preset changes don't pop the exposure.
    -- Presets not listed = 1.0.
    -- 2026-07-04 recalibration: Overcast dusk was STILL too dark at 1.45
    -- (20 presses, applied lens 2.0-29.5, mult confirmed active in log).
    -- LENS compensation is now the SECONDARY lever. The 2026-07-04 full-cycle
    -- Alt+D runs proved lens raises barely read on screen (overcast night at
    -- lens 34 -> 78 = "too dark, and it stayed dark") - lens mostly shapes
    -- contrast/adaptation, sky is the brightness. Kept at the earlier baseline;
    -- the real per-weather brightening is WeatherSkyMult below.
    WeatherLensMult = {
        Clear_Skies       = 1.00,
        Partly_Cloudy     = 1.15,
        Cloudy            = 1.45,
        Overcast          = 2.00,
        Foggy             = 1.60,
        Rain_Light        = 1.70,
        Rain              = 1.90,
        Rain_Thunderstorm = 2.20,
        Snow_Light        = 1.45,
        Snow              = 1.70,
        Snow_Blizzard     = 2.20,
        Sand_Dust_Calm    = 1.30,
        Sand_Dust_Storm   = 1.80,
    },

    -- Per-weather SKY multiplier (r.SkylightIntensityMultiplier) - the effective
    -- brightness lever, added 2026-07-04 after the lens-only compensation failed
    -- to register. Skylight is exactly the light heavy cloud takes away, so this
    -- is also physically the right knob. Smoothed like the lens mult. Values are
    -- a conservative first pass (sky is potent - night overcast runs
    -- 1.005 * 1.5 = ~1.5): flag too-dark/too-bright with Alt+D / Alt+Shift+D and
    -- read weather_sky_mult in the ExposureTune log lines.
    WeatherSkyMult = {
        Clear_Skies       = 1.00,
        Partly_Cloudy     = 1.10,
        Cloudy            = 1.25,
        Overcast          = 1.50,
        Foggy             = 1.40,
        Rain_Light        = 1.35,
        Rain              = 1.50,
        Rain_Thunderstorm = 1.70,
        Snow_Light        = 1.25,
        Snow              = 1.40,
        Snow_Blizzard     = 1.70,
        Sand_Dust_Calm    = 1.20,
        Sand_Dust_Storm   = 1.50,
    },
    WeatherLensSmoothSeconds = 20.0,

    -- [1..144] = { sky, leak, lens }. Index 1 = 00:00-00:10. Curves interpolated
    Slots = {
        -- NIGHT CORE
        [  1] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 00:00-00:10
        [  2] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 00:10-00:20
        [  3] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 00:20-00:30
        [  4] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 00:30-00:40
        [  5] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 00:40-00:50
        [  6] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 00:50-01:00
        [  7] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 01:00-01:10
        [  8] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 01:10-01:20
        [  9] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 01:20-01:30
        [ 10] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 01:30-01:40
        [ 11] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 01:40-01:50
        [ 12] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 01:50-02:00
        [ 13] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 02:00-02:10
        [ 14] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 02:10-02:20
        [ 15] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 02:20-02:30
        [ 16] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 02:30-02:40
        [ 17] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 02:40-02:50
        [ 18] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 02:50-03:00
        [ 19] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 03:00-03:10
        [ 20] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 03:10-03:20
        [ 21] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 03:20-03:30
        [ 22] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 03:30-03:40
        [ 23] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 03:40-03:50
        [ 24] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 03:50-04:00
        [ 25] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 04:00-04:10
        [ 26] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 04:10-04:20
        [ 27] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 04:20-04:30
        [ 28] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 04:30-04:40
        [ 29] = { sky = 0.9700, leak = 0.070, lens = 28.00 }, -- 04:40-04:50
        [ 30] = { sky = 0.9350, leak = 0.070, lens = 26.00 }, -- 04:50-05:00
        -- DAWN TRANSITION (night -> day)
        [ 31] = { sky = 0.9000, leak = 0.070, lens = 24.00 }, -- 05:00-05:10
        [ 32] = { sky = 0.8000, leak = 0.070, lens = 20.67 }, -- 05:10-05:20
        [ 33] = { sky = 0.7000, leak = 0.070, lens = 17.33 }, -- 05:20-05:30
        [ 34] = { sky = 0.6000, leak = 0.070, lens = 14.00 }, -- 05:30-05:40
        [ 35] = { sky = 0.4833, leak = 0.070, lens = 11.00 }, -- 05:40-05:50
        [ 36] = { sky = 0.3667, leak = 0.070, lens =  8.00 }, -- 05:50-06:00
        [ 37] = { sky = 0.2500, leak = 0.070, lens =  6.40 }, -- 06:00-06:10
        [ 38] = { sky = 0.2067, leak = 0.070, lens =  5.40 }, -- 06:10-06:20
        [ 39] = { sky = 0.1633, leak = 0.070, lens =  4.60 }, -- 06:20-06:30
        [ 40] = { sky = 0.1200, leak = 0.070, lens =  3.60 }, -- 06:30-06:40
        [ 41] = { sky = 0.1067, leak = 0.070, lens =  3.10 }, -- 06:40-06:50
        [ 42] = { sky = 0.1000, leak = 0.070, lens =  2.60 }, -- 06:50-07:00
        [ 43] = { sky = 0.1000, leak = 0.070, lens =  2.20 }, -- 07:00-07:10
        [ 44] = { sky = 0.1000, leak = 0.070, lens =  1.80 }, -- 07:10-07:20
        [ 45] = { sky = 0.1000, leak = 0.070, lens =  1.40 }, -- 07:20-07:30
        [ 46] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 07:30-07:40
        [ 47] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 07:40-07:50
        [ 48] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 07:50-08:00
        [ 49] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 08:00-08:10
        [ 50] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 08:10-08:20
        [ 51] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 08:20-08:30
        -- DAY
        [ 52] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 08:30-08:40
        [ 53] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 08:40-08:50
        [ 54] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 08:50-09:00
        [ 55] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 09:00-09:10
        [ 56] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 09:10-09:20
        [ 57] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 09:20-09:30
        [ 58] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 09:30-09:40
        [ 59] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 09:40-09:50
        [ 60] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 09:50-10:00
        [ 61] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 10:00-10:10
        [ 62] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 10:10-10:20
        [ 63] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 10:20-10:30
        [ 64] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 10:30-10:40
        [ 65] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 10:40-10:50
        [ 66] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 10:50-11:00
        [ 67] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 11:00-11:10
        [ 68] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 11:10-11:20
        [ 69] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 11:20-11:30
        [ 70] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 11:30-11:40
        [ 71] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 11:40-11:50
        [ 72] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 11:50-12:00
        [ 73] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 12:00-12:10
        [ 74] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 12:10-12:20
        [ 75] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 12:20-12:30
        [ 76] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 12:30-12:40
        [ 77] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 12:40-12:50
        [ 78] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 12:50-13:00
        [ 79] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 13:00-13:10
        [ 80] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 13:10-13:20
        [ 81] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 13:20-13:30
        [ 82] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 13:30-13:40
        [ 83] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 13:40-13:50
        [ 84] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 13:50-14:00
        [ 85] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 14:00-14:10
        [ 86] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 14:10-14:20
        [ 87] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 14:20-14:30
        [ 88] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 14:30-14:40
        [ 89] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 14:40-14:50
        [ 90] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 14:50-15:00
        [ 91] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 15:00-15:10
        [ 92] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 15:10-15:20
        [ 93] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 15:20-15:30
        [ 94] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 15:30-15:40
        [ 95] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 15:40-15:50
        [ 96] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 15:50-16:00
        [ 97] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 16:00-16:10
        [ 98] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 16:10-16:20
        [ 99] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 16:20-16:30
        [100] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 16:30-16:40
        [101] = { sky = 0.1000, leak = 0.070, lens =  1.00 }, -- 16:40-16:50
        [102] = { sky = 0.1000, leak = 0.070, lens =  1.15 }, -- 16:50-17:00
        [103] = { sky = 0.1000, leak = 0.070, lens =  1.40 }, -- 17:00-17:10
        [104] = { sky = 0.1000, leak = 0.070, lens =  1.80 }, -- 17:10-17:20
        [105] = { sky = 0.1000, leak = 0.070, lens =  2.40 }, -- 17:20-17:30
        -- DUSK -> EVENING (brightened 2026-07-03 from Alt+D nudges: ramp now
        -- starts 16:50 and runs ~2x through 19:10; was flat 1.00 until 17:40)
        [106] = { sky = 0.1000, leak = 0.070, lens =  3.20 }, -- 17:30-17:40
        [107] = { sky = 0.1000, leak = 0.070, lens =  4.20 }, -- 17:40-17:50
        [108] = { sky = 0.1000, leak = 0.070, lens =  5.20 }, -- 17:50-18:00
        [109] = { sky = 0.1000, leak = 0.070, lens =  6.20 }, -- 18:00-18:10
        [110] = { sky = 0.1333, leak = 0.070, lens =  7.50 }, -- 18:10-18:20
        [111] = { sky = 0.1767, leak = 0.070, lens =  9.00 }, -- 18:20-18:30
        [112] = { sky = 0.2200, leak = 0.070, lens = 10.80 }, -- 18:30-18:40
        [113] = { sky = 0.2967, leak = 0.070, lens = 13.00 }, -- 18:40-18:50
        [114] = { sky = 0.3733, leak = 0.070, lens = 15.50 }, -- 18:50-19:00
        [115] = { sky = 0.4500, leak = 0.070, lens = 18.00 }, -- 19:00-19:10
        [116] = { sky = 0.5267, leak = 0.070, lens = 20.00 }, -- 19:10-19:20
        [117] = { sky = 0.6033, leak = 0.070, lens = 20.50 }, -- 19:20-19:30
        [118] = { sky = 0.6800, leak = 0.070, lens = 21.00 }, -- 19:30-19:40
        [119] = { sky = 0.7433, leak = 0.070, lens = 21.67 }, -- 19:40-19:50
        [120] = { sky = 0.8067, leak = 0.070, lens = 23.33 }, -- 19:50-20:00
        [121] = { sky = 0.8700, leak = 0.070, lens = 25.00 }, -- 20:00-20:10
        [122] = { sky = 0.9033, leak = 0.070, lens = 26.00 }, -- 20:10-20:20
        [123] = { sky = 0.9367, leak = 0.070, lens = 27.00 }, -- 20:20-20:30
        [124] = { sky = 0.9700, leak = 0.070, lens = 28.00 }, -- 20:30-20:40
        [125] = { sky = 0.9807, leak = 0.070, lens = 28.50 }, -- 20:40-20:50
        [126] = { sky = 0.9913, leak = 0.070, lens = 29.00 }, -- 20:50-21:00
        [127] = { sky = 1.0020, leak = 0.070, lens = 29.50 }, -- 21:00-21:10
        [128] = { sky = 1.0030, leak = 0.070, lens = 29.67 }, -- 21:10-21:20
        [129] = { sky = 1.0040, leak = 0.070, lens = 29.83 }, -- 21:20-21:30
        -- NIGHT CORE
        [130] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 21:30-21:40
        [131] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 21:40-21:50
        [132] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 21:50-22:00
        [133] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 22:00-22:10
        [134] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 22:10-22:20
        [135] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 22:20-22:30
        [136] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 22:30-22:40
        [137] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 22:40-22:50
        [138] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 22:50-23:00
        [139] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 23:00-23:10
        [140] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 23:10-23:20
        [141] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 23:20-23:30
        [142] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 23:30-23:40
        [143] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 23:40-23:50
        [144] = { sky = 1.0050, leak = 0.070, lens = 30.00 }, -- 23:50-24:00
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
    Stars       = true,
    Rainbow     = true,   -- mesh-rendered rainbow (UDW drives visibility)
    SpaceLayer  = true,   -- night-sky nebula
    CinematicSky= true,   -- daytime cloud/atmosphere grade (see Config.CinematicSky)
    Vignette    = true,   -- hide the HUD vignette (see Config.Vignette)
    PhotoMode   = true,   -- photo mode free-camera unlocks
    WetGrip     = true,   -- dynamic wet grip
    Tuning      = true,   -- alignment slider-range widening (see Config.Tuning)
}

-- ============== VERSION ==============
Config.Version = {
    Major = 3, Minor = 3, Patch = 0,
    String = "3.3.0",
    Name = "TXR Weather Mod",
    FullName = "TXR Weather Mod v3.3.0",
}

return Config
