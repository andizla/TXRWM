-- TXR Weather Mod v3.0
-- main.lua
-- Bootstrap and main loop

-- ============== MODULE LOADING ==============

-- Helper to safely require modules
local function safeRequire(modulePath, moduleName)
    local success, result = pcall(require, modulePath)
    if success then
        return result, nil
    else
        print(string.format("[FATAL] Failed to load %s: %s", moduleName, tostring(result)))
        return nil, result
    end
end

-- ============== LOAD CORE MODULES ==============

-- Load config first (no dependencies)
local Config = safeRequire("config", "Config")
if not Config then
    error("Cannot continue without Config module")
end

-- Load logging (depends on nothing)
local Log = safeRequire("core.logging", "Logging")
if not Log then
    error("Cannot continue without Logging module")
end

-- Initialize logging
Log.Init({
    minLevel = Config.Logging.MinLevel,
    logToFile = Config.Logging.EnableFileLogging,
    logToConsole = Config.Logging.EnableConsoleLogging,
    version = Config.Version and Config.Version.String,
})

Log.Info("Main", "==============================================")
Log.Info("Main", Config.Version.FullName)
Log.Info("Main", "==============================================")

-- Load utils (depends on nothing)
local Utils = safeRequire("core.utils", "Utils")
if not Utils then
    Log.Error("Main", "Failed to load Utils module: continuing with limited functionality")
end

-- Load state (depends on nothing)
local State = safeRequire("core.state", "State")
if not State then
    Log.Error("Main", "Failed to load State module: continuing with limited functionality")
end

-- Mark core modules as loaded
if State then
    State.InitSession()
    State.SetModuleStatus("logging", true)
    Log.Info("Main", "Core module loaded: Logging")
    
    if Utils then
        State.SetModuleStatus("utils", true)
        Log.Info("Main", "Core module loaded: Utils")
    end
    
    State.SetModuleStatus("state", true)
    Log.Info("Main", "Core module loaded: State")
end

-- ============== LOAD SYSTEM MODULES ==============
-- These will be loaded in Phase 2+

local Actors = nil
local Weather = nil
local Scheduler = nil
local Presets = nil
local TimeOfDay = nil
local Keybinds = nil
local Persistence = nil
local CloudsFog = nil
local Lightning = nil
local EnhancedFog = nil
local Wetness = nil
local Shadows = nil
local Transitions = nil
local Atmosphere = nil
local Headlights = nil
local Audio = nil
local Stars = nil
local LightCycle = nil
local Tunnels = nil
local WindDebris = nil
local LightRays = nil
local Moon = nil
local Rainbow = nil
local SpaceLayer = nil
local CinematicSky = nil
local RealSun = nil
local Vignette = nil
local PhotoMode = nil
local WetGrip = nil
local Tuning = nil

