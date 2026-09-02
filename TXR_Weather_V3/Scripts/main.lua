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
local GT = safeRequire("core.gt", "GT")
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
-- State is required: the tick loop calls it unguarded (the PA-frozen and
-- photo-session gates), so a missing module would error on every tick.
local State = safeRequire("core.state", "State")
if not State then
    error("Cannot continue without State module")
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
local Shadows = nil
local Transitions = nil
local Atmosphere = nil
local Headlights = nil
local Audio = nil
local Stars = nil
local LightCycle = nil
local Tunnels = nil
local GapWalls = nil
local SlabEditor = nil
local RainCollision = nil
local WindDebris = nil
local LightRays = nil
local Moon = nil
local Rainbow = nil
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

    GapWalls = safeRequire("systems.gap_walls", "GapWalls")
    if GapWalls then
        Log.Info("Main", "System module loaded: GapWalls")
        if GapWalls.Init then GapWalls.Init() end
    else
        Log.Debug("Main", "GapWalls module not loaded")
    end

    -- Dev-only: release builds omit systems/slab_editor.lua entirely,
    -- so this stays nil and no editor keys or ticks exist.
    SlabEditor = safeRequire("systems.slab_editor", "SlabEditor")
    if SlabEditor then
        Log.Info("Main", "System module loaded: SlabEditor (dev build)")
        if SlabEditor.Init then SlabEditor.Init() end
    end

    -- Weather audio (rain/wind/thunder loops; restored for 3.8.0)
    Audio = safeRequire("systems.audio", "Audio")
    if Audio then
        Log.Info("Main", "System module loaded: Audio")
        if Audio.Init then Audio.Init() end
    else
        Log.Debug("Main", "Audio module not loaded")
    end

    -- Rain collision: targeted rain-solid stealth bodies on tunnel and
    -- bridge meshes (see Config.RainCollision)
    RainCollision = safeRequire("systems.rain_collision", "RainCollision")
    if RainCollision then
        Log.Info("Main", "System module loaded: RainCollision")
        if RainCollision.Init then RainCollision.Init() end
    else
        Log.Debug("Main", "RainCollision module not loaded")
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

end

-- ============== MAIN LOOP ==============

local lastHeartbeat = os.time()
local tickCount = 0
local initialWeatherApplied = false  -- Track if we've applied initial weather this session
local _pendingRestore = false        -- Flag set when actors become invalid, triggers restore on next valid
local _actorsLostTicks = 0           -- consecutive ticks with actors missing (blip debounce)
local _mapTeardownPending = false    -- set only by LoadMapPreHook: cascade instantly
local ACTORS_LOST_CASCADE_TICKS = 16 -- ~2s at 125ms; photomode/churn blips re-find in ~1s

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
-- on map unload. Declared here so applyPAState captures it as an upvalue
-- (declared further down it would silently become a global).
local _CourseStateBeforePA = nil

