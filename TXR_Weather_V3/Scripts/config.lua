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
    -- RAIN RETURNS (3.8.0): the rain variants are BACK (this cycle, the
    -- scheduler pool and presets.lua's DEFAULT_CYCLE_ORDER, all in sync:
    -- the lists must always move together) now that rain occludes natively
    -- on real geometry (Config.RainCollision). Snow/dust were never in
    -- the cycle.
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
    -- Rebalanced 3.8.0 (field: clear skies held too long): clear tiers
    -- down, cloudy/wet tiers up, so the sky changes character more often.
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
    Enabled = true,    -- RAIN RETURNS (3.8.0): re-enabled with the native
                       -- occlusion work (ModuleToggles.WetGrip also true)

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

    -- RESTORED true 2026-07-24: the real-star 360 map with real
    -- movement and the Milky Way band. Safe again because the actual
    -- black-stars root cause was LightPollutionMax > 1.0 (see
    -- Atmosphere); with pollution in range, UDS's own star pushes are
    -- CORRECT and the whole override war is retired.
    SimulateRealStars = true,

    -- Tiling-mode texture pan; irrelevant while SimulateRealStars=true.
    TilingStarSpeed = 0.0,

    -- OFF (2026-07-18 field model, built from three observations:
    -- intensity up = DARKER specks; nebula off = specks remain; glow up =
    -- brighter background): stars composite as opacity-weighted holes in
    -- the glow layer. Intensity = hole opacity, Stars Color = the fill.
    -- Scaling OPACITY with glow while the fill is dimmer than the sky
    -- makes the black dots MORE solid, so this boost was amplifying the
    -- problem. Re-raise only after ColorBoost wins the luminance race.
    CityGlowBoost = 1.0,

    -- Stars Color multiplier (stock color x this, captured fresh per
    -- course so it never compounds). Field verdict 2026-07-18: NOT a
    -- luminance lever; the rendered star clamps below a lifted sky, and
    -- this multiplier only promotes fainter map stars past visibility =
    -- a star DENSITY knob (more dots, same brightness). 1.0 = the stock
    -- field. Raise deliberately for a denser sky once the glow crossover
    -- is settled (Config.Atmosphere.NightSkyGlowMax).
    ColorBoost = 1.0,

    -- ROOT CAUSE FIX, PARKED (2026-07-18, from the Sky MID dump): UDS's
    -- RETIRED 2026-07-24 (nil = the entire MID-override machinery off:
    -- belt, stomp watch, burst, BP-input writes). The black dots were
    -- never a material/MID problem: Atmosphere.LightPollutionMax 1.5
    -- made the star formula's (1 - pollution) term negative. With
    -- pollution <= 1.0 UDS pushes correct star colors itself, moving
    -- stars included. Star brightness knobs are now the NATIVE ones:
    -- Stars.Intensity above, and pollution's distance from 1.0.
    -- (The machinery stays in stars.lua, config-keyed, for emergencies;
    -- the FName("Stars Color") lesson lives in the footguns memory.)
    MIDStarColor = nil,

    -- Diagnostic: once per boot, dump the Sky Sphere MID's scalar +
    -- vector parameters (grep "Sky MID"). BAKED OFF 2026-07-24: the star
    -- saga is verified closed (moving bright stars via the pollution
    -- fix); re-enable only for future MID forensics.
    DumpSkyMIDParams = false,
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
    -- 0-1: rays through natural cloud gaps (0 = painted gaps only, which
    -- in TXR means none: we never paint coverage). This is OUR setting,
    -- not a UDS default, and it is the DENSITY lever: at 1.0 UDS casts a
    -- ray card through every gap it can find, which is what puts one on
    -- top of the car. Backed off 1.0 -> 0.6 (2026-07-29, "still annoying"
    -- after the distance pass); lower further if the field is still busy,
    -- raise toward 1.0 if the rays get too rare to notice.
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
    -- Distance/geometry shaping. Rays are giant additive cards, so one
    -- spawned near the camera reads as a glow slab in your face rather
    -- than a distant shaft ("they fire way too close", field 2026-07-29).
    -- STOCK VALUES (captured from the readback line): maxDistKm 12,
    -- depthFade 100000, spacing 50000, rayLen 1.0, maxRayLen 0.0.
    -- DepthFadeDistance is THE near-geometry knob: cards fade where the
    -- scene depth behind them is close, so RAISING it pushes rays off
    -- nearby structures and out toward the distance where they belong.
    -- PointSpacing thins the field (fewer cards = less chance one lands
    -- on top of you, and cheaper: IndividualClouds=1.0 spawns many).
    -- MaxDistanceKm is the OUTER bound: lowering it pulls rays CLOSER,
    -- which is the wrong direction here. Leave at stock.
    MaxDistanceKm     = nil,
    DepthFadeDistance = 400000,  -- 1 km stock -> 4 km fade band (2.5 km was still too close)
    PointSpacing      = 110000,  -- 500 m stock -> 1.1 km between ray points (sparser field)
    RayLength         = nil,
    MaxRayLength      = nil,
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
    -- NO-RAIN BUILD: the wetness debug keys are retired (module off).
    -- DebugForceWetness= { Key = "W", Modifiers = {"Alt"} },
    -- DebugForceDry    = { Key = "W", Modifiers = {"Alt", "Shift"} },
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
    -- DEV: UDS exposure-bias liveness test (+2 EV on all five knobs, press
    -- again to restore). Unbound for release; uncomment to re-enable.
    -- ExposureDebugOverlay = { Key = "H", Modifiers = {"Alt"} },

    -- Rain-spot datapoint key, REINSTATED with the rain return: press at
    -- any wrong-rain spot (raining under cover, dry in the open); the
    -- logged mesh names feed Config.RainCollision.TargetPatterns.
    NoteRainSpot = { Key = "N", Modifiers = {"Alt"} },
    -- Dormant diagnostics, uncomment to re-arm. Alt+J toggles the (now
    -- fallback-only) covered-road precipitation hide; Alt+O logs the live
    -- UDW particle-collision properties plus an upward channel trace sweep
    -- from the car, the tool that mapped the occlusion problem.
    -- PrecipSuppressTest = { Key = "J", Modifiers = {"Alt"} },
    -- OcclusionProbe = { Key = "O", Modifiers = {"Alt"} },
    -- (The Alt+I sun-leak toggle is DELETED as of 2026-08-04, handler and
    -- module function both: its revert keyed on an unstable component key
    -- and falsely exonerated the fix in an A/B. A/B by course reload.)

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
    -- THE THREE-WEEK BLACK-STARS ROOT CAUSE (2026-07-24, decompiled from
    -- the UDS blueprint bytecode): the sky material's star color =
    -- StarsColor x StarsIntensity x (1 - Overcast) x 0.62 x
    -- (1 - LIGHT POLLUTION INTENSITY). Pollution is a 0..1 design range;
    -- our 1.5 (the 07-07 night-floor lift, the exact era stars broke)
    -- made the last term -0.5 = NEGATIVE star intensity = the black dots
    -- (3.0 x 0.62 x -0.5 = -0.93, the measured value to the decimal).
    -- KEEP THIS <= 1.0 FOREVER; stars fade toward zero as it approaches
    -- 1.0 (realistic: city glare hides stars), so 0.5-0.7 = city feel
    -- WITH stars. NightSkyGlow does NOT appear in the star formula: lift
    -- the glow look with NightSkyGlowMax instead, it cannot hurt stars.
    LightPollutionMax = 0.6,   -- was 1.5 = the star killer; see above
    NightSkyGlowMax = 1.0,     -- glow is star-safe (not in the formula);
                               -- raise toward 1.5 freely for the night
                               -- feel. Alt+K still nudges it live.
    -- Colors are LinearColor {R,G,B,A}; defaults live in atmosphere.lua. Uncomment to override:
    -- LightPollutionColor = {R = 1.00, G = 0.55, B = 0.25, A = 1.0},
    -- NightSkyGlowColor   = {R = 0.45, G = 0.50, B = 0.65, A = 1.0},

    -- God rays = the sun's screen-space light-shaft bloom (EnableGodRays above).
    --
    -- WHY THREE ROUNDS OF TUNING DID NOTHING (settled 2026-07-30): rounds 1
    -- and 2 tuned Config.LightRays, which drives UDS's NIAGARA volumetric
    -- cloud rays. Those never construct in TXR: the sole constructor is gated
    -- on "Cloud Coverage Target in Use" which the game never satisfies, the
    -- construction script does not re-run in a cook, and maxRayLen read 0.0
    -- in 106 of 106 samples. That block is dormant. THESE keys drive the
    -- system actually on screen.
    --
    -- THE PAIRS INTERPOLATE ON SUN ELEVATION (X = high sun, Y = low sun),
    -- proven from bytecode: Apply Light Shaft Settings takes
    -- GetForwardVector(Sun World Rotation) as its only selector. Cloud cover is
    -- NOT an input, which is why heavy overcast still gets full shafts. An
    -- earlier note here claiming a (clear, overcast) pair was simply wrong.
    -- Stock:
    --   Max Brightness   0.35 -> 0.25
    --   Bloom Threshold  1.30 -> 0.35
    --   Bloom Scale      0.30 -> 0.225
    -- WHICH KNOB DOES WHAT. UE light shaft bloom is a screen-space RADIAL BLUR
    -- from the sun's screen position, with no distance parameter of any kind.
    -- Max Brightness caps intensity. Bloom Threshold gates which pixels seed a
    -- streak, and is useless as a limiter here because an overcast HDR sky sits
    -- far above any sane threshold (raising it 0.35 -> 0.7 changed nothing on
    -- screen). BLOOM SCALE is how far the streaks extend, i.e. the actual
    -- "rays fire too close to the car" knob, and rounds 1 to 3 never wrote it.
    --
    -- Written ABSOLUTE, never scaled off the live value. Atmosphere.Setup()
    -- runs per course load, so a read-modify-write only stays correct while
    -- the UDS actor happens to be fresh; light_cycle.lua:596 documents that
    -- same hazard. Absolute writes make Setup idempotent.
    -- WHY IT "FIRES OFF BUILDINGS" (working theory). The threshold only bites
    -- ABOVE the sky's luminance, and {1.3, 0.7} sat UNDER an overcast HDR sky at
    -- every elevation, so effectively every bright pixel qualified: sky showing
    -- between and behind building silhouettes seeded streaks indistinguishable
    -- from real sun rays. That is also why 0.35 -> 0.7 did nothing on screen.
    -- The threshold is not useless as a limiter, it was simply never raised past
    -- the thing it had to gate.
    -- THE UNITS ARE INFERRED, NOT MEASURED. There is no framebuffer readback in
    -- this mod. Stock is {1.3, 0.35}; stock LOWERS it at low sun because
    -- extinction dims the disc at sunrise and sunset, so always keep Y below X.
    SunShaftBrightnessMult = 1.0,          -- 1.0 = stock 0.35/0.25 exactly
    -- THE ONE KNOB TO TUNE AFTER THIS, and the only one. If god rays never
    -- appear in CLEAR weather with the sun in frame, step DOWN: 6/2.5 then
    -- 4/1.6 then 2/0.8. If shafts still seed off buildings and bright sky in
    -- clear weather, step UP: 12/5 then 25/10. Do NOT reach for Max Brightness
    -- or Bloom Scale first, neither can make the effect appear or stop it
    -- seeding.
    -- Diagnostic, not a setting: {X = 200, Y = 200} once. Shafts vanishing at
    -- 200 proves the gate works in these units and the answer is a bisection.
    -- Shafts SURVIVING at 200 proves the comparison is against raw scene
    -- luminance, no reachable value can gate the sky, and the threshold route is
    -- dead: what is left is the weather gate below plus Bloom Scale.
    SunShaftBloomThreshold = {X = 6.0, Y = 2.5},
    -- Extent. Half stock (0.30/0.225), unchanged: this HAS run in game and is
    -- deliberately held while the threshold is the single moving variable.
    -- Go to {X = 0.08, Y = 0.05} for shorter streaks, back toward stock for
    -- longer ones, but only after the threshold is settled.
    SunShaftBloomScale = {X = 0.15, Y = 0.10},
    SunShaftTint = {R = 1.00, G = 0.92, B = 0.80, A = 1.0},

    -- WEATHER GATE. There are no god rays under a solid deck: no direct sun.
    -- UDS never works that out, because Apply Light Shaft Settings takes the sun
    -- forward vector and nothing else, so heavy overcast gets full-strength
    -- streaks fanning across the road. This gates them on the mod's OWN cloud
    -- coverage (clouds_fog, 0-10, already smoothed over PresetTransitionSeconds):
    -- full shafts at or below ClearCloud, none at or above OvercastCloud,
    -- smoothstep between. Both Max Brightness and Bloom Scale are scaled by the
    -- same factor, so rays dim AND retract as cover thickens.
    --   Clear_Skies 0.5, Partly_Cloudy 2.0, Foggy 3.0            -> full
    --   Cloudy 4.0, Snow_Light 4.0, Sand_Dust_Storm 4.0          -> 0.65
    --   Rain_Light 5.0                                           -> 0.10
    --   Overcast 6.0, Rain 6.0, Overcast_Heavy 7.5,
    --   Rain_Thunderstorm 8.0                                    -> off
    -- Foggy keeps its rays on purpose: shafts through haze are the real thing.
    -- Rays only on genuinely clear skies? Drop the pair to 1.5 / 3.5.
    -- Rays back everywhere? GodRayWeatherGate = false.
    -- The gate is identity below ClearCloud, so it does NOT stack with the
    -- threshold in clear weather: a clear-weather boot reads the threshold
    -- alone, an overcast boot reads the gate alone.
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