-- Attempt to load system modules (may not exist yet)
local function loadSystemModules()
    Log.Info("Main", "Loading system modules...")
    
    -- Phase 2: Actor discovery
    Actors = safeRequire("systems.actors", "Actors")
    if Actors then
        Log.Info("Main", "System module loaded: Actors")
        State.SetModuleStatus("actors", true)
    else
        Log.Debug("Main", "Actors module not yet implemented")
    end
    
    -- Phase 3: Weather control
    Presets = safeRequire("systems.presets", "Presets")
    if Presets then
        Log.Info("Main", "System module loaded: Presets", {count = Presets.GetCount()})
    else
        Log.Debug("Main", "Presets module not yet implemented")
    end
    
    Weather = safeRequire("systems.weather", "Weather")
    if Weather then
        Log.Info("Main", "System module loaded: Weather")
        State.SetModuleStatus("weather", true)
    else
        Log.Debug("Main", "Weather module not yet implemented")
    end
    
    -- Phase 4: Time and input
    TimeOfDay = safeRequire("systems.time_of_day", "TimeOfDay")
    if TimeOfDay then
        Log.Info("Main", "System module loaded: TimeOfDay")
        State.SetModuleStatus("timeOfDay", true)
    else
        Log.Debug("Main", "TimeOfDay module not yet implemented")
    end
    
    Keybinds = safeRequire("systems.keybinds", "Keybinds")
    if Keybinds then
        Log.Info("Main", "System module loaded: Keybinds")
        -- Note: Actual keybind registration happens in initialize()
    else
        Log.Debug("Main", "Keybinds module not yet implemented")
    end
    
    Persistence = safeRequire("systems.persistence", "Persistence")
    if Persistence then
        Log.Info("Main", "System module loaded: Persistence")
        State.SetModuleStatus("persistence", true)
    else
        Log.Debug("Main", "Persistence module not yet implemented")
    end
    
    CloudsFog = safeRequire("systems.clouds_fog", "CloudsFog")
    if CloudsFog then
        Log.Info("Main", "System module loaded: CloudsFog")
        State.SetModuleStatus("cloudsFog", true)
    else
        Log.Debug("Main", "CloudsFog module not yet implemented")
    end
    
    -- Phase 7: Lightning control
    Lightning = safeRequire("systems.lightning", "Lightning")
    if Lightning then
        Log.Info("Main", "System module loaded: Lightning")
        State.SetModuleStatus("lightning", true)
    else
        Log.Debug("Main", "Lightning module not yet implemented")
    end
    
    -- Phase 7: Enhanced fog control
    EnhancedFog = safeRequire("systems.enhanced_fog", "EnhancedFog")
    if EnhancedFog then
        Log.Info("Main", "System module loaded: EnhancedFog")
        State.SetModuleStatus("enhancedFog", true)
    else
        Log.Debug("Main", "EnhancedFog module not yet implemented")
    end
    
    -- Shadow distance scaling based on FOV
    Shadows = safeRequire("systems.shadows", "Shadows")
    if Shadows then
        Log.Info("Main", "System module loaded: Shadows")
        State.SetModuleStatus("shadows", true)
    else
        Log.Debug("Main", "Shadows module not loaded")
    end
    
    -- Phase 8: Dawn/Dusk transitions (slow time, Tokyo tint)
    Transitions = safeRequire("systems.transitions", "Transitions")
    if Transitions then
        Log.Info("Main", "System module loaded: Transitions")
        if Transitions.Init then Transitions.Init() end
    else
        Log.Debug("Main", "Transitions module not loaded")
    end
    
    -- Phase 9: Atmospheric enhancements (god rays, aurora, cloud shadows)
    Atmosphere = safeRequire("systems.atmosphere", "Atmosphere")
    if Atmosphere then
        Log.Info("Main", "System module loaded: Atmosphere")
        if Atmosphere.Init then Atmosphere.Init() end
    else
        Log.Debug("Main", "Atmosphere module not loaded")
    end
    
    -- Phase 10: Headlights (auto on/off based on time)
    Headlights = safeRequire("systems.headlights", "Headlights")
    if Headlights then
        Log.Info("Main", "System module loaded: Headlights")
        if Headlights.Init then Headlights.Init() end
    else
        Log.Debug("Main", "Headlights module not loaded")
    end
    
    -- Phase 10: Audio (weather sounds)
    Audio = safeRequire("systems.audio", "Audio")
    if Audio then
        Log.Info("Main", "System module loaded: Audio")
        if Audio.Init then Audio.Init() end
    else
        Log.Debug("Main", "Audio module not loaded")
    end

    -- Phase 12: Stars (HD night sky)
    Stars = safeRequire("systems.stars", "Stars")
    if Stars then
        Log.Info("Main", "System module loaded: Stars")
        if Stars.Init then Stars.Init() end
    else
        Log.Debug("Main", "Stars module not loaded")
    end

    -- Light cycle: sun-elevation-driven exposure (the active exposure system)
    LightCycle = safeRequire("systems.light_cycle", "LightCycle")
    if LightCycle then
        Log.Info("Main", "System module loaded: LightCycle")
        if LightCycle.Init then LightCycle.Init() end
    else
        Log.Debug("Main", "LightCycle module not loaded")
    end

    -- Tunnels: covered-road detection + rain kill (split from LightCycle)
    Tunnels = safeRequire("systems.tunnels", "Tunnels")
    if Tunnels then
        Log.Info("Main", "System module loaded: Tunnels")
        if Tunnels.Init then Tunnels.Init() end
    else
        Log.Debug("Main", "Tunnels module not loaded")
    end

    -- Wind debris (UDW Niagara debris, scales with wind intensity)
    WindDebris = safeRequire("systems.wind_debris", "WindDebris")
    if WindDebris then
        Log.Info("Main", "System module loaded: WindDebris")
        if WindDebris.Init then WindDebris.Init() end
    else
        Log.Debug("Main", "WindDebris module not loaded")
    end

    -- Volumetric cloud light rays (UDS Niagara god-ray shafts through cloud gaps)
    LightRays = safeRequire("systems.volumetric_light_rays", "LightRays")
    if LightRays then
        Log.Info("Main", "System module loaded: LightRays")
        if LightRays.Init then LightRays.Init() end
    else
        Log.Debug("Main", "LightRays module not loaded")
    end

    -- Moon appearance (phases + scale)
    Moon = safeRequire("systems.moon", "Moon")
    if Moon then
        Log.Info("Main", "System module loaded: Moon")
        if Moon.Init then Moon.Init() end
    else
        Log.Debug("Main", "Moon module not loaded")
    end

    -- Rainbow (UDW mesh-rendered rainbow; UDW drives visibility from weather)
    Rainbow = safeRequire("systems.rainbow", "Rainbow")
    if Rainbow then
        Log.Info("Main", "System module loaded: Rainbow")
        if Rainbow.Init then Rainbow.Init() end
    else
        Log.Debug("Main", "Rainbow module not loaded")
    end

    -- Space Layer (night-sky nebula rendered into the sky material)
    SpaceLayer = safeRequire("systems.space_layer", "SpaceLayer")
    if SpaceLayer then
        Log.Info("Main", "System module loaded: SpaceLayer")
        if SpaceLayer.Init then SpaceLayer.Init() end
    else
        Log.Debug("Main", "SpaceLayer module not loaded")
    end

    -- Cinematic sky (daytime cloud/atmosphere grade; settle-gated one-shot)
    CinematicSky = safeRequire("systems.cinematic_sky", "CinematicSky")
    if CinematicSky then
        Log.Info("Main", "System module loaded: CinematicSky")
        if CinematicSky.Init then CinematicSky.Init() end
    else
        Log.Debug("Main", "CinematicSky module not loaded")
    end

    -- Real sun (probe + real-world solar simulation experiment; settle-gated)
    RealSun = safeRequire("systems.real_sun", "RealSun")
    if RealSun then
        Log.Info("Main", "System module loaded: RealSun")
        if RealSun.Init then RealSun.Init() end
    else
        Log.Debug("Main", "RealSun module not loaded")
    end

    -- Vignette (hide HUD vignette; opt-in UI toggle)
    Vignette = safeRequire("systems.vignette", "Vignette")
    if Vignette then
        Log.Info("Main", "System module loaded: Vignette")
        if Vignette.Init then Vignette.Init() end
    else
        Log.Debug("Main", "Vignette module not loaded")
    end

    -- Photo mode unlocker (free-cam collision/distance/FOV/speed; self-gating)
    PhotoMode = safeRequire("systems.photomode", "PhotoMode")
    if PhotoMode then
        Log.Info("Main", "System module loaded: PhotoMode")
        if PhotoMode.Init then PhotoMode.Init() end
    else
        Log.Debug("Main", "PhotoMode module not loaded")
    end

    -- Dynamic wet grip (player tire grip scales with UDW precipitation)
    WetGrip = safeRequire("systems.wet_grip", "WetGrip")
    if WetGrip then
        Log.Info("Main", "System module loaded: WetGrip")
        if WetGrip.Init then WetGrip.Init() end
    else
        Log.Debug("Main", "WetGrip module not loaded")
    end

    -- Alignment slider-range widening (garage tuning menu)
    Tuning = safeRequire("systems.tuning", "Tuning")
    if Tuning then
        Log.Info("Main", "System module loaded: Tuning")
        if Tuning.Init then Tuning.Init() end
    else
        Log.Debug("Main", "Tuning module not loaded")
    end

    -- Phase 11: Random weather preset scheduler
    Scheduler = safeRequire("systems.scheduler", "Scheduler")
    if Scheduler then
        Log.Info("Main", "System module loaded: Scheduler")
        if Scheduler.Init then Scheduler.Init() end
    else
        Log.Debug("Main", "Scheduler module not loaded")
    end

    -- Phase 6: Wetness simulation (disabled by default, WIP)
    if Config.Wetness and Config.Wetness.Enabled then
        Wetness = safeRequire("systems.wetness", "Wetness")
        if Wetness then
            Log.Info("Main", "System module loaded: Wetness")
            State.SetModuleStatus("wetness", true)
        else
            Log.Debug("Main", "Wetness module failed to load")
        end
    else
        Log.Info("Main", "Wetness module disabled in config")
    end
