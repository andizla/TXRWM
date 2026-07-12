-- TXR Weather Mod v3.0
-- core/state.lua
-- Centralized state management: single source of truth for mod state

local State = {}

-- ============== INTERNAL STATE ==============
-- Only track what UDW doesn't expose or what we need across module boundaries

local state = {
    -- Actor references (cached, may become invalid)
    actors = {
        uds = nil,          -- Ultra Dynamic Sky actor
        udw = nil,          -- Ultra Dynamic Weather actor
        lastDiscovery = 0,  -- Timestamp of last successful discovery
    },
    
    -- World context
    world = {
        context = "unknown",  -- "course", "outgame", "unknown"
        lastContext = "unknown",  -- Previous context for transition detection
        mapName = nil,
        isOnCourse = false,
    },
    
    -- PA (Parking Area) state preservation
    pa = {
        -- Captured course state before entering PA
        capturedTOD = nil,
        capturedCloud = nil,
        capturedFog = nil,
        capturedSpeed = nil,
        capturedPreset = nil,
        -- Tracking
        frozen = false,
        entryTime = nil,
    },
    
    -- Weather state (what WE applied, UDW is authoritative)
    weather = {
        currentPreset = nil,      -- Name of currently applied preset
        targetPreset = nil,       -- Name of preset we're transitioning to
        isTransitioning = false,
        transitionStart = 0,
        transitionDuration = 0,
        -- Preset targets for clouds/fog (from preset definition)
        presetCloudTarget = nil,
        presetFogTarget = nil,
        presetActive = false,     -- True when a preset is actively controlling values
    },
    
    -- Time state
    time = {
        lastKnownTOD = nil,
        isPaused = false,
        currentSpeed = 1.0,
    },
    
    -- Module status flags. Pre-seeded with the modules that report status; any
    -- other module that calls SetModuleStatus is added on first call (the setter is
    -- self-registering), so this list does not have to be kept exhaustive.
    modules = {
        logging = false,
        utils = false,
        state = false,
        actors = false,
        weather = false,
        timeOfDay = false,
        keybinds = false,
        persistence = false,
        cloudsFog = false,
        shadows = false,
        transitions = false,
        atmosphere = false,
        audio = false,
        stars = false,
        exposure = false,
    },
    
    -- Session info
    session = {
        startTime = 0,
        loopCount = 0,
        lastError = nil,
    },
}

-- ============== ACTOR STATE ==============

--- Set UDS actor reference
--- @param actor any UDS actor
function State.SetUDS(actor)
    state.actors.uds = actor
    if actor then
        state.actors.lastDiscovery = os.time()
    end
end

--- Get UDS actor reference
--- @return any|nil
function State.GetUDS()
    return state.actors.uds
end

--- Set UDW actor reference
--- @param actor any UDW actor
function State.SetUDW(actor)
    state.actors.udw = actor
    if actor then
        state.actors.lastDiscovery = os.time()
    end
end

--- Get UDW actor reference
--- @return any|nil
function State.GetUDW()
    return state.actors.udw
end

--- Clear actor references (call on map unload)
function State.ClearActors()
    state.actors.uds = nil
    state.actors.udw = nil
end

--- Check if actors are available
--- @return boolean
function State.HasActors()
    return state.actors.uds ~= nil and state.actors.udw ~= nil
end

--- Get last actor discovery timestamp
--- @return number
function State.GetLastDiscoveryTime()
    return state.actors.lastDiscovery
end

-- ============== WORLD CONTEXT ==============

--- Set world context
--- @param context string "course", "outgame", "unknown"
--- @param mapName string|nil Optional map name
function State.SetWorldContext(context, mapName)
    state.world.lastContext = state.world.context
    state.world.context = context
    state.world.mapName = mapName
    state.world.isOnCourse = (context == "course")
end

--- Get previous world context (for transition detection)
--- @return string
function State.GetLastWorldContext()
    return state.world.lastContext
end

--- Get world context
--- @return string
function State.GetWorldContext()
    return state.world.context
end

--- Check if on course
--- @return boolean
function State.IsOnCourse()
    return state.world.isOnCourse
end

--- Get map name
--- @return string|nil
function State.GetMapName()
    return state.world.mapName
end

-- ============== WEATHER STATE ==============

--- Set current weather preset (what we applied)
--- @param presetName string
function State.SetCurrentPreset(presetName)
    state.weather.currentPreset = presetName