-- PA weather (Config.PA.Mode, canon 2026-07-09): the PA scene lives in the
-- same outgame world as the garage but has its own working UDS/UDW (canned:
-- always night, TOD 1950 / cloud 7.5 / fog 3.0). Discovery succeeding in an
-- outgame world = PA; the garage's UDS never validates. "continue" carries
-- the captured course weather/time in and keeps the clock at the captured
-- course speed, "freeze" carries then freezes time (the V1.32 behavior),
-- "stock" leaves the canned night alone.
local paStateApplied = false
local paCarry = nil        -- carried cloud/fog for the delayed re-assert
local paReassertAt = nil   -- os.clock() deadline for it (nil = none due)
local paClockLast = nil    -- {tod, clock}: last agreed PA clock reading
local paClockNext = 0.0    -- next clock-watch poll (throttle)
local PA_CANNED_TOD = 1950 -- the PA scene's canned night clock (see above)
local PA_CANNED_TOL = 5    -- "landed on the canned TOD" tolerance, units

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
        if (not cloud or cloud < 0) and cap.cloud and cap.cloud >= 0 then cloud = cap.cloud end
        -- fog < 0 is the save/capture "read failed" sentinel, same as cloud
        if (fog == nil or fog < 0) and cap.fog ~= nil and cap.fog >= 0 then fog = cap.fog end
        if preset == nil and cap.preset then preset = cap.preset end
        if speed == nil and cap.speed then speed = cap.speed end
    end

    -- Preset first (field 2026-07-15 23:35): Weather.Apply re-applies the
    -- preset's own cloud/fog baselines immediately, so a carry written before
    -- it lost every time ("PA state applied but nothing visibly takes").
    -- Preset for rain/effects, then the carried sky state on top.
    if preset and Weather and Weather.Apply then
        pcall(function() Weather.Apply(preset, 0) end)
    end

    if tod and tod >= 0 and tod <= 2400 then
        pcall(function() uds["Time Of Day"] = tod end)
        paClockLast = { tod = tod, clock = os.clock() }  -- seed the clock watch
    end
    if udw then
        if cloud and cloud >= 0 then
            pcall(function() udw["Cloud Coverage - Manual Override"] = true end)
            pcall(function() udw["Cloud Coverage"] = cloud end)
        end
        if fog ~= nil and fog >= 0 then
            pcall(function() udw["Fog - Manual Override"] = true end)
            pcall(function() udw["Fog"] = fog end)
        end
    end

    -- One-shot delayed re-assert (~2s, see the PA lifecycle block): UDW's own
    -- pushes right after an apply can revert the carried pair; the re-assert
    -- logs what the first write left behind.
    if (cloud and cloud >= 0) or (fog ~= nil and fog >= 0) then
        paCarry = { cloud = cloud, fog = fog }
        paReassertAt = os.clock() + 2.0
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
        -- Config.PA.ForceNormalSpeed caps a carried Alt+T fast-forward back to
        -- normal speed (it would race the clock while you sit in a menu).
        if Config.PA and Config.PA.ForceNormalSpeed then
            local normal = (Config.TimeOfDay and Config.TimeOfDay.DefaultSpeed) or 53.333
            if spd and spd > normal then spd = normal end
        end
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
    if GapWalls and GapWalls.OnCourseLoad then
        GapWalls.OnCourseLoad()
    end
    if SlabEditor and SlabEditor.OnCourseLoad then
        SlabEditor.OnCourseLoad()
    end
    if RainCollision and RainCollision.OnCourseLoad then
        RainCollision.OnCourseLoad()
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