end

-- ============== MAIN LOOP ==============

local lastHeartbeat = os.time()
local tickCount = 0
local initialWeatherApplied = false  -- Track if we've applied initial weather this session
local restoredFromPA = false         -- Flag to skip initial weather when restoring from PA
local _pendingRestore = false        -- Flag set when actors become invalid, triggers restore on next valid

-- PA freeze watchdog: continuously enforce freeze while in PA
local function enforcePAFreezeWatchdog()
    local uds = Actors and Actors.GetUDS()
    if uds then
        pcall(function() uds["Animate Time of Day"] = false end)
        pcall(function() uds["Simulation Speed"] = 0 end)
        pcall(function() uds["Time Speed"] = 0 end)
    end
end

-- Captured course state (runtime fallback for the persistence file), written
-- on map unload. Declared HERE so applyPAState below captures it as an
-- upvalue (declared further down it would silently split into a global).
local _CourseStateBeforePA = nil

-- PA weather (Config.PA.Mode, canon 2026-07-09): the PA scene lives in the
-- SAME outgame world as the garage but has its OWN working UDS/UDW (canned
-- state: always night, TOD 1950 / cloud 7.5 / fog 3.0). Discovery succeeding
-- in an outgame world = PA; the garage's UDS never validates.
--   "continue": carry the captured course weather/time into the PA and keep
--               the clock running at the captured course speed.
--   "freeze":   same carry, then freeze time (the original V1.32 behavior).
--   "stock":    leave the canned PA night alone.
local paStateApplied = false

local function applyPAState()
    local mode = "continue"
    pcall(function()
        if type(Config.PA.Mode) == "string" then mode = Config.PA.Mode:lower() end
    end)

    local uds = Actors and Actors.GetUDS and Actors.GetUDS()
    local udw = Actors and Actors.GetUDW and Actors.GetUDW()
    if not uds then return end

    -- Captured course state: persistence file first, runtime capture fallback
    local tod, cloud, fog, preset, speed = nil, nil, nil, nil, nil
    if Persistence and Persistence.LoadRaw then
        local data = Persistence.LoadRaw()
        if data then
            tod, cloud, fog, preset, speed =
                data.tod, data.cloud, data.fog, data.preset, data.speed
        end
    end
    local cap = _CourseStateBeforePA
    if cap then
        if (not tod or tod < 0) and cap.tod then tod = cap.tod end
        if (not cloud or cloud < 0) and cap.cloud then cloud = cap.cloud end
        if fog == nil and cap.fog then fog = cap.fog end
        if preset == nil and cap.preset then preset = cap.preset end
        if speed == nil and cap.speed then speed = cap.speed end
    end

    if tod and tod >= 0 and tod <= 2400 then
        pcall(function() uds["Time Of Day"] = tod end)
    end
    if udw then
        if cloud and cloud >= 0 then
            pcall(function() udw["Cloud Coverage - Manual Override"] = true end)
            pcall(function() udw["Cloud Coverage"] = cloud end)
        end
        if fog ~= nil then
            pcall(function() udw["Fog - Manual Override"] = true end)
            pcall(function() udw["Fog"] = fog end)
        end
    end
    -- Re-apply the preset for rain/effects (Weather.Apply accepts the PA
    -- scene: its actors validate, unlike the garage's)
    if preset and Weather and Weather.Apply then
        pcall(function() Weather.Apply(preset, 0) end)
    end

    if mode == "freeze" then
        pcall(function() uds["Simulate Real Sun"] = false end)
        pcall(function() uds["Animate Time of Day"] = false end)
        pcall(function() uds["Time Speed"] = 0 end)
        pcall(function() uds["Simulation Speed"] = 0 end)
        if State and State.SetPAFrozen then State.SetPAFrozen(true) end
    else
        -- continue: PA clock runs at the captured course speed
        pcall(function() uds["Animate Time of Day"] = true end)
        local spd = speed
        if not spd and State and State.GetTimeSpeed then spd = State.GetTimeSpeed() end
        if spd and spd > 0 then
            pcall(function() uds["Time Speed"] = 1.0 end)
            pcall(function() uds["Simulation Speed"] = spd end)
        end
    end

    -- Exposure follows the PA's real sun (light_cycle bypasses the garage
    -- constants for a validated PA scene); arm it like a course entry.
    if LightCycle and LightCycle.OnCourseLoad then
        LightCycle.OnCourseLoad()
    end
    if Tunnels and Tunnels.OnCourseLoad then
        Tunnels.OnCourseLoad()
    end

    Log.Info("Main", "PA state applied", {
        mode = mode,
        tod = tod or -1,
        cloud = cloud or -1,
        fog = fog or -1,
        preset = preset or "?",
        speed = speed or -1,
    })
end