end

--- Get current weather preset name
--- @return string|nil
function State.GetCurrentPreset()
    return state.weather.currentPreset
end

--- Mark weather transition start
--- @param targetPreset string Preset we're transitioning to
--- @param duration number Transition duration in seconds
function State.StartWeatherTransition(targetPreset, duration)
    state.weather.currentPreset = targetPreset  -- Set immediately so saves capture it
    state.weather.targetPreset = targetPreset
    state.weather.isTransitioning = true
    state.weather.transitionStart = os.time()
    state.weather.transitionDuration = duration
end

--- Mark weather transition complete
function State.CompleteWeatherTransition()
    state.weather.currentPreset = state.weather.targetPreset
    state.weather.targetPreset = nil
    state.weather.isTransitioning = false
end

--- Check if weather is transitioning
--- @return boolean
function State.IsWeatherTransitioning()
    -- Also check if transition should have completed by now
    if state.weather.isTransitioning then
        local elapsed = os.time() - state.weather.transitionStart
        if elapsed >= state.weather.transitionDuration then
            State.CompleteWeatherTransition()
            return false
        end
    end
    return state.weather.isTransitioning
end

--- Get target preset during transition
--- @return string|nil
function State.GetTargetPreset()
    return state.weather.targetPreset
end

--- Set preset cloud target (for clouds_fog module)
--- @param value number|nil Cloud coverage target (nil to disable)
function State.SetPresetCloudTarget(value)
    state.weather.presetCloudTarget = value
end

--- Get preset cloud target
--- @return number|nil
function State.GetPresetCloudTarget()
    return state.weather.presetCloudTarget
end

--- Set preset fog target (for clouds_fog module)
--- @param value number|nil Fog density target (nil to disable)
function State.SetPresetFogTarget(value)
    state.weather.presetFogTarget = value
end

--- Get preset fog target
--- @return number|nil
function State.GetPresetFogTarget()
    return state.weather.presetFogTarget
end

--- Set whether a preset is actively controlling values
--- @param active boolean
function State.SetPresetActive(active)
    state.weather.presetActive = active
end

--- Check if a preset is actively controlling values
--- @return boolean
function State.IsPresetActive()
    return state.weather.presetActive == true
end

-- ============== TIME STATE ==============

--- Update last known time of day
--- @param tod number Time of day (0-2400)
function State.SetLastKnownTOD(tod)
    state.time.lastKnownTOD = tod
end

--- Get last known time of day
--- @return number|nil
function State.GetLastKnownTOD()
    return state.time.lastKnownTOD
end

--- Set time paused state
--- @param paused boolean
function State.SetTimePaused(paused)
    state.time.isPaused = paused
end

--- Check if time is paused
--- @return boolean
function State.IsTimePaused()
    return state.time.isPaused
end

--- Set current simulation speed
--- @param speed number
function State.SetTimeSpeed(speed)
    state.time.currentSpeed = speed
    state.time.isPaused = (speed == 0)
end

--- Get current simulation speed
--- @return number
function State.GetTimeSpeed()
    return state.time.currentSpeed
end

-- ============== PA STATE ==============

--- Capture current state for PA preservation
--- @param tod number Time of day
--- @param cloud number Cloud coverage
--- @param fog number Fog density
--- @param speed number Simulation speed
--- @param preset string|nil Current preset name
function State.CaptureForPA(tod, cloud, fog, speed, preset)
    state.pa.capturedTOD = tod
    state.pa.capturedCloud = cloud
    state.pa.capturedFog = fog
    state.pa.capturedSpeed = speed
    state.pa.capturedPreset = preset
    state.pa.entryTime = os.time()
end

--- Get captured PA state
--- @return table|nil Captured state or nil if none
function State.GetCapturedPAState()
    if not state.pa.capturedTOD then return nil end
    return {
        tod = state.pa.capturedTOD,
        cloud = state.pa.capturedCloud,
        fog = state.pa.capturedFog,
        speed = state.pa.capturedSpeed,
        preset = state.pa.capturedPreset,
    }
end

--- Clear captured PA state
function State.ClearPAState()
    state.pa.capturedTOD = nil
    state.pa.capturedCloud = nil
    state.pa.capturedFog = nil
    state.pa.capturedSpeed = nil
    state.pa.capturedPreset = nil
    state.pa.frozen = false
    state.pa.entryTime = nil
