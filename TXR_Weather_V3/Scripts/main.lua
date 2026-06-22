-- TXR Weather Mod v3.0
-- main.lua
-- Bootstrap and main loop

-- ============== MODULE LOADING ==============

-- Get the script directory for relative requires
local scriptDir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"

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
})

Log.Info("Main", "==============================================")
Log.Info("Main", Config.Version.FullName)
Log.Info("Main", "==============================================")

-- Load utils (depends on nothing)
local Utils = safeRequire("core.utils", "Utils")
if not Utils then
    Log.Error("Main", "Failed to load Utils module - continuing with limited functionality")
end

-- Load state (depends on nothing)
local State = safeRequire("core.state", "State")
if not State then
    Log.Error("Main", "Failed to load State module - continuing with limited functionality")
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
local Exposure = nil

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

    -- Phase 13: Auto-exposure scheduler (ported from VEAO)
    Exposure = safeRequire("systems.exposure", "Exposure")
    if Exposure then
        Log.Info("Main", "System module loaded: Exposure")
        if Exposure.Init then Exposure.Init() end
    else
        Log.Debug("Main", "Exposure module not loaded")
    end

    -- Phase 6: Wetness simulation (disabled by default - WIP)
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
local lastWorldContext = "unknown"   -- Track world context for PA transitions
local restoredFromPA = false         -- Flag to skip initial weather when restoring from PA
local _pendingRestore = false        -- Flag set when actors become invalid, triggers restore on next valid

-- PA freeze watchdog - continuously enforce freeze while in PA
local function enforcePAFreezeWatchdog()
    local uds = Actors and Actors.GetUDS()
    if uds then
        pcall(function() uds["Animate Time of Day"] = false end)
        pcall(function() uds["Simulation Speed"] = 0 end)
        pcall(function() uds["Time Speed"] = 0 end)
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
        
        -- Phase 2+: Actor discovery
        if Actors and Actors.Tick then
            Actors.Tick()
        end
        
        -- PA freeze watchdog - continuously enforce freeze while in PA
        if State.IsPAFrozen() then
            enforcePAFreezeWatchdog()
        end
        
        -- Phase 3+: Weather updates (skip in PA)
        if Weather and Weather.Tick and not State.IsPAFrozen() then
            Weather.Tick()
        end
        
        -- Apply initial settings once actors are discovered (but not in PA or just restored from PA)
        if not initialWeatherApplied and Actors and Actors.IsOnCourse() and not State.IsPAFrozen() then
            -- If we just restored from PA, skip the normal initialization
            if restoredFromPA then
                Log.Info("Main", "Restored from PA - skipping initial weather setup")
                -- Still need to initialize DLWE system
                if Wetness and Wetness.OnActorsReady then
                    Wetness.OnActorsReady()
                end
                initialWeatherApplied = true
                restoredFromPA = false
            else
                Log.Info("Main", "Actors ready - triggering initial setup")
                
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
                if Exposure and Exposure.OnCourseLoad then
                    Exposure.OnCourseLoad()
                end

                initialWeatherApplied = true
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
            initialWeatherApplied = false
            _pendingRestore = true  -- Signal to restore on next actor detection
            print("[TXR] Actors lost - pending restore on next detection")
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
        
        -- Headlights (auto on/off based on time)
        if Headlights and Headlights.Tick and not State.IsPAFrozen() then
            Headlights.Tick()
        end

        -- Auto-exposure scheduler (self-throttled; also runs in garage/menu,
        -- so it is intentionally NOT gated by the PA-frozen check)
        if Exposure and Exposure.Tick then
            Exposure.Tick()
        end
    end)
    
    if not success then
        Log.Error("Main", "Tick error: " .. tostring(err))
        if State then
            State.SetLastError(tostring(err))
        end
    end
end

-- ============== UE4SS HOOKS ==============

-- Get world tag from actor's world object
local function getWorldTagFromActor(actor)
    if not actor then return "unknown" end
    
    -- Check validity
    local isValid = false
    pcall(function()
        if actor.IsValid then isValid = actor:IsValid() end
    end)
    if not isValid then return "unknown" end
    
    -- Get world object
    local worldObj = nil
    pcall(function()
        if actor.GetWorld then worldObj = actor:GetWorld() end
    end)
    
    -- Check world validity
    local worldValid = false
    if worldObj then
        pcall(function()
            if worldObj.IsValid then worldValid = worldObj:IsValid() end
        end)
    end
    if not worldValid then return "unknown" end
    
    -- Get world string and detect tag
    local ws = nil
    pcall(function() ws = tostring(worldObj) end)
    
    if type(ws) == "string" then
        local lw = ws:lower()
        if lw:find("garage") or lw:find("outgame") or lw:find("ls_") then
            return "outgame"
        elseif lw:find("_pa") or lw:find("/pa") or lw:find(" pa ") or lw:find("pa_") or lw:find("pause") then
            return "pa"
        end
    end
    
    return "course"