local function onTick()
    -- Increment counters
    tickCount = tickCount + 1
    if State then
        State.IncrementLoopCount()
    end
    
    -- Wrap all tick logic in pcall to never crash the game
    local success, err = pcall(function()
        -- Periodic heartbeat log
        local now = os.time()
        if Config.Logging.HeartbeatInterval > 0 then
            if now - lastHeartbeat >= Config.Logging.HeartbeatInterval then
                lastHeartbeat = now
                local snapshot = State and State.GetDebugSnapshot() or {}
                local actorStatus = Actors and Actors.GetStatus() or {}
                Log.Debug("Main", "Heartbeat", {
                    tick = tickCount,
                    hasActors = snapshot.hasUDS and snapshot.hasUDW,
                    context = snapshot.context,
                    preset = snapshot.currentPreset or "none",
                    searching = actorStatus.isSearching,
                })
            end
        end
        
        -- Periodic loop count log
        if tickCount % Config.MainLoop.LogEveryNLoops == 0 then
            Log.Debug("Main", string.format("Loop #%d", tickCount))
        end
        
        -- Phase 2+: Actor discovery
        if Actors and Actors.Tick then
            Actors.Tick()
        end
        
        -- PA freeze watchdog: continuously enforce freeze while in PA
        if State.IsPAFrozen() then
            enforcePAFreezeWatchdog()
        end
        
        -- Phase 3+: Weather updates (skip in PA)
        if Weather and Weather.Tick and not State.IsPAFrozen() then
            Weather.Tick()
        end

        -- Phase 11: Random weather scheduler (skip in PA)
        if Scheduler and Scheduler.Tick and not State.IsPAFrozen() then
            Scheduler.Tick()
        end
        
        -- Apply initial settings once actors are discovered (but not in PA or just restored from PA)
        if not initialWeatherApplied and Actors and Actors.IsOnCourse() and not State.IsPAFrozen() then
            -- If we just restored from PA, skip the normal initialization
            if restoredFromPA then
                Log.Info("Main", "Restored from PA: skipping initial weather setup")
                -- Still need to initialize DLWE system
                if Wetness and Wetness.OnActorsReady then
                    Wetness.OnActorsReady()
                end
                initialWeatherApplied = true
                restoredFromPA = false
            else
                Log.Info("Main", "Actors ready: triggering initial setup")
                
                -- Initialize DLWE system FIRST before any weather operations
                if Wetness and Wetness.OnActorsReady then
                    Wetness.OnActorsReady()
                end
                
                -- Try to restore persisted state first
                local restored = false
                if Persistence and Persistence.Restore then
                    restored = Persistence.Restore()
                    if restored then
                        Log.Info("Main", "Restored persisted state")
                    end
                end
                
                -- If not restored, apply defaults
                if not restored then
                    -- Apply initial weather
                    if Weather and Weather.OnCourseLoad then
                        Weather.OnCourseLoad()
                    end
                    
                    -- Apply initial time settings
                    if TimeOfDay and TimeOfDay.OnCourseLoad then
                        TimeOfDay.OnCourseLoad()
                    end
                end
                
                -- Initialize clouds/fog (always, whether restored or not)
                if CloudsFog and CloudsFog.OnCourseLoad then
                    CloudsFog.OnCourseLoad()
                end

                -- Reset the weather-effect helpers' per-course state (fog
                -- manual-override flag, lightning manager ref)
                if EnhancedFog and EnhancedFog.OnCourseLoad then
                    EnhancedFog.OnCourseLoad()
                end
                if Lightning and Lightning.OnCourseLoad then
                    Lightning.OnCourseLoad()
                end
                
                -- Initialize atmosphere (god rays, aurora, cloud shadows)
                if Atmosphere and Atmosphere.Setup then
                    Atmosphere.Setup()
                end
                
                -- Initialize audio (weather sounds)
                if Audio and Audio.Setup then
                    Audio.Setup()
                end

                -- Apply HD stars (night sky)
                if Stars and Stars.Setup then
                    Stars.Setup()
                end

                -- Force exposure to re-apply its slot (map load may reset CVARs)
                if LightCycle and LightCycle.OnCourseLoad then
                    LightCycle.OnCourseLoad()
                end
                if Tunnels and Tunnels.OnCourseLoad then
                    Tunnels.OnCourseLoad()
                end

                -- Reconcile headlights: clear any cast-only desync the game's native
                -- auto leaves at load by re-asserting the desired state on entry.
                if Headlights and Headlights.OnCourseLoad then
                    Headlights.OnCourseLoad()
                end

                -- Re-baseline wet grip for the fresh car (incl. a race started from PA).
                if WetGrip and WetGrip.OnCourseLoad then
                    WetGrip.OnCourseLoad()
                end

                initialWeatherApplied = true
            end
        end
        
        -- PA lifecycle (Config.PA.Mode ~= "stock"): apply the captured course
        -- state once when the PA's own actors bind; clear when they're gone.
        if Config.PA and Config.PA.Mode and Config.PA.Mode ~= "stock" then
            if not paStateApplied and Actors and Actors.IsInPAScene and Actors.IsInPAScene() then
                paStateApplied = true
                applyPAState()
            elseif paStateApplied and Actors and not Actors.HasActors() then
                paStateApplied = false
                if State and State.IsPAFrozen and State.IsPAFrozen() then
                    State.SetPAFrozen(false)
                end
                if LightCycle and LightCycle.OnCourseUnload then
                    LightCycle.OnCourseUnload()   -- disarm; the PA actors are gone
                end
                if Tunnels and Tunnels.OnCourseUnload then
                    Tunnels.OnCourseUnload()
                end
                Log.Info("Main", "PA state cleared (actors lost)")
            end
        end

        -- Reset flag when leaving course
        if initialWeatherApplied and Actors and not Actors.HasActors() then
            -- Save state before leaving course
            if Persistence and Persistence.Save then
                Persistence.Save("course_unload")
            end
            -- Reset CloudsFog state
            if CloudsFog and CloudsFog.OnCourseUnload then
                CloudsFog.OnCourseUnload()
            end
            -- Drop per-course refs/flags in the weather-effect helpers (the
            -- lightning manager ref is a course-world object; keeping it
            -- across the teardown is the known cross-world-ref crash pattern)
            if EnhancedFog and EnhancedFog.OnCourseUnload then
                EnhancedFog.OnCourseUnload()
            end
            if Lightning and Lightning.OnCourseUnload then
                Lightning.OnCourseUnload()
            end
            -- Disarm exposure's course branch so the re-entry transient (unrestored
            -- UDS reads Time Of Day = 0) can't flash the midnight slot before restore.
            if LightCycle and LightCycle.OnCourseUnload then
                LightCycle.OnCourseUnload()
            end
            if Tunnels and Tunnels.OnCourseUnload then
                Tunnels.OnCourseUnload()
            end
            initialWeatherApplied = false
            _pendingRestore = true  -- Signal to restore on next actor detection
            Log.Info("Main", "Actors lost: pending restore on next detection")
        end
        
        -- Phase 4+: Time updates (skip in PA)
        if TimeOfDay and TimeOfDay.Tick and not State.IsPAFrozen() then
            TimeOfDay.Tick()
        end
        
        -- Clouds and fog updates (skip in PA)
        if CloudsFog and CloudsFog.Tick and not State.IsPAFrozen() then
            CloudsFog.Tick()
        end
        
        -- Persistence autosave (skip in PA)
        if Persistence and Persistence.Tick and not State.IsPAFrozen() then
            Persistence.Tick()
        end
        
        -- Wetness simulation (skip in PA)
        if Wetness and Wetness.Tick and not State.IsPAFrozen() then
            Wetness.Tick()
        end

        -- Dynamic wet grip (global tire degradation table vs precipitation; self-throttled,
        -- re-applies only on change). Intentionally NOT PA-frozen-gated: a race initiated
        -- from PA is the case we most need it in, and the global table edit is what makes
        -- PA + AI work. It only scales tire grip rates (never the PA-persisted weather
        -- state), so running through the PA transition is safe.
        if WetGrip and WetGrip.Tick then
            WetGrip.Tick()
        end
        
        -- Shadow distance scaling (updates based on FOV)
        if Shadows and Shadows.Update then
            Shadows.Update()
        end
        
        -- Dawn/Dusk transitions (slow time, Tokyo tint)
        if Transitions and Transitions.Tick and not State.IsPAFrozen() then
            Transitions.Tick()
        end
        
        -- Atmospheric enhancements (god rays, aurora, cloud shadows)
        if Atmosphere and Atmosphere.Tick and not State.IsPAFrozen() then
            Atmosphere.Tick()
        end
        
        -- Headlights (auto on/off; auto mode follows the exposure brightness)
        if Headlights and Headlights.Tick and not State.IsPAFrozen() then
            Headlights.Tick()
        end

        -- Stars (settle-gated apply, deferred past BeginPlay)
        if Stars and Stars.Tick and not State.IsPAFrozen() then
            Stars.Tick()
        end

        -- Wind debris (settle-gated one-shot apply)
        if WindDebris and WindDebris.Tick and not State.IsPAFrozen() then
            WindDebris.Tick()
        end

        -- Volumetric cloud light rays (settle-gated one-shot apply)
        if LightRays and LightRays.Tick and not State.IsPAFrozen() then
            LightRays.Tick()
        end

        -- Moon appearance (settle-gated one-shot apply)
        if Moon and Moon.Tick and not State.IsPAFrozen() then
            Moon.Tick()
        end

        -- Rainbow (settle-gated one-shot enable; UDW drives visibility)
        if Rainbow and Rainbow.Tick and not State.IsPAFrozen() then
            Rainbow.Tick()
        end

        -- Space Layer nebula (settle-gated one-shot apply)
        if SpaceLayer and SpaceLayer.Tick and not State.IsPAFrozen() then
            SpaceLayer.Tick()
        end

        -- Cinematic sky grade (settle-gated one-shot apply)
        if CinematicSky and CinematicSky.Tick and not State.IsPAFrozen() then
            CinematicSky.Tick()
        end

        -- Real sun probe/experiment (settle-gated one-shot)
        if RealSun and RealSun.Tick and not State.IsPAFrozen() then
            RealSun.Tick()
        end

        -- Weather audio (settle-gated one-shot apply of UDW's native sounds)
        if Audio and Audio.Tick and not State.IsPAFrozen() then
            Audio.Tick()
        end

        -- Vignette HUD toggle (throttled re-assert; runs in/out of course like the
        -- HUD itself, so intentionally not gated by the PA-frozen check)
        if Vignette and Vignette.Tick then
            Vignette.Tick()
        end

        -- Light cycle (exposure/look; also runs in garage/menu, so it is
        -- intentionally NOT gated by the PA-frozen check)
        if LightCycle and LightCycle.Tick then
            LightCycle.Tick()
        end

        -- Tunnels (covered-road rain kill; entered at the full tick rate and
        -- self-paced inside, so portal reactions stay at the 0.25s budget)
        if Tunnels and Tunnels.Tick then
            Tunnels.Tick()
        end

        -- Tuning slider widening (the alignment menu lives in the garage, so
        -- like Exposure/Vignette it is NOT course- or PA-gated)
        if Tuning and Tuning.Tick then
            Tuning.Tick()
        end

        -- NOTE: PhotoMode is intentionally NOT ticked here. It runs its own dedicated
        -- LoopAsync (started in PhotoMode.Init) so its re-assert can't be stalled or
        -- skipped by anything else in this shared tick.
    end)
    
    if not success then
        Log.Error("Main", "Tick error: " .. tostring(err))
        if State then
            State.SetLastError(tostring(err))
        end
    end