end

--- Set PA frozen flag
--- @param frozen boolean
function State.SetPAFrozen(frozen)
    state.pa.frozen = frozen
end

--- Check if PA is frozen
--- @return boolean
function State.IsPAFrozen()
    return state.pa.frozen
end

--- Check if we have captured state from course
--- @return boolean
function State.HasCapturedPAState()
    return state.pa.capturedTOD ~= nil
end

-- ============== MODULE STATUS ==============

--- Set module enabled/initialized status. Self-registering: a module name not in
--- the pre-seeded list is added rather than silently dropped (the old guard meant
--- e.g. the exposure module's status never recorded, undercounting "modules loaded").
--- @param moduleName string
--- @param enabled boolean
function State.SetModuleStatus(moduleName, enabled)
    if type(moduleName) == "string" then
        state.modules[moduleName] = enabled
    end
end

--- Get module status
--- @param moduleName string
--- @return boolean
function State.GetModuleStatus(moduleName)
    return state.modules[moduleName] or false
end

--- Get all module statuses
--- @return table
function State.GetAllModuleStatuses()
    local copy = {}
    for k, v in pairs(state.modules) do
        copy[k] = v
    end
    return copy
end

-- ============== SESSION INFO ==============

--- Initialize session
function State.InitSession()
    state.session.startTime = os.time()
    state.session.loopCount = 0
    state.session.lastError = nil
end

--- Increment loop count
function State.IncrementLoopCount()
    state.session.loopCount = state.session.loopCount + 1
    return state.session.loopCount
end

--- Get loop count
--- @return number
function State.GetLoopCount()
    return state.session.loopCount
end

--- Set last error
--- @param error string
function State.SetLastError(error)
    state.session.lastError = error
end

--- Get last error
--- @return string|nil
function State.GetLastError()
    return state.session.lastError
end

--- Get session duration in seconds
--- @return number
function State.GetSessionDuration()
    return os.time() - state.session.startTime
end

-- ============== FULL STATE OPERATIONS ==============

--- Reset all state (call on mod reload or map change)
--- @param preserveSession boolean If true, keep session info
function State.Reset(preserveSession)
    -- Clear actor references
    State.ClearActors()
    
    -- Reset world context
    state.world.context = "unknown"
    state.world.lastContext = "unknown"
    state.world.mapName = nil
    state.world.isOnCourse = false
    
    -- Reset weather state
    state.weather.currentPreset = nil
    state.weather.targetPreset = nil
    state.weather.isTransitioning = false
    state.weather.transitionStart = 0
    state.weather.transitionDuration = 0
    
    -- Reset time state
    state.time.lastKnownTOD = nil
    state.time.isPaused = false
    state.time.currentSpeed = 1.0
    
    -- Clear PA state
    State.ClearPAState()
    
    -- Keep module statuses (they represent loaded modules, not runtime state)
    
    -- Optionally reset session
    if not preserveSession then
        state.session.loopCount = 0
        state.session.lastError = nil
    end
end

--- Export state for persistence
--- @return table Serializable state subset
function State.Export()
    return {
        weather = {
            currentPreset = state.weather.currentPreset,
        },
        time = {
            lastKnownTOD = state.time.lastKnownTOD,
            currentSpeed = state.time.currentSpeed,
        },
        modules = state.modules,
    }
end

--- Import state from persistence
--- @param data table Previously exported state
function State.Import(data)
    if not data then return end
    
    if data.weather then
        state.weather.currentPreset = data.weather.currentPreset
    end
    
    if data.time then
        state.time.lastKnownTOD = data.time.lastKnownTOD
        state.time.currentSpeed = data.time.currentSpeed or 1.0
    end
    
    if data.modules then
        for k, v in pairs(data.modules) do
            if state.modules[k] ~= nil then
                state.modules[k] = v
            end
        end
    end
end

--- Get a debug snapshot of current state
--- @return table
function State.GetDebugSnapshot()
    return {
        hasUDS = state.actors.uds ~= nil,
        hasUDW = state.actors.udw ~= nil,
        context = state.world.context,
        isOnCourse = state.world.isOnCourse,
        currentPreset = state.weather.currentPreset,
        isTransitioning = state.weather.isTransitioning,
        lastTOD = state.time.lastKnownTOD,
        loopCount = state.session.loopCount,
    }
end

return State