end

-- Capture course state while actors still valid
local function captureCurrentState()
    local uds = Actors and Actors.GetUDS()
    local udw = Actors and Actors.GetUDW()
    
    local tod = -1
    local cloud = -1
    local fog = -1
    local speed = Config.TimeOfDay.DefaultSpeed
    
    if uds then
        pcall(function() tod = uds["Time Of Day"] end)
        pcall(function() speed = uds["Simulation Speed"] end)
    end
    
    if udw then
        pcall(function() cloud = udw["Cloud Coverage"] end)
        pcall(function() fog = udw["Fog"] end)
    end
    
    local preset = State.GetCurrentPreset()
    
    return {
        tod = Utils.ToNumber(tod, -1),
        cloud = Utils.ToNumber(cloud, -1),
        fog = Utils.ToNumber(fog, -1),
        speed = Utils.ToNumber(speed, Config.TimeOfDay.DefaultSpeed),
        preset = preset
    }
end

-- Apply frozen state to PA
local function applyPAFreeze(actor)
    -- Get captured state
    local captured = State.GetCapturedPAState()
    
    -- Set TOD from captured state
    if captured and captured.tod and captured.tod >= 0 then
        pcall(function() actor["Time Of Day"] = captured.tod end)
        Log.Info("Main", string.format("PA: Applied captured TOD=%.2f", captured.tod))
    end
    
    -- Freeze time
    pcall(function() actor["Animate Time of Day"] = false end)
    pcall(function() actor["Time Speed"] = 0 end)
    pcall(function() actor["Simulation Speed"] = 0 end)
    
    -- Apply cloud/fog to UDW if available
    local udw = nil
    pcall(function() udw = actor["Ultra Dynamic Weather"] end)
    if udw and captured then
        if captured.cloud and captured.cloud >= 0 then
            pcall(function() udw["Cloud Coverage - Manual Override"] = true end)
            pcall(function() udw["Cloud Coverage"] = captured.cloud end)
        end
        if captured.fog and captured.fog >= 0 then
            pcall(function() udw["Fog - Manual Override"] = true end)
            pcall(function() udw["Fog"] = captured.fog end)
        end
    end
    
    State.SetPAFrozen(true)
    Log.Info("Main", "PA: Time frozen")
end

-- Restore state when returning from PA
local function restoreFromPA(actor)
    local captured = State.GetCapturedPAState()
    if not captured then return end
    
    -- Restore TOD
    if captured.tod and captured.tod >= 0 then
        pcall(function() actor["Time Of Day"] = captured.tod end)
        Log.Info("Main", string.format("Course: Restored TOD=%.2f from PA", captured.tod))
    end
    
    -- Resume time
    pcall(function() actor["Animate Time of Day"] = true end)
    pcall(function() actor["Simulation Speed"] = captured.speed or Config.TimeOfDay.DefaultSpeed end)
    pcall(function() actor["Time Speed"] = 1.0 end)
    
    -- Restore cloud/fog
    local udw = nil
    pcall(function() udw = actor["Ultra Dynamic Weather"] end)
    if udw then
        if captured.cloud and captured.cloud >= 0 then
            pcall(function() udw["Cloud Coverage - Manual Override"] = true end)
            pcall(function() udw["Cloud Coverage"] = captured.cloud end)
        end
        if captured.fog and captured.fog >= 0 then
            pcall(function() udw["Fog - Manual Override"] = true end)
            pcall(function() udw["Fog"] = captured.fog end)
        end
    end
    
    State.SetPAFrozen(false)
    Log.Info("Main", "Course: Restored state from PA")
end