end

-- ============== UE4SS HOOKS ==============

local function setupHooks()
    Log.Info("Main", "Setting up UE4SS hooks...")
    
    -- Check if we're in UE4SS environment
    if not RegisterHook then
        Log.Warn("Main", "RegisterHook not available: running outside UE4SS?")
        return false
    end
    
    -- Note: LoadMapPreHook and BeginPlayPreHook are registered at global scope (end of file)
    -- to match V1.34's pattern. We only register ReceiveBeginPlay/EndPlay here as fallback.
    
    -- BeginPlay hook for map load detection (fallback)
    local hookSuccess, hookErr = pcall(function()
        RegisterHook("/Script/Engine.Actor:ReceiveBeginPlay", function(self)
            -- Safely get actor name
            local success, actorName = pcall(function()
                return self:GetFullName()
            end)
            
            if success and actorName then
                -- Check if this is a sky actor
                if actorName:find("Ultra_Dynamic_Sky") then
                    Log.Info("Main", "BeginPlay: UDS actor detected", {
                        actor = Utils and Utils.Truncate(actorName, 60) or actorName:sub(1, 60)
                    })
                    
                    -- Trigger actor discovery
                    if Actors and Actors.OnMapLoad then
                        Actors.OnMapLoad()
                    end
                    
                    -- Clear weather cache on new map
                    if Weather and Weather.ClearCache then
                        Weather.ClearCache()
                    end
                end
            end
        end)
        Log.Info("Main", "BeginPlay hook registered")
    end)
    
    if not hookSuccess then
        Log.Warn("Main", "Failed to register BeginPlay hook: " .. tostring(hookErr))
    end
    
    -- EndPlay hook for map unload detection
    local endPlaySuccess, endPlayErr = pcall(function()
        RegisterHook("/Script/Engine.Actor:ReceiveEndPlay", function(self)
            -- During map teardown EndPlay fires for EVERY dying actor; the unload
            -- handling already ran (LoadMapPreHook), so skip the per-actor name
            -- lookups on half-destroyed objects for the rest of the window.
            if Actors and Actors.IsDiscoverySuspended and Actors.IsDiscoverySuspended() then
                return
            end

            -- Safely get actor name
            local success, actorName = pcall(function()
                return self:GetFullName()
            end)
            
            if success and actorName then
                if actorName:find("Ultra_Dynamic_Sky") then
                    Log.Info("Main", "EndPlay: UDS actor destroyed (map unload)")
                    
                    -- Notify actors module
                    if Actors and Actors.OnMapUnload then
                        Actors.OnMapUnload()
                    end
                    
                    -- Clear weather cache
                    if Weather and Weather.ClearCache then
                        Weather.ClearCache()
                    end
                    
                    -- Reset initial weather flag (done in tick loop, but also here for safety)
                    initialWeatherApplied = false
                end
            end
        end)
        Log.Info("Main", "EndPlay hook registered")
    end)
    
    if not endPlaySuccess then
        Log.Warn("Main", "Failed to register EndPlay hook: " .. tostring(endPlayErr))
    end
    
    return true