--- PA continue-mode clock watch (~1s poll): the PA scene re-cans its clock
--- after the carry (field 2026-07-16 00:18: TOD teleported to the canned
--- 1950 about a minute after the bind), so a write-once carry cannot hold.
--- Each poll predicts the carried clock (last agreed reading + elapsed at
--- the live simulation speed; speed/40 units per second, 53.333 = 2400 per
--- 30 min) and snaps back + re-asserts the speed when the clock has
--- teleported (>100 units off the prediction). Alt+T speed changes stay
--- under the threshold because the prediction reads the live speed every poll.
local function paClockWatchTick()
    local now = os.clock()
    if now < paClockNext then return end
    paClockNext = now + 1.0

    local uds = Actors and Actors.GetUDS and Actors.GetUDS()
    if not uds then return end
    local tod, spd = nil, nil
    pcall(function() tod = tonumber(uds["Time Of Day"]) end)
    if tod == nil then return end
    pcall(function() spd = tonumber(uds["Simulation Speed"]) end)

    if not paClockLast then
        paClockLast = { tod = tod, clock = now }
        return
    end

    local predicted = (paClockLast.tod
        + (now - paClockLast.clock) * ((spd or 0) / 40.0)) % 2400
    local diff = math.abs(tod - predicted)
    if diff > 1200 then diff = 2400 - diff end  -- shortest way around midnight

    -- Re-can signature (field 2026-08-07: a dusk carry ~1800-1900 sits
    -- inside the 100-unit window of the canned 1950, so the re-can passed as
    -- truth and the watch synced to the canned night): a jump off the
    -- prediction that lands on the canned TOD is a re-can regardless of
    -- size. The 15-unit floor keeps prediction drift and the legitimate
    -- nightly pass through 1950 (prediction in tow, diff ~1-2) from misfiring.
    local canned = math.abs(tod - PA_CANNED_TOD)
    if canned > 1200 then canned = 2400 - canned end
    local recanned = (canned <= PA_CANNED_TOL) and (diff > 15)

    if diff > 100 or recanned then
        -- The scene re-canned the clock; restore the carried timeline and
        -- re-assert the running speed (the canned push can zero it too)
        local speed = State and State.GetTimeSpeed and State.GetTimeSpeed() or nil
        if Config.PA and Config.PA.ForceNormalSpeed then
            local normal = (Config.TimeOfDay and Config.TimeOfDay.DefaultSpeed) or 53.333
            if speed and speed > normal then speed = normal end
        end
        pcall(function() uds["Time Of Day"] = predicted end)
        pcall(function() uds["Animate Time of Day"] = true end)
        if speed and speed > 0 then
            pcall(function() uds["Time Speed"] = 1.0 end)
            pcall(function() uds["Simulation Speed"] = speed end)
        end
        Log.Info("Main", "PA clock re-synced (scene re-canned it)", {
            was = string.format("%.0f", tod),
            restored = string.format("%.0f", predicted),
            trigger = recanned and "canned-signature" or "threshold",
        })
        paClockLast = { tod = predicted, clock = now }
    else
        -- Speed-only revert (field 2026-08-04, "PA runs at a different
        -- timescale"): the canned push can reset Simulation Speed to the
        -- spawn default (~1.0, a real-time crawl) without teleporting the
        -- clock, and the prediction reads the live speed, so the position
        -- check above never trips (the PA then runs ~53x slower forever).
        -- Enforce the carried speed independently of clock position.
        local want = State and State.GetTimeSpeed and State.GetTimeSpeed() or nil
        if Config.PA and Config.PA.ForceNormalSpeed then
            local normal = (Config.TimeOfDay and Config.TimeOfDay.DefaultSpeed) or 53.333
            if want and want > normal then want = normal end
        end
        if want and want > 0
           and (spd == nil or math.abs(spd - want) > want * 0.1) then
            pcall(function() uds["Animate Time of Day"] = true end)
            pcall(function() uds["Time Speed"] = 1.0 end)
            pcall(function() uds["Simulation Speed"] = want end)
            Log.Info("Main", "PA speed re-asserted (canned push reverted it)", {
                was = tostring(spd), want = string.format("%.1f", want),
            })
        end
        paClockLast = { tod = tod, clock = now }
    end
end

-- GT pump watchdog (2026-08-21): UE4SS can silently remove its engine-tick
-- Lua hook after a "[Lua::Registry::get_function_ref] Ref was not function"
-- error (upstream #346, multi-mod hook collision), killing every
-- ExecuteInGameThread marshal for the session (photomode edge toggles,
-- pulse reverts, cvar batches, dark garage) while the async side keeps
-- running (field 2026-08-20 23:50:31). Beat a trivial GT closure every
-- 10s; no beat for 60s = pump dead: flag State and warn. Beats pause while
-- dead; a late beat landing flips it back.
local gtPumpLastBeat = nil
local gtPumpNextSend = 0.0
local gtPumpWarnedAt = nil
local function gtPumpWatch()
    local now = os.clock()
    if gtPumpLastBeat == nil then gtPumpLastBeat = now end
    local dead = (now - gtPumpLastBeat) > 60.0
    if not dead and now >= gtPumpNextSend and ExecuteInGameThread then
        gtPumpNextSend = now + 10.0
        -- the beat rides the single-flight queue, verifying the whole
        -- marshal path (queue, pump, drain), not just raw EIGT
        if GT and GT.Run then
            GT.Run(function() gtPumpLastBeat = os.clock() end)
        end
    end
    if dead then
        if State and State.SetGTPumpAlive then State.SetGTPumpAlive(false) end
        if gtPumpWarnedAt == nil or (now - gtPumpWarnedAt) > 300.0 then
            gtPumpWarnedAt = now
            Log.Warn("Main", "GAME-THREAD PUMP DEAD: UE4SS removed its"
                .. " engine-tick hook (registry bug, upstream #346)."
                .. " Marshalled features are inert (photomode auto-open,"
                .. " pulse revert, cvar batches, dark garage)."
                .. " RESTART THE GAME to restore them.")
        end
    else
        if State and State.SetGTPumpAlive then State.SetGTPumpAlive(true) end
        gtPumpWarnedAt = nil
    end
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

        -- GT pump watchdog (self-paced inside)
        gtPumpWatch()

        -- Single-flight marshal pump: drains everything queued via
        -- GT.Run/GT.After onto the game thread, one action at a time
        if GT and GT.PumpTick then
            GT.PumpTick()
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

        -- Phase 11: Random weather scheduler (skip in PA; skip during a
        -- photo session, 2026-08-07 field: a scheduler pick's transition
        -- kept mutating the sky mid-shoot while TOD stood frozen)
        if Scheduler and Scheduler.Tick and not State.IsPAFrozen()
           and not (State.IsPhotoSessionOpen and State.IsPhotoSessionOpen()) then
            Scheduler.Tick()
        end
        
        -- Apply initial settings once actors are discovered (not in PA). Every
        -- course entry, PA returns included, takes this path; Persistence.Restore
        -- reads the PA-exit save, which keeps the clock continuous.
        if not initialWeatherApplied and Actors and Actors.IsOnCourse() and not State.IsPAFrozen() then
            do
                Log.Info("Main", "Actors ready: triggering initial setup")

                -- Sun simulation first, before anything writes Time Of Day: with
                -- Simulate Real Sun the sun position depends on the date, and
                -- landing the pinned date 4-5 s later (real_sun's own settle
                -- gate) made the first rendered sky use the drifting calendar
                -- and snap across the horizon at a dusk TOD. Marshalled inside,
                -- so the date write and Hard Reset Cache land on the game thread
                -- after the async TOD restore below has run.
                if RealSun and RealSun.OnCourseLoad then
                    RealSun.OnCourseLoad()
                end

                -- No UDW warmup here: the ClientRestart hook (weather.lua) does
                -- it at course entry, before this block. A warmup queued from
                -- here as a GT closure landed after the synchronous
                -- restore/apply below (re-asserting Enable*Particles after a
                -- dry apply, warming mid-transition on a wet one: the recorded
                -- AV class). Removed 2026-08-04; the hook alone is the verified
                -- fix (2026-07-31, CCC disabled).

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
                
                -- Initialize audio (weather sounds; restored for 3.8.0)
                if Audio and Audio.Setup then
                    Audio.Setup()
                end

                -- Apply HD stars (night sky)
                if Stars and Stars.Setup then
                    Stars.Setup()
                end

                -- Fresh course, fresh photo-freeze latch: TimeOfDay's own reset
                -- runs only when restore fails (the rare path), so a stranded
                -- latch would silently disable the next shoot's freeze. Never
                -- mid-photo-session: the blip re-init lands with the session open.
                if TimeOfDay and TimeOfDay.ResetPhotoFreeze
                    and not (State.IsPhotoSessionOpen and State.IsPhotoSessionOpen()) then
                    TimeOfDay.ResetPhotoFreeze()
                end

                -- Force exposure to re-apply its slot (map load may reset CVARs)
                if LightCycle and LightCycle.OnCourseLoad then
                    LightCycle.OnCourseLoad()
                end
                if Tunnels and Tunnels.OnCourseLoad then
                    Tunnels.OnCourseLoad()
                end
                if GapWalls and GapWalls.OnCourseLoad then
                    GapWalls.OnCourseLoad()
                end
                if SlabEditor and SlabEditor.OnCourseLoad then
                    SlabEditor.OnCourseLoad()
                end
                if RainCollision and RainCollision.OnCourseLoad then
                    RainCollision.OnCourseLoad()
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
            elseif paStateApplied and paReassertAt and os.clock() >= paReassertAt then
                -- Delayed carry re-assert: log what the first write left (was_*
                -- at the preset's values = something reverted it after
                -- Weather.Apply; at the carried values = it held and this
                -- re-write is a no-op), then write the carried pair again.
                paReassertAt = nil
                local c = paCarry
                paCarry = nil
                local udw = Actors and Actors.GetUDW and Actors.GetUDW()
                if udw and c then
                    local wasCloud, wasFog = nil, nil
                    pcall(function() wasCloud = tonumber(udw["Cloud Coverage"]) end)
                    pcall(function() wasFog = tonumber(udw["Fog"]) end)
                    if c.cloud and c.cloud >= 0 then
                        pcall(function() udw["Cloud Coverage - Manual Override"] = true end)
                        pcall(function() udw["Cloud Coverage"] = c.cloud end)
                    end
                    if c.fog ~= nil and c.fog >= 0 then
                        pcall(function() udw["Fog - Manual Override"] = true end)
                        pcall(function() udw["Fog"] = c.fog end)
                    end
                    Log.Info("Main", "PA carry re-assert", {
                        was_cloud = wasCloud or -1, was_fog = wasFog or -1,
                        cloud = c.cloud or -1, fog = c.fog or -1,
                    })
                end
            elseif paStateApplied and Actors and not Actors.HasActors() then
                paStateApplied = false
                paCarry, paReassertAt = nil, nil
                paClockLast, paClockNext = nil, 0.0
                if State and State.IsPAFrozen and State.IsPAFrozen() then
                    State.SetPAFrozen(false)
                end
                if LightCycle and LightCycle.OnCourseUnload then
                    LightCycle.OnCourseUnload()   -- disarm; the PA actors are gone
                end
                -- A covered PA spot engages the fog damp; without this reset a
                -- stale 0.0 rides into the next course's first weather apply
                -- (which runs before OnCourseLoad's resets).
                if EnhancedFog and EnhancedFog.OnCourseUnload then
                    EnhancedFog.OnCourseUnload()
                end
                if Tunnels and Tunnels.OnCourseUnload then
                    Tunnels.OnCourseUnload()
                end
                if GapWalls and GapWalls.OnCourseUnload then
                    GapWalls.OnCourseUnload()
                end
                if SlabEditor and SlabEditor.OnCourseUnload then
                    SlabEditor.OnCourseUnload()
                end
                if RainCollision and RainCollision.OnCourseUnload then
                    RainCollision.OnCourseUnload()
                end
                if CinematicSky and CinematicSky.OnCourseUnload then
                    CinematicSky.OnCourseUnload()
                end
                if Audio and Audio.OnCourseUnload then
                    Audio.OnCourseUnload()
                end
                if Stars and Stars.OnCourseUnload then Stars.OnCourseUnload() end
                if Moon and Moon.OnCourseUnload then Moon.OnCourseUnload() end
                if Rainbow and Rainbow.OnCourseUnload then Rainbow.OnCourseUnload() end
                if WindDebris and WindDebris.OnCourseUnload then WindDebris.OnCourseUnload() end
                if LightRays and LightRays.OnCourseUnload then LightRays.OnCourseUnload() end
                if RealSun and RealSun.OnCourseUnload then RealSun.OnCourseUnload() end
                Log.Info("Main", "PA state cleared (actors lost)")
            end
            -- Continue-mode clock watch (freeze mode has its own watchdog)
            if paStateApplied and not State.IsPAFrozen() then
                paClockWatchTick()
            end
        end

        -- Course-exit cascade with blip debounce (2026-08-31): photomode opens
        -- and ClientRestart churn invalidate the sky for ~1s and rediscovery
        -- lands moments later at a new address. Cascading on the first missing
        -- tick respawned every gap slab and re-ran the whole weather/light
        -- init per blip (19 blips and 1458 slab spawns on 08-31 alone: the
        -- reported lag, the editor 0-slab wipes, spawn-detour crash exposure).
        -- A real teardown cascades instantly via the LoadMapPreHook flag;
        -- anything else must stay missing ~2s, never mid-photo-session.
        if initialWeatherApplied and Actors and not Actors.HasActors() then
            _actorsLostTicks = _actorsLostTicks + 1
            local photoOpen = State.IsPhotoSessionOpen and State.IsPhotoSessionOpen()
            if _mapTeardownPending
                or (_actorsLostTicks >= ACTORS_LOST_CASCADE_TICKS and not photoOpen) then
                _mapTeardownPending = false
                _actorsLostTicks = 0
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
                if GapWalls and GapWalls.OnCourseUnload then
                    GapWalls.OnCourseUnload()
                end
                if SlabEditor and SlabEditor.OnCourseUnload then
                    SlabEditor.OnCourseUnload()
                end
                if RainCollision and RainCollision.OnCourseUnload then
                    RainCollision.OnCourseUnload()
                end
                -- Drop the per-course stock cache behind the cinematic
                -- multipliers (a blip re-apply must not scale twice)
                if CinematicSky and CinematicSky.OnCourseUnload then
                    CinematicSky.OnCourseUnload()
                end
                -- Re-arm the audio settle sequence and drop its loop refs
                -- (no object touches: the components die with the world)
                if Audio and Audio.OnCourseUnload then
                    Audio.OnCourseUnload()
                end
                -- The settle-gated one-shots re-arm here, not on the raw
                -- actor flicker: a photomode open used to re-run their bakes
                if Stars and Stars.OnCourseUnload then Stars.OnCourseUnload() end
                if Moon and Moon.OnCourseUnload then Moon.OnCourseUnload() end
                if Rainbow and Rainbow.OnCourseUnload then Rainbow.OnCourseUnload() end
                if WindDebris and WindDebris.OnCourseUnload then WindDebris.OnCourseUnload() end
                if LightRays and LightRays.OnCourseUnload then LightRays.OnCourseUnload() end
                if RealSun and RealSun.OnCourseUnload then RealSun.OnCourseUnload() end
                initialWeatherApplied = false
                _pendingRestore = true  -- Signal to restore on next actor detection
                Log.Info("Main", "Actors lost: pending restore on next detection")
            end
        elseif _actorsLostTicks > 0 or _mapTeardownPending then
            if _actorsLostTicks > 0 and initialWeatherApplied then
                Log.Info("Main", "Actors blip absorbed (no cascade)", {
                    ticks = _actorsLostTicks,
                })
            end
            _actorsLostTicks = 0
            _mapTeardownPending = false
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
        
        -- Dynamic wet grip (self-throttled, re-applies only on change). Not
        -- PA-frozen-gated on purpose: a race started from PA is the case it is
        -- for, and it only scales tire grip rates, never the PA-persisted
        -- weather state, so running through the PA transition is safe.
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
        
        -- Headlights (auto on/off keyed on sun elevation, see Config.Headlights)
        if Headlights and Headlights.Tick and not State.IsPAFrozen() then
            Headlights.Tick()
        end

        -- Stars (settle-gated apply, deferred past BeginPlay)
        if Stars and Stars.Tick and not State.IsPAFrozen() then
            Stars.Tick()
        end

        -- Weather audio (rain/wind/thunder loops follow the weather state)
        if Audio and Audio.Tick and not State.IsPAFrozen() then
            Audio.Tick()
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

        -- Cinematic sky grade (settle-gated one-shot apply)
        if CinematicSky and CinematicSky.Tick and not State.IsPAFrozen() then
            CinematicSky.Tick()
        end

        -- Real sun probe/experiment (settle-gated one-shot)
        if RealSun and RealSun.Tick and not State.IsPAFrozen() then
            RealSun.Tick()
        end

        -- Vignette HUD toggle (throttled re-assert; runs in/out of course like the
        -- HUD itself, so intentionally not gated by the PA-frozen check)
        if Vignette and Vignette.Tick then
            Vignette.Tick()
        end

        -- Light cycle (exposure/look; also runs in garage/menu, so it is
        -- intentionally not gated by the PA-frozen check)
        if LightCycle and LightCycle.Tick then
            LightCycle.Tick()
        end

        -- Tunnels (covered-road rain kill; entered at the full tick rate and
        -- self-paced inside, so portal reactions stay at the 0.25s budget)
        if Tunnels and Tunnels.Tick then
            Tunnels.Tick()
        end

        -- Gap shadow walls (leak-fix slabs + tuner; self-paced inside)
        if GapWalls and GapWalls.Tick then
            GapWalls.Tick()
        end

        if SlabEditor and SlabEditor.Tick then
            SlabEditor.Tick()
        end

        -- Rain collision (channel enforcement + streamed-cell re-pass;
        -- self-paced inside, near-free while dry)
        if RainCollision and RainCollision.Tick then
            RainCollision.Tick()
        end

        -- Tuning slider widening (the alignment menu lives in the garage, so
        -- like Exposure/Vignette it is not course- or PA-gated)
        if Tuning and Tuning.Tick then
            Tuning.Tick()
        end

        -- PhotoMode is not ticked here: it runs its own LoopAsync (started in
        -- PhotoMode.Init) so this shared tick cannot stall its re-assert.
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
    
    -- Note: LoadMapPreHook and BeginPlayPreHook are registered at global scope
    -- (end of file) to match V1.34's pattern.

    -- No ReceiveBeginPlay/ReceiveEndPlay fallback hooks (removed 2026-08-10):
    -- each was a Lua dispatch + GetFullName for every actor spawn/death and
    -- never detected anything (BeginPlayPreHook did all of it), and the 08-09
    -- dumps fault inside exactly that per-actor GT hook dispatch. The weather
    -- module's cached component list is dropped by Weather.OnMapTeardown
    -- (called from LoadMapPreHook) instead.

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
    -- Config.ModuleToggles.X = false nils that module's handle, so every
    -- `if X and X.Tick`/`X.Setup` guard skips it. Actors/Presets/Keybinds are
    -- core and not toggleable.
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
        if tg.WindDebris  == false then WindDebris = nil end
        if tg.LightRays   == false then LightRays = nil end
        if tg.Moon        == false then Moon = nil end
        if tg.Stars       == false then Stars = nil end
        if tg.Rainbow     == false then Rainbow = nil end
        if tg.CinematicSky== false then CinematicSky = nil end
        if tg.LightCycle  == false then LightCycle = nil end
        if tg.Tunnels     == false then Tunnels = nil end
        if tg.RainCollision == false then RainCollision = nil end
        if tg.RealSun     == false then RealSun = nil end
        if tg.Vignette    == false then Vignette = nil end
        if tg.PhotoMode   == false then PhotoMode = nil end
        if tg.WetGrip     == false then WetGrip = nil end
        if tg.Tuning      == false then Tuning = nil end
        if tg.Audio       == false then Audio = nil end
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
    
    -- Read the saved state file so the boot log shows what the next course
    -- entry will restore; Persistence.Restore applies it once the sky
    -- actors exist.
    if Persistence and Persistence.Load then
        Persistence.Load()
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

-- Sky class cache (V1.34 pattern). Declared above LoadMapPreHook
-- (2026-08-10): the teardown block nils them, and with the locals declared
-- after the hook those assignments would silently write globals (the
-- local-ordering trap). The TryGet* definitions stay below, next to the
-- BeginPlayPreHook that uses them.
local SkyClass = nil
local CourseSkyClass = nil

-- LoadMapPreHook: fires before map unload while actors are still valid
if RegisterLoadMapPreHook then
    RegisterLoadMapPreHook(function()
        -- Get world tag from Actors module (or State), not a local variable
        local currentTag = "unknown"
        if Actors and Actors.GetWorldTag then
            currentTag = Actors.GetWorldTag()
        elseif State and State.GetWorldContext then
            currentTag = State.GetWorldContext()
        end

        if Log then Log.Info("Main", "LoadMapPreHook: Map unloading, tag=" .. tostring(currentTag)) end

        -- Capture course state first: the PreHook runs on the game thread with
        -- the old world still alive, the last safe moment to read its UDS/UDW.
        -- The suspend + cache drop at the end of this hook must follow these reads.
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
        
        -- Save persistence on course or when leaving the PA (still before the
        -- cache drop, so the save reads live values). The PA leg keeps the
        -- clock in sync: time runs there in continue mode, and without this
        -- save the next course restores from an up-to-30s-stale autosave.
        local leavingPA = false
        pcall(function()
            leavingPA = Actors and Actors.IsInPAScene and Actors.IsInPAScene() or false
        end)
        if (currentTag == "course" or leavingPA) and Persistence and Persistence.Save then
            -- pcall: this hook body has no enclosing pcall, and an io error
            -- escaping into UE4SS hook machinery is the hook-death vector.
            pcall(function() Persistence.Save("map_unload_pre") end)
        end

        -- Last: stop the async actor search and drop every cached actor ref.
        -- A ref surviving the swap can falsely validate against freed memory
        -- and crash the next property read (2026-07-14 beta crash on the
        -- course to PA return; the dump held the previous course's UDS).
        if Actors and Actors.SuspendDiscovery then
            Actors.SuspendDiscovery()
        end
        -- Real-teardown signal for the actors-lost debounce: only this
        -- hook may trigger the instant unload cascade (blips never do).
        _mapTeardownPending = true
        -- Same rule for weather's cached precip-component list: drop the
        -- suppression state (no object touches) so the next Weather.Apply
        -- can't unhide dead old-world components.
        if Weather and Weather.OnMapTeardown then
            Weather.OnMapTeardown()
        end
        -- Gap walls take the real-teardown signal from here: the cascade
        -- alone can be a living-world sky loss, where the slabs must stay
        if GapWalls and GapWalls.OnMapTeardown then
            GapWalls.OnMapTeardown()
        end
        -- Sky-class cache: the BP class objects die with their world's GC, and
        -- TryGet*'s cross-world IsValid() revalidation is the +0x0C
        -- freed-object read every 08-09 dump faults on (2026-08-10 disasm).
        -- Pure Lua nils, GT-safe; TryGet* re-finds in the new world.
        SkyClass = nil
        CourseSkyClass = nil

        _LastWorldTag = currentTag
        _WorldLogPending = true
    end)
end

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
        
        -- Cheap name check first, one GetFullName per actor; the class-cache
        -- route is only the fallback when the name read gives nothing. Running
        -- TryGetSkyClass() for every actor revalidated a cached class object
        -- with IsValid() during world swaps, a freed-memory read matching the
        -- intermittent transition-crash signature (read AV in a game-thread
        -- hook). Not tostring(Actor): UE4SS's __tostring returns the userdata
        -- address, never the name (the 3.3.0 version made isSky never match,
        -- so discovery only resumed via the 15s failsafe: "TOD takes ~15s to
        -- snap in after a load"). GetFullName on the live hook param is safe:
        -- this actor spawns in the new world, no cached cross-world reference.
        local actorName = nil
        pcall(function()
            if Actor.GetFullName then actorName = Actor:GetFullName() end
        end)

        -- One-shot per map load: log the first named actor's world, so worlds
        -- whose sky never matches the patterns below stay identifiable from
        -- the log. Live spawning actor, GetWorld+GetFullName once per load.
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
            -- Garage/menu worlds have no sky actor, so the sky-based resume
            -- below never fires there and the suspension sat out the full 15s
            -- failsafe (cache-only garage probe, exposure garage branch blocked:
            -- ~15s on the previous course's cvars, sky=0.1 after a dusk course
            -- = a very dark garage). The outgame managers begin play early in
            -- those worlds and serve as the resume signal.
            if type(actorName) == "string"
               and (actorName:find("OutGameGarageManager") or actorName:find("OutGameMode"))
               and Actors then
                -- Event-driven outgame signal (2026-07-21 map-open crash fix):
                -- game-thread context with the actor in hand, so the async
                -- garage probe (FindFirstOf x2 every 1.5s) never runs there.
                if Actors.OnOutgameManagerBeginPlay then
                    Actors.OnOutgameManagerBeginPlay()
                end
                if State and State.SetWorldContext then State.SetWorldContext("outgame") end
                if Actors.IsDiscoverySuspended and Actors.IsDiscoverySuspended()
                   and Actors.ResumeDiscovery then
                    Actors.ResumeDiscovery()
                end
            end
            return
        end

        -- A sky actor is beginning play: the new world is constructing, so the
        -- teardown window is over; let the actor search run again
        if Actors and Actors.ResumeDiscovery then
            Actors.ResumeDiscovery()
        end

        -- World tag from the actor. GetFullName, not tostring: tostring(world)
        -- is "UWorld: 0x..." (no map path), which tagged every world "course".
        local tag = "course"
        local worldString = "unknown"
        pcall(function()
            local worldObj = Actor:GetWorld()
            if worldObj and worldObj.IsValid and worldObj:IsValid() then
                local ws = worldObj:GetFullName()
                if type(ws) ~= "string" or #ws == 0 then return end
                worldString = ws  -- Capture for logging
                local lw = ws:lower()
                -- No separate "pa" world: the PA scene lives inside the outgame
                -- world (L_OutGame_P); the tick loop's PA lifecycle handles it.
                if lw:find("garage") or lw:find("outgame") or lw:find("ls_") then
                    tag = "outgame"
                end
            end
        end)
        
        if Log then Log.Info("Main", string.format("BeginPlayPreHook: worldString=%s tag=%s (was %s)",
            worldString:sub(1,80), tag, _LastWorldTag)) end
        
        -- PA handling lives in the tick loop's PA lifecycle (applyPAState); no
        -- world path ever tags "pa". Course return: no restore here, the tick
        -- loop's Persistence.Restore() handles it.
        if tag == "course" and _pendingRestore then
            if Log then Log.Info("Main", "Course entry: deferring restore to tick loop") end
            _pendingRestore = false
            -- (the tick loop's initial-setup branch calls Persistence.Restore())
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
    Shadows = Shadows,
    Transitions = Transitions,
    Atmosphere = Atmosphere,
    Headlights = Headlights,
    Audio = Audio,
    Stars = Stars,
    LightCycle = LightCycle,
    Tunnels = Tunnels,
    RainCollision = RainCollision,
    Rainbow = Rainbow,
    CinematicSky = CinematicSky,
    RealSun = RealSun,
    Vignette = Vignette,
    PhotoMode = PhotoMode,
    WetGrip = WetGrip,
    Tuning = Tuning,
}