-- ============== SPACE LAYER (nebula in the night sky) ==============
-- UDS Space Layer: a faint Nebula band rendered INTO the sky material (like the
-- stars/moon), plus a space-glow control. UDS fades it by day/night itself, so it
-- only shows at night. It composites via DBuffer decals (the installer's Engine.ini
-- profile sets r.DBuffer=1; the module also requests it at runtime as a fallback).
-- Stylistic (real Tokyo skies are light-polluted); keep the intensity modest or set
-- Enabled=false if you prefer a plain night sky.
Config.SpaceLayer = {
    -- TEMP A/B (2026-07-18): OFF to settle whether the dark sky speckles
    -- are the NEBULA (DBuffer decal compositing, the broken-materials
    -- family) or the star layer. Next night boot: speckles gone = nebula
    -- guilty (keep off or fix its compositing); speckles remain = truly
    -- stars, then Alt+K (the untested Stars Color lever) is the tool.
    Enabled = false,
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
-- coordinates and pinned date below: astronomically correct sunrise/sunset
-- times and sun path. NOTE: the exposure slot curve is tuned for the stock
-- sun path; expect dawn/dusk timing shifts on dates far from late July
-- (Tokyo sunset ~18:50, the closest match to the current curve).
Config.RealSun = {
    Enabled = true,       -- real-sun simulation (see date policy below)

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
    -- manual exposure level. The sky column is 3.4.0 REFERENCE DATA only
    -- (not applied; photomode never scales the skylight). Field-tuned
    -- across the 07-07/07-08 sweeps for manual metering; time is frozen
    -- in photomode so each session gets one steady value.
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
        { elev = -10, sky = 1.050, lens = 27.0 },   -- night (14/22 -> 17/27
                                    -- 2026-07-17: a max-aperture night shot
                                    -- still read dark; day anchors untouched)
    },

    -- Garage / PA-menu sessions (artificial light, no sun): the fixed
    -- 3.4.0 garage values (Sky = reference data, like the curve's sky
    -- column; only Lens applies).
    ManualGarage = { Sky = 1.005, Lens = 30.0 },

    -- Covered sessions: opening photomode under a road-data roof uses
    -- this fixed lens instead of the sun curve. A lit bore's brightness
    -- does not follow the sun (the day anchor lens 1.0 read near-black
    -- in tunnels); like the garage it gets an indoor level. Checked once
    -- at session open. FIRST GUESS between the night anchor (22) and
    -- day; raise if bore shots still read dark, lower toward the curve
    -- if they blow out. nil = off (sun curve everywhere).
    CoveredLens = 14.0,

    -- Live exposure trim inside a photo session (Alt+E brighter,
    -- Alt+Shift+E darker): each press multiplies/divides the session's
    -- lens level by this step. Session-scoped (fresh session = neutral);
    -- every press logs the resulting level, so field use doubles as
    -- calibration telemetry for the curve/garage/covered values above.
    NudgeStep = 1.25,

    -- Alt+G "dark look" toggle inside a photo session: forces this lens
    -- regardless of the sun/garage/covered branch. Born from the 07-22
    -- tester's accidental garage render (crushed low-key, underglow and
    -- emissives pop); the nudge still applies on top. Session-scoped.
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

    -- GARAGE SHOW-FLOOR LIGHTS (2026-08-11): keep the displayed car's
    -- headlights ON for the whole garage visit (pairs with
    -- Config.LightCycle.GarageDark). State-checked re-assert every ~2.5s
    -- covers vehicle swaps; Alt+Q still toggles manually (auto-on re-arms
    -- within one window). Set false for the stock lights-off garage.
    GarageAlwaysOn = true,

    -- Forced-ON contexts for auto mode: real tunnel bores (road-data cover;
    -- lone overpasses deliberately do NOT flash the lights) and wet weather
    -- presets. When the context ends, the elevation logic takes back over.
    AutoOnInTunnel = true,
    AutoOnInRain = true,   -- RAIN RETURNS (3.8.0)

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
-- Removed in the no-rain build 2026-07-17, RESTORED for 3.8.0 with the
-- rain return.
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

    -- DARK GARAGE look (2026-08-11): every garage visit starts from the
    -- tuned low-key show floor instead of the neutral exposure: the Alt+G
    -- dark lens with an Alt+E trim baseline on top (lens 30 * 1.25^-33
    -- ~= 0.019, the 2026-08-11 00:31 field tuning). HDR-calibrated; SDR
    -- feedback pending. Alt+G / Alt+E still adjust live during the
    -- visit. The installer exposes Enabled as a yes/no; set false for
    -- the stock garage brightness.
    GarageDark = {
        Enabled = true,
        NudgeSteps = -33,
    },

    -- EXPOSURE POLICY: the stock pipeline runs untouched apart from the
    -- skylight-leak kill (Config.Tunnels.KillVolumeSkylightLeak) and the
    -- look overrides below. Shaping ships neutral; tune from Alt+D data
    -- (Logs/tuning_feedback.log).

    -- EV bias vs sun elevation (0 = stock). Anchor shape: day / golden
    -- hour / sunset / blue hour / civil twilight / night.
    -- First shaped pass (2026-07-13, from photographic reference targets):
    -- auto-exposure meters shaded scenes to mid-grey = flat and washed; a
    -- negative bias sinks the whole frame toward the low-key photographic
    -- look (deep blacks, controlled sky). Flat 2/3 stop under during the
    -- day, easing off through dusk so nights don't double-darken. Tune
    -- with Alt+D / Alt+Shift+D in 0.2 steps.
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
    -- 0.10 (2026-07-15, field-verified): with the volume leak dead and the
    -- skylight cut off translucents, Lumen bounce light carries the ambient
    -- and the direct skylight runs near-floor. 1.0 = engine default.
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
    -- stock). Asymmetric like real eyes: adapting to BRIGHT (SpeedUp, e.g.
    -- exiting a tunnel) is fast or the exit blows out white; adapting to
    -- DARK (SpeedDown) stays slower and cinematic. Down raised 0.35 -> 0.6
    -- (2026-07-14, "a bit faster reacting"; photomode now locks exposure
    -- entirely, so gameplay speed no longer has to protect photo shoots).
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
        -- SSR overrides removed 2026-07-14 (MaxRoughness 0.4, then Quality
        -- 100 too): reflection settings in the PP are now fully stock while
        -- the milky car-glass artifact is hunted. Note the sheen is BRIGHT
        -- in dark tunnels, and SSR can only reflect what is on screen, so
        -- the prime suspect is the skylight-leak reflection floor
        -- (LeakAlbedo cvar): test live with Alt+Shift+Z.
        LumenSceneDetail = 2.0,                     -- game runs 1
        LumenFinalGatherLightingUpdateSpeed = 2.0,
        -- BLACK GEOMETRY IN CAR-PAINT REFLECTIONS: screen-trace dependency in
        -- software Lumen. TWO REGIMES (2026-07-31, three-shot A/B):
        --   VANILLA: black only when the reflected object is OFF SCREEN. Stock
        --     engine behaviour, not fixable from here.
        --   WITH Engine.ini: FIXED 2026-07-31. Fine/thin geometry and the gaps
        --     between small details reflected black while large panels were
        --     fine, independent of viewport visibility. Cause: Engine.ini ran
        --     r.Lumen.Reflections.HierarchicalScreenTraces.MaxIterations=4
        --     against an engine default of 50. An HZB is a downsampled depth
        --     pyramid, so thin features vanish at coarse mips and a 4-iteration
        --     traversal never reached one fine enough to resolve them. Now 50
        --     at Engine.ini:108. Watch for the reflection banding that
        --     motivated the 4 to return. See HANDOFF.md.
        -- This cook runs SOFTWARE Lumen (r.RayTracing=False,
        -- r.Lumen.HardwareRayTracing=False, r.Nanite.ProjectEnabled=False are
        -- all cook-time flags, so every r.Lumen.HardwareRayTracing.* line in
        -- Engine.ini is INERT). In software mode a reflection ray that HITS
        -- geometry has one radiance source, the Lumen Scene; miss it and the ray
        -- returns zero, i.e. black exactly where geometry is, while the SKY
        -- stays correct because a ray MISS is served by the skylight cubemap.
        -- Epic documents the symptom class verbatim ("Areas that don't have
        -- Surface Cache coverage will appear black in reflections"; "Small
        -- meshes appear black in mirror reflections because Lumen culls small
        -- objects from Lumen Scene"). Its three cures (hit lighting, multi-
        -- bounce, Nanite) all need cook-time flags this build does not have.
        -- TRIED AND REVERTED: LumenSceneViewDistance = 80000.0 (800 m, against
        -- the stock 20000 uu = 200 m). Note the units are UNREAL UNITS, not
        -- metres, so "800" would have meant EIGHT metres. It did not help.
        -- THE TEST THAT SETTLED IT: with Engine.ini REMOVED, the sign reflects
        -- CORRECTLY in the hood while it is visible in the viewport, and turns
        -- into a black blob the moment it leaves the viewport. Same sign, same
        -- drive. The discriminator is on-screen versus off-screen, which is
        -- screen tracing by definition. It also reproduces with no Engine.ini at
        -- all, so it is neither ours nor the ini's. Zoomed in, the black is
        -- patchy rather than total and MOVES with the camera, which a static
        -- hole in the world representation could not do.
        -- Also disproven: r.Lumen.Reflections.ScreenTraces=0 made it WORSE (it
        -- killed the only working path), and the blobs PREDATE
        -- r.ReflectionEnvironment=0.
        -- Two independent web search passes found NO other report of this exact
        -- artifact, so there is no known workaround to go looking for either.
        -- BLACK BLOBS IN CAR PAINT (2026-07-30): setting this false was WRONG
        -- and is kept here only as a signpost. The diagnosis it rested on (a
        -- grazing-angle screen trace false-hitting thin geometry and returning
        -- dark scene colour) is not what the screenshots show. The SKY
        -- reflects correctly; what comes back black is where GEOMETRY should
        -- be, with torn edges and colour fringing off the sign. That is
        -- Lumen's SURFACE CACHE returning nothing for those meshes, a
        -- different stage entirely. Turning screen traces off made it worse,
        -- because on-screen geometry lost its one good path (scene colour) and
        -- every ray fell through to the empty cache. Look at
        -- r.LumenScene.SurfaceCache.* instead, in particular Feedback
        -- .MinPageHits (Engine.ini runs 32, so surfaces seen ONLY through a
        -- reflection never earn a capture) and AtlasSize.
        LumenReflectionsScreenTraces = true,
        -- Shadow contrast: the game LIFTS unlit areas two ways, film toe
        -- 0.3 (UE default 0.55) and local-exposure shadow scale 0.7 (a
        -- regional lift that tracks auto-exposure). Neutralizing both
        -- darkens shadows without moving mid-tones.
        FilmToe = 0.55,
        LocalExposureShadowContrastScale = 1.0,     -- game runs 0.7
        LocalExposureHighlightContrastScale = 1.0,  -- game runs 0.8
        -- Low-key look pass (2026-07-13, photographic reference targets):
        -- with the frame sitting darker (BiasCurve), a touch of saturation
        -- keeps color alive in the shade instead of washing grey.
        ColorSaturation = { X = 1.05, Y = 1.05, Z = 1.05, W = 1.0 },
        -- Highlight rolloff: the game runs shoulder 0.7 (UE default 0.26),
        -- a hard bright ramp that clips skies to white. Softer shoulder =
        -- skies keep their tone like the reference shots. Raise toward 0.7
        -- if bright scenes start reading dull.
        FilmShoulder = 0.45,
        -- Slight near-black lift (2026-07-14): gain on the shadows region
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