end

local function startMainLoop()
    Log.Info("Main", "Starting main loop...")
    
    -- Check if LoopAsync is available (UE4SS)
    if not LoopAsync then
        Log.Error("Main", "LoopAsync not available: cannot start main loop")
        return false
    end
    
    local loopSuccess, loopErr = pcall(function()
        LoopAsync(Config.MainLoop.TickIntervalMs, function()
            onTick()
            return false  -- Return false to continue loop
        end)
    end)
    
    if loopSuccess then
        Log.Info("Main", string.format("Main loop started (interval=%dms)", Config.MainLoop.TickIntervalMs))
        return true
    else
        Log.Error("Main", "Failed to start main loop: " .. tostring(loopErr))
        return false
    end
end

-- ============== INITIALIZATION ==============

local function initialize()
    Log.Info("Main", "Initializing mod...")
    
    -- Load system modules
    loadSystemModules()

    -- ===== PER-MODULE TOGGLES =====
    -- Setting a Config.ModuleToggles.X to false nil-s that module's handle, so every
    -- `if X and X.Tick`/`X.Setup` guard in the loop skips it entirely, disabling the
    -- module's runtime without touching call sites. All true = normal operation.
    -- Actors/Presets/Keybinds are core and intentionally not toggleable here.
    local tg = Config.ModuleToggles
    if tg then
        if tg.Weather     == false then Weather = nil end
        if tg.Scheduler   == false then Scheduler = nil end
        if tg.TimeOfDay   == false then TimeOfDay = nil end
        if tg.CloudsFog   == false then CloudsFog = nil end
        if tg.Shadows     == false then Shadows = nil end
        if tg.Transitions == false then Transitions = nil end
        if tg.Atmosphere  == false then Atmosphere = nil end
        if tg.Headlights  == false then Headlights = nil end
        if tg.Audio       == false then Audio = nil end
        if tg.WindDebris  == false then WindDebris = nil end
        if tg.LightRays   == false then LightRays = nil end
        if tg.Moon        == false then Moon = nil end
        if tg.Stars       == false then Stars = nil end
        if tg.Rainbow     == false then Rainbow = nil end
        if tg.SpaceLayer  == false then SpaceLayer = nil end
        if tg.CinematicSky== false then CinematicSky = nil end
        if tg.LightCycle  == false then LightCycle = nil end
        if tg.Tunnels     == false then Tunnels = nil end
        if tg.RealSun     == false then RealSun = nil end
        if tg.Vignette    == false then Vignette = nil end
        if tg.PhotoMode   == false then PhotoMode = nil end
        if tg.WetGrip     == false then WetGrip = nil end
        if tg.Tuning      == false then Tuning = nil end
        if tg.Persistence == false then Persistence = nil end
        Log.Info("Main", "Module toggles applied", {
            Weather = Weather ~= nil, TimeOfDay = TimeOfDay ~= nil,
            CloudsFog = CloudsFog ~= nil, Shadows = Shadows ~= nil,
            Transitions = Transitions ~= nil, Atmosphere = Atmosphere ~= nil,
            Headlights = Headlights ~= nil, Audio = Audio ~= nil,
            Stars = Stars ~= nil, Persistence = Persistence ~= nil,
        })
    end

    -- Set up UE4SS hooks
    setupHooks()
    
    -- Initialize keybinds
    if Keybinds and Keybinds.Init then
        Keybinds.Init(Config.Keybinds)
    end
    
    -- Load persisted state
    if Persistence and Persistence.Load then
        local savedState = Persistence.Load()
        if savedState and State then
            State.Import(savedState)
            Log.Info("Main", "Restored saved state")
        end
    end
    
    -- Start main loop
    local loopStarted = startMainLoop()
    
    -- Log initialization complete
    local moduleStatus = State and State.GetAllModuleStatuses() or {}
    local loadedCount = 0
    for _, v in pairs(moduleStatus) do
        if v then loadedCount = loadedCount + 1 end
    end
    
    Log.Info("Main", string.format("Initialization complete (%d modules loaded, loop %s)", 
        loadedCount,
        loopStarted and "running" or "NOT started"))
    
    return true