local function setupHooks()
    Log.Info("Main", "Setting up UE4SS hooks...")
    
    -- Check if we're in UE4SS environment
    if not RegisterHook then
        Log.Warn("Main", "RegisterHook not available - running outside UE4SS?")
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
        Log.Error("Main", "LoopAsync not available - cannot start main loop")
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

    -- ===== BISECTION HARNESS (debug; remove once the course-load crash is found) =====
    -- Setting a Config.ModuleToggles.X to false nil-s that module's handle, so every
    -- `if X and X.Tick`/`X.Setup` guard in the loop skips it entirely - disabling the
    -- module's runtime without touching call sites. All true = normal operation.
    -- Actors/Presets/Keybinds are core and intentionally not toggleable here.
    local tg = Config.ModuleToggles
    if tg then
        if tg.Weather     == false then Weather = nil end
        if tg.TimeOfDay   == false then TimeOfDay = nil end
        if tg.CloudsFog   == false then CloudsFog = nil end
        if tg.Shadows     == false then Shadows = nil end
        if tg.Transitions == false then Transitions = nil end
        if tg.Atmosphere  == false then Atmosphere = nil end
        if tg.Headlights  == false then Headlights = nil end
        if tg.Audio       == false then Audio = nil end
        if tg.Stars       == false then Stars = nil end
        if tg.Persistence == false then Persistence = nil end
        Log.Info("Main", "BISECT module toggles applied", {
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
local _CourseStateBeforePA = nil

-- LoadMapPreHook - fires BEFORE map unload while actors still valid
if RegisterLoadMapPreHook then
    RegisterLoadMapPreHook(function()
        print("[TXR] LoadMapPreHook fired")
        
        -- Get world tag from Actors module (or State) - NOT local variable
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
            
            print(string.format("[TXR] LoadMapPreHook: Read live values TOD=%.2f cloud=%.2f fog=%.2f preset=%s",
                tod, cloud, fog, preset or "?"))
            
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
                print(string.format("[TXR] LoadMapPreHook: Invalid TOD=%.2f - cannot capture", tod or -1))
                if Log then Log.Warn("Main", string.format("Invalid TOD on unload: %.2f", tod or -1)) end
            end
        else
            print(string.format("[TXR] LoadMapPreHook: Actors not valid (uds=%s udw=%s)", tostring(udsValid), tostring(udwValid)))
            if Log then Log.Debug("Main", "No valid actors on unload - cannot capture state") end
        end
        
        -- Save persistence if on course
        if currentTag == "course" and Persistence and Persistence.Save then
            Persistence.Save("map_unload_pre")
        end
        
        _LastWorldTag = currentTag
    end)
    print("[TXR] RegisterLoadMapPreHook completed")
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

-- BeginPlayPreHook - fires when new actors begin play
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
        
        -- Check if it's a sky actor using IsA (like V1.34)
        local skyCls = TryGetSkyClass()
        local courseCls = TryGetCourseSkyClass()
        
        local isSkyCls = false
        local isCourseCls = false
        
        if skyCls then
            pcall(function() isSkyCls = Actor:IsA(skyCls) end)
        end
        if courseCls then
            pcall(function() isCourseCls = Actor:IsA(courseCls) end)
        end
        
        -- Fallback: string matching
        local actorName = nil
        pcall(function() actorName = tostring(Actor) end)
        local isSkyByName = actorName and (
            actorName:find("UltraDynamicSky") or
            actorName:find("Ultra_Dynamic_Sky") or
            actorName:find("CourseSky") or
            actorName:find("BP_Sky")
        )
        
        -- Must match at least one detection method
        if not (isSkyCls or isCourseCls or isSkyByName) then return end
        
        print(string.format("[TXR] BeginPlayPreHook: Sky actor detected (IsA=%s/%s name=%s)", 
            tostring(isSkyCls), tostring(isCourseCls), actorName and actorName:sub(1,50) or "?"))
        
        -- Get world tag from actor
        local tag = "course"
        local worldString = "unknown"
        pcall(function()
            local worldObj = Actor:GetWorld()
            if worldObj and worldObj.IsValid and worldObj:IsValid() then
                local ws = tostring(worldObj)
                worldString = ws  -- Capture for logging
                local lw = ws:lower()
                if lw:find("garage") or lw:find("outgame") or lw:find("ls_") then
                    tag = "outgame"
                elseif lw:find("_pa") or lw:find("/pa") or lw:find(" pa ") or lw:find("pa_") or lw:find("pause") then
                    tag = "pa"
                end
            end
        end)
        
        -- DEBUG: Always log the world string so we can see what PA looks like
        print(string.format("[TXR] World string: %s", worldString))
        print(string.format("[TXR] World tag: %s (was %s)", tag, _LastWorldTag))
        if Log then Log.Info("Main", string.format("BeginPlayPreHook: worldString=%s tag=%s (was %s)", 
            worldString:sub(1,80), tag, _LastWorldTag)) end
        
        -- Handle PA entry - V1.32 pattern: load from file, apply, freeze
        if tag == "pa" then
            print("[TXR] Entering PA - loading state and freezing")
            if Log then Log.Info("Main", "Entering PA - loading state from file") end
            
            -- STEP 1: Load state from persistence file FIRST (V1.32 pattern)
            -- This ensures we have valid saved values even if runtime vars were lost
            local savedTOD, savedCloud, savedFog, savedPreset = nil, nil, nil, nil
            if Persistence and Persistence.LoadRaw then
                local data = Persistence.LoadRaw()
                if data then
                    savedTOD = data.tod
                    savedCloud = data.cloud
                    savedFog = data.fog
                    savedPreset = data.preset
                    print(string.format("[TXR] PA: Loaded from file: TOD=%.2f cloud=%.2f fog=%.2f preset=%s",
                        savedTOD or -1, savedCloud or -1, savedFog or -1, savedPreset or "?"))
                end
            end
            
            -- Fallback to runtime captured state if file didn't have values
            if (not savedTOD or savedTOD < 0) and _CourseStateBeforePA and _CourseStateBeforePA.tod then
                savedTOD = _CourseStateBeforePA.tod
            end
            if (not savedCloud or savedCloud < 0) and _CourseStateBeforePA and _CourseStateBeforePA.cloud then
                savedCloud = _CourseStateBeforePA.cloud
            end
            if (not savedFog) and _CourseStateBeforePA and _CourseStateBeforePA.fog then
                savedFog = _CourseStateBeforePA.fog
            end
            if (not savedPreset) and _CourseStateBeforePA and _CourseStateBeforePA.preset then
                savedPreset = _CourseStateBeforePA.preset
            end
            
            -- STEP 2: Apply saved TOD to PA actor
            if savedTOD and savedTOD >= 0 and savedTOD <= 2400 then
                pcall(function() Actor["Time Of Day"] = savedTOD end)
                print(string.format("[TXR] PA: Set TOD to %.2f", savedTOD))
            end
            
            -- STEP 3: Get UDW and apply cloud/fog
            local udw = nil
            pcall(function() udw = Actor["Ultra Dynamic Weather"] end)
            
            if udw then
                -- Update State module with PA actors
                if State and State.SetUDS then State.SetUDS(Actor) end
                if State and State.SetUDW then State.SetUDW(udw) end
                
                -- Apply cloud/fog with manual override
                if savedCloud and savedCloud >= 0 then
                    pcall(function() udw["Cloud Coverage - Manual Override"] = true end)
                    pcall(function() udw["Cloud Coverage"] = savedCloud end)
                    print(string.format("[TXR] PA: Set Cloud to %.2f", savedCloud))
                end
                if savedFog ~= nil then
                    pcall(function() udw["Fog - Manual Override"] = true end)
                    pcall(function() udw["Fog"] = savedFog end)
                    print(string.format("[TXR] PA: Set Fog to %.2f", savedFog))
                end
            end
            
            -- STEP 4: Re-apply weather preset to get rain/effects
            if savedPreset and Weather and Weather.Apply then
                print(string.format("[TXR] PA: Re-applying weather preset: %s", savedPreset))
                if Log then Log.Info("Main", "PA: Re-applying preset " .. tostring(savedPreset)) end
                pcall(function() Weather.Apply(savedPreset, 0) end)
            end
            
            -- STEP 5: Freeze time
            pcall(function() Actor["Simulate Real Sun"] = false end)
            pcall(function() Actor["Animate Time of Day"] = false end)
            pcall(function() Actor["Time Speed"] = 0 end)
            pcall(function() Actor["Simulation Speed"] = 0 end)
            
            -- STEP 6: Save state snapshot (like V1.32)
            if Persistence and Persistence.Save then
                Persistence.Save("enter_pa")
            end
            
            if State and State.SetPAFrozen then State.SetPAFrozen(true) end
            if Log then Log.Info("Main", string.format("PA frozen: TOD=%.2f cloud=%.2f fog=%.2f preset=%s",
                savedTOD or -1, savedCloud or -1, savedFog or -1, savedPreset or "?")) end
            
            _LastWorldTag = tag
            return  -- Don't continue to course handling
            
        -- Handle return to course (PA/map transition)
        -- Don't restore here - let the main tick loop's Persistence.Restore() handle it
        -- This matches Fix1 behavior where TOD worked
        elseif tag == "course" and _pendingRestore then
            print("[TXR] Course entry after map transition - will restore in tick loop")
            if Log then Log.Info("Main", "Course entry - deferring restore to tick loop") end
            _pendingRestore = false
            -- restoredFromPA stays false so tick loop will call Persistence.Restore()
        end
        
        _LastWorldTag = tag
        
        -- Update State module
        if State and State.SetWorldContext then State.SetWorldContext(tag) end
    end)
    print("[TXR] RegisterBeginPlayPreHook completed")
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
    Exposure = Exposure,
}