-- ============== RAIN COLLISION (v9 targeted, 2026-07-28) ==============
-- Native rain occlusion on the game's real geometry, pure Lua (the whole
-- discovery arc lives in HANDOFF.md; occlusion internals in
-- reference\udwdig\OCCLUSION_FINDINGS.md). The pass flips ONLY the meshes
-- that matter (tunnel linings + interior sets + overpass decks, matched
-- by asset path) rain-solid, as STEALTH BODIES: object type on a
-- game-undefined channel + Ignore-all responses + Block on the rain
-- channel alone, so the AI and every other game query never see them
-- (the world-wide v7/v8 flip broke AI by sheer mass enablement).
-- Re-runs on a cadence while wet so streamed-in cells get flipped too.
Config.RainCollision = {
    -- Restored after pilot round 2 (2026-08-10): pak loaded crash-free
    -- (name-map fix field-proven) but pak-alone occlusion was not
    -- observed (dry only under drivable/native-collision geometry). The
    -- pilot pak STAYS INSTALLED: with this module back on, the FIRST
    -- pass line's preCtf3 is the discriminator: >0 means the pak's mesh
    -- CollisionTraceFlag override mounted (baseline without pak was 0),
    -- =0 means the container is not overriding at all.
    Enabled = true,
    -- ECollisionChannel index for rain particle traces. 3 = stock
    -- ECC_Visibility (field-verified: occlusion correct). 22..31 = the
    -- private-channel experiment (25 verified game-unused): arms the
    -- containment-fan/shape-neutralization machinery too, but field
    -- round 1 showed mid-air rain loss there: parked, see HANDOFF.
    Channel = 3,
    -- Lua patterns matched against disabled mesh components' static-mesh
    -- asset paths; matching meshes become rain-solid STEALTH BODIES.
    -- HARD CONSTRAINT (2026-08-04): mass collision enablement is the
    -- proven AI breaker (the v7/v8 field failures on both channels), so
    -- this list stays the narrow v9 set that the 3.8.0 "AI healthy"
    -- verdict was given on. From 2026-07-30 to 2026-08-04 it accidentally
    -- carried the whole shadow roster below, and the AI misbehaved in the
    -- field again. Extend ONLY from confirmed rain-through evidence
    -- (Alt+N / Alt+O mesh names), one family at a time.
    -- Naming convention on this course (from the pak dig): a section ships
    -- as SMsr_c1_<sec><tnl|_br|_wc|_wl|_wr> = lining, bridge/deck, and
    -- wall centre/left/right, and tunnel interior sets live under a
    -- Mesh_tn folder (which is how the _pNN_ interior pieces match).
    TargetPatterns = {
        "tnl", "Mesh_tn", "_br%.", "_br$",
    },
    -- Patterns for the tunnel sun-leak SHADOW flip only (two-sided shadow
    -- casting, rendering flags, no collision), so breadth is safe here.
    -- WALLS ADDED 2026-07-30: the first pass covered linings/decks and the
    -- field result was "some geometry instantly works, some does not";
    -- the matched-asset log showed only _pNN_ interior pieces and one _br,
    -- while the tree shadows in the screenshots come through a WALL.
    -- Anchored with %. or $ like _br so they cannot over-match ("kb" also
    -- appears in MATERIAL names, so a loose substring would over-match).
    -- SECTION ROSTER DECODE (2026-07-30, from the collision-independent
    -- enumeration of section c1_067; ray probes cannot see these because
    -- art meshes ship with collision DISABLED):
    --   _wc/_wl/_wr        wall centre/left/right
    --   _br                bridge/deck
    --   _s                 sidewalk/shoulder = the raised KERB strip
    --   _w_extcS_<place>   EXTERIOR wall, continues outside the tunnel
    --   _a                 apron/verge
    ShadowFixPatterns = {
        "tnl", "Mesh_tn", "_br%.", "_br$",
        "_wc%.", "_wc$", "_wl%.", "_wl$", "_wr%.", "_wr$",
        "_kb%.", "_kb$",
        "_s%.", "_s$",
        "w_ext",
        -- APRONS, SECTION-PREFIXED (2026-08-09): bare "_a%."/"_a$" also
        -- matched SMobj_pylon_a = every traffic cone. A PA load pass
        -- (2026-08-08 23:51:59 log) filled all 60 matched-asset slots
        -- with pylons and flipped 56 of them, so the cap could no longer
        -- catch new families (the tunnel-ceiling lead). The SMsr_ prefix
        -- limits the anchors to section meshes; [%w_]* cannot cross '/'
        -- or '.', so a folder name cannot bridge into a prop suffix.
        -- Coverage unchanged: the census apron family (a 59/59) is
        -- entirely SMsr_.
        "SMsr_[%w_]*_a%.", "SMsr_[%w_]*_a$",
        -- EVERYTHING-FLIPPED TEST (2026-07-30), RUN AND REVERTED: _r (roadway,
        -- 200), _p (237) and _rj (road joints, 127) were added so that every
        -- structural family in the world was two-sided at once. The leak was
        -- UNCHANGED. Removed again, because they roughly doubled the pass and
        -- put self-shadowing acne risk on the asphalt for zero benefit.
        -- Do not re-add them: this test is done and the answer was no.
    },
    -- THE SHADOW LIST IS COMPLETE (settled 2026-07-30 by the Alt+O family census).
    -- The census enumerates every asset suffix family in the loaded world by
    -- NAME, so unlike a trace it can see art meshes that ship with collision
    -- disabled. Post-flip it reads 100% on every structural family:
    --   s 200/200, wr 122/122, wl 120/120, kb 66/66, a 59/59, wc 43/43,
    --   tnl 20/20, br 17/17, w_ext 12/12
    -- so there was no missed family. The last three (_r 200, _p 237, _rj 127)
    -- were then flipped too, as a one-shot test, and changed nothing, so the
    -- search space is provably exhausted.
    --
    -- The residual lit kerb that drove five rounds of pattern-hunting is NOT
    -- a casting-flag problem and is not reachable from Lua. It is missing
    -- geometry: the outer "second wall" is the w_ext family, and there are
    -- only TWELVE w_ext assets in the whole map. Section rosters show
    -- c1_066 and c1_067 have one while c1_065, c1_068 and c1_069 have none,
    -- and every row reads vis=true hidden=false, so nothing is merely culled
    -- and bCastHiddenShadow has nothing to act on. Where the art placed no
    -- exterior wall the low sun simply has an unobstructed path to the kerb.
    -- Known residual, closed. A temporary section-wide "SMsr_c1_067" pattern
    -- was used as the decision procedure and has been removed.
    ReapplySeconds = 20.0,  -- streamed-cell re-pass cadence while wet
    SettleSeconds = 3.0,    -- course-arm settle before the first pass
    Debug = false,          -- log quiet periodic no-op passes too

    -- TUNNEL SUN-LEAK FIX. PERMANENT SHIPPING FEATURE as of 2026-07-30,
    -- promoted from the experiment it started as.
    --
    -- THE BUG IT FIXES: the game's tunnel and bridge decks cast shadows
    -- ONE-SIDED (measured: CastShadow=true but bCastShadowAsTwoSided=false),
    -- so from the sun's side the shadow pass culls their backfaces and
    -- daylight lands on the road inside a covered section, tree shadows and
    -- all. It is a VANILLA artifact, reproduced with no mod and no
    -- Engine.ini, and it is the same one-sided geometry that makes rain
    -- need an upward trace. The pass flips every matched mesh to two-sided
    -- shadow casting and forces the render-state rebuild that makes it take
    -- effect, since the flag has no setter of its own.
    --
    -- FIELD-VERIFIED with a same-bore A/B: the warm wall streak and the
    -- ceiling dapple are gone. What it does NOT fix is the lit kerb where a
    -- section has no outer wall at all, because that is missing geometry
    -- rather than a casting flag (see the note above the pattern list). That
    -- residual is closed and is not a reason to keep this off.
    --
    -- COSTS, accepted: two-sided casting is not free, each flipped mesh
    -- rebuilds its render proxy once, and this makes the world pass run in
    -- DRY weather too (normally wet-only), because a sun leak is a sunny-day
    -- problem. The pass is chunked so the rebuild does not hitch. Watch
    -- shadowFixed=N and gt_ms_maxchunk in the pass log line.
    --
    -- No longer a toggle. The Alt+I test keybind is retired: its revert path
    -- keys on tostring(component), which is not stable across passes, so
    -- toggling OFF reverted only a few dozen of ~660 meshes and would
    -- falsely exonerate the fix in an A/B. Use a course reload if you ever
    -- need to compare.
    --
    -- AI-RESIDUAL A/B (2026-08-07, field: AI still bugs out sometimes near
    -- tunnels): setting this FALSE for a session is the clean isolation
    -- test for the shadow-pass render-state churn hypothesis (SetCastShadow
    -- false->true proxy rebuilds hitching the GT near bores as cells
    -- stream). Safe to run: the pass gate is (wet or FixShadowLeak), so
    -- rain occlusion and the stealth-collision block keep working in wet
    -- weather; only the two-sided shadow flip stops. Expect the tunnel sun
    -- leak back for that session. Restart the game after flipping (stale
    -- flips do not survive a course reload, so state self-heals).
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
    SpaceLayer  = true,   -- night-sky nebula
    CinematicSky= true,   -- daytime cloud/atmosphere grade (see Config.CinematicSky)
    LightCycle  = true,   -- sun-elevation exposure (see Config.LightCycle)
    Tunnels     = true,   -- covered-road rain kill (see Config.Tunnels)
    RainCollision = true, -- native rain occlusion (see Config.RainCollision)
    RealSun     = true,   -- real-sun probe + experiment (see Config.RealSun)
    Vignette    = true,   -- hide the HUD vignette (see Config.Vignette)
    PhotoMode   = true,   -- photo mode free-camera unlocks
    WetGrip     = true,   -- RAIN RETURNS (3.8.0): dynamic wet grip back on
    Audio       = true,   -- RAIN RETURNS (3.8.0): weather sound restored
    Tuning      = true,   -- alignment slider-range widening (see Config.Tuning)
}

-- ============== VERSION ==============
-- Bump String only; FullName derives from it. (2026-08-09 cleanup:
-- Major/Minor/Patch and Name had no readers anywhere, release tooling
-- included, and the duplicated version string was a bump hazard.)
Config.Version = {
    String = "3.9.0",
}
Config.Version.FullName = "TXR Weather Mod v" .. Config.Version.String

return Config