end

-- ============== RUN ==============

-- Run initialization
local initSuccess, initErr = pcall(initialize)
if not initSuccess then
    Log.Error("Main", "Initialization failed: " .. tostring(initErr))
end

-- ============== GLOBAL LIFECYCLE HOOKS (V1.34 style) ==============
-- These must be at global scope, not inside functions

-- Track world context for PA transitions
local _LastWorldTag = "unknown"
-- (_CourseStateBeforePA is declared above the main loop; applyPAState
-- captures it as an upvalue)
local _WorldLogPending = true       -- one-shot "World identify" log per map load (PA-name hunt)

-- LoadMapPreHook: fires BEFORE map unload while actors still valid
if RegisterLoadMapPreHook then
    RegisterLoadMapPreHook(function()
        -- Old world is about to die: stop the async actor search from touching
        -- the object array until the new world's sky actor begins play
        if Actors and Actors.SuspendDiscovery then
            Actors.SuspendDiscovery()
        end

        -- Get world tag from Actors module (or State), NOT a local variable
        local currentTag = "unknown"
        if Actors and Actors.GetWorldTag then
            currentTag = Actors.GetWorldTag()
        elseif State and State.GetWorldContext then
            currentTag = State.GetWorldContext()
        end
        
        if Log then Log.Info("Main", "LoadMapPreHook: Map unloading, tag=" .. tostring(currentTag)) end
        
        -- Capture course state while actors still valid
        -- Try to capture regardless of tag if we have valid actors
        local uds = Actors and Actors.GetUDS()
        local udw = Actors and Actors.GetUDW()
        
        local udsValid = false
        local udwValid = false
        pcall(function() udsValid = uds and uds.IsValid and uds:IsValid() end)
        pcall(function() udwValid = udw and udw.IsValid and udw:IsValid() end)
        
        if udsValid and udwValid then
            local tod, cloud, fog = -1, -1, -1
            pcall(function() tod = uds["Time Of Day"] end)
            pcall(function() cloud = udw["Cloud Coverage"] end)
            pcall(function() fog = udw["Fog"] end)
            
            local speed = State and State.GetTimeSpeed() or 53.333
            local preset = State and State.GetCurrentPreset() or "Clear_Skies"
            
            -- Only save if we got valid values
            if tod >= 0 and tod <= 2400 then
                _CourseStateBeforePA = {
                    tod = tod, cloud = cloud, fog = fog,
                    speed = speed, preset = preset
                }
                
                -- Also save to State module
                if State and State.CaptureForPA then
                    State.CaptureForPA(tod, cloud, fog, speed, preset)
                end
                
                if Log then Log.Info("Main", string.format("Captured pre-PA: TOD=%.2f cloud=%.2f fog=%.2f preset=%s", 
                    tod, cloud or -1, fog or -1, preset or "?")) end
            else
                if Log then Log.Warn("Main", string.format("Invalid TOD on unload: %.2f", tod or -1)) end
            end
        else
            if Log then Log.Debug("Main", "No valid actors on unload: cannot capture state") end
        end
        
        -- Save persistence if on course
        if currentTag == "course" and Persistence and Persistence.Save then
            Persistence.Save("map_unload_pre")
        end
        
        _LastWorldTag = currentTag
        _WorldLogPending = true
    end)
end

-- Sky class caching like V1.34
local SkyClass = nil
local CourseSkyClass = nil

local function TryGetSkyClass()
    if SkyClass then
        local valid = false
        pcall(function() valid = SkyClass:IsValid() end)
        if valid then return SkyClass end
    end
    pcall(function()
        SkyClass = StaticFindObject('/Game/ITSB/ArtAssets/Models/Course/ACOMMON/Sky/BP_Sky.BP_Sky_C')
    end)
    return SkyClass
end

local function TryGetCourseSkyClass()
    if CourseSkyClass then
        local valid = false
        pcall(function() valid = CourseSkyClass:IsValid() end)
        if valid then return CourseSkyClass end
    end
    pcall(function()
        CourseSkyClass = StaticFindObject('/Game/ITSB/ArtAssets/Models/Course/ACOMMON/Sky/BP_CourseSky.BP_CourseSky_C')
    end)
    return CourseSkyClass
end

-- BeginPlayPreHook: fires when new actors begin play
if RegisterBeginPlayPreHook then
    RegisterBeginPlayPreHook(function(ActorParam)
        -- Get actor
        local Actor = nil
        pcall(function() Actor = ActorParam and ActorParam:get() end)
        if not Actor then return end
        
        -- Check validity
        local isValid = false
        pcall(function() isValid = Actor.IsValid and Actor:IsValid() end)
        if not isValid then return end
        
        -- Cheap NAME check first: one GetFullName per actor. The old order ran
        -- TryGetSkyClass() for EVERY actor beginning play, which revalidates a
        -- CACHED CLASS OBJECT with IsValid(); during a world swap the previous
        -- world's GC can have freed that class, making the revalidation a
        -- freed-memory read, matching the intermittent transition-crash
        -- signature (read AV in a game-thread hook, transitions only). The
        -- class-cache route now runs only as a fallback when the name read gives
        -- nothing usable, instead of hundreds of times per map load.
        -- NOT tostring(Actor): UE4SS's __tostring returns the userdata address
        -- ("...Userdata: 0x..."), never the object name; the 3.3.0 tostring
        -- version made isSky never match, so discovery only ever resumed via
        -- the 15s failsafe (the "TOD takes ~15s to snap in after a load"
        -- symptom). GetFullName on the live hook param is safe: this actor is
        -- spawning in the NEW world, not a cached cross-world reference.
        local actorName = nil
        pcall(function()
            if Actor.GetFullName then actorName = Actor:GetFullName() end
        end)

        -- One-shot per map load: log the first NAMED actor's world, so worlds
        -- whose sky never matches the patterns below (PA? menus?) are still
        -- identifiable from the log. Same safe pattern as the sky path: live
        -- spawning actor, GetWorld+GetFullName once per load.
        if _WorldLogPending and type(actorName) == "string" and #actorName > 0 then
            _WorldLogPending = false
            pcall(function()
                local w = Actor:GetWorld()
                if w and w.IsValid and w:IsValid() then
                    local ws = w:GetFullName()
                    if type(ws) == "string" and #ws > 0 and Log then
                        Log.Info("Main", string.format("World identify: %s (first actor: %s)",
                            ws:sub(1, 120), actorName:sub(1, 100)))
                    end
                end
            end)
        end

        local isSky = false
        if type(actorName) == "string" and #actorName > 0 then
            isSky = (actorName:find("UltraDynamicSky")
                  or actorName:find("Ultra_Dynamic_Sky")
                  or actorName:find("CourseSky")
                  or actorName:find("BP_Sky")) ~= nil
        else
            local skyCls = TryGetSkyClass()
            local courseCls = TryGetCourseSkyClass()
            if skyCls then
                pcall(function() isSky = Actor:IsA(skyCls) end)
            end
            if not isSky and courseCls then
                pcall(function() isSky = Actor:IsA(courseCls) end)
            end
        end

        if not isSky then
            -- Garage/menu worlds have NO sky actor, so the sky-based resume
            -- below never fires there and the teardown suspension always sat
            -- out the full 15s failsafe. While suspended the garage probe is
            -- cache-only, so the exposure garage branch could not fire either:
            -- the garage ran ~15s on the previous course's cvars (after a dusk
            -- course that is sky=0.1 = a very dark garage). The outgame
            -- managers begin play early in those worlds; use them as the
            -- resume signal.
            if type(actorName) == "string"
               and (actorName:find("OutGameGarageManager") or actorName:find("OutGameMode"))
               and Actors and Actors.IsDiscoverySuspended and Actors.IsDiscoverySuspended()
               and Actors.ResumeDiscovery then
                Actors.ResumeDiscovery()
            end
            return
        end

        -- A sky actor is beginning play: the new world is constructing, so the
        -- teardown window is over; let the actor search run again
        if Actors and Actors.ResumeDiscovery then
            Actors.ResumeDiscovery()
        end

        -- Get world tag from actor. GetFullName, NOT tostring: tostring(world)
        -- is just "UWorld: 0x..." (the address, no map path), which made every
        -- world tag as the "course" default; the PA branch below never fired.
        local tag = "course"
        local worldString = "unknown"
        pcall(function()
            local worldObj = Actor:GetWorld()
            if worldObj and worldObj.IsValid and worldObj:IsValid() then
                local ws = worldObj:GetFullName()
                if type(ws) ~= "string" or #ws == 0 then return end
                worldString = ws  -- Capture for logging
                local lw = ws:lower()
                -- NOTE: there is NO separate "pa" world; the PA scene lives
                -- inside the outgame world (L_OutGame_P) and is handled by
                -- the tick loop's PA lifecycle (Actors.IsInPAScene).
                if lw:find("garage") or lw:find("outgame") or lw:find("ls_") then
                    tag = "outgame"
                end
            end
        end)
        
        if Log then Log.Info("Main", string.format("BeginPlayPreHook: worldString=%s tag=%s (was %s)",
            worldString:sub(1,80), tag, _LastWorldTag)) end
        
        -- PA handling moved to the tick loop's PA lifecycle (applyPAState):
        -- the old tag=="pa" branch here was DEAD: no world path ever matched,
        -- the PA scene is part of the outgame world. Course return: don't
        -- restore here; the tick loop's Persistence.Restore() handles it.
        if tag == "course" and _pendingRestore then
            if Log then Log.Info("Main", "Course entry: deferring restore to tick loop") end
            _pendingRestore = false
            -- restoredFromPA stays false so tick loop will call Persistence.Restore()
        end
        
        _LastWorldTag = tag
        
        -- Update State module
        if State and State.SetWorldContext then State.SetWorldContext(tag) end
    end)
end

-- Export for external access if needed
return {
    Config = Config,
    Log = Log,
    Utils = Utils,
    State = State,
    Actors = Actors,
    Presets = Presets,
    Weather = Weather,
    TimeOfDay = TimeOfDay,
    Keybinds = Keybinds,
    Persistence = Persistence,
    CloudsFog = CloudsFog,
    Lightning = Lightning,
    EnhancedFog = EnhancedFog,
    Wetness = Wetness,
    Shadows = Shadows,
    Transitions = Transitions,
    Atmosphere = Atmosphere,
    Headlights = Headlights,
    Audio = Audio,
    Stars = Stars,
    LightCycle = LightCycle,
    Tunnels = Tunnels,
    Rainbow = Rainbow,
    SpaceLayer = SpaceLayer,
    CinematicSky = CinematicSky,
    RealSun = RealSun,
    Vignette = Vignette,
    PhotoMode = PhotoMode,
    WetGrip = WetGrip,
    Tuning = Tuning,
}
