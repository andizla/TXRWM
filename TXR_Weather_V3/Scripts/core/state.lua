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

    -- Photo mode session (photomode.lua owns detection; main.lua gates the
    -- weather scheduler on this so a pick can't mutate the sky mid-shoot)
    photo = {
        sessionOpen = false,
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
    
    -- Module status flags. SetModuleStatus is self-registering, so this
    -- pre-seeded list need not be exhaustive.
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

-- ============== WEATHER STATE ==============

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

--- Set photo-mode session flag (photomode.lua, on its open/close edges)
--- @param open boolean
function State.SetPhotoSessionOpen(open)
    state.photo.sessionOpen = open
end

--- Check if a photo-mode session is open
--- @return boolean
function State.IsPhotoSessionOpen()
    return state.photo.sessionOpen
end

--- GT pump health (set by main's watchdog): false means UE4SS removed its
--- engine-tick Lua hook ("Ref was not function", upstream #346) and every
--- ExecuteInGameThread marshal is inert until the game restarts. Consumers
--- skip futile marshals and surface the condition (overlay banner, pulse gate).
function State.SetGTPumpAlive(alive)
    state.gtPumpAlive = alive
end

function State.IsGTPumpAlive()
    return state.gtPumpAlive ~= false   -- default true before first beat
end

-- ============== MODULE STATUS ==============

--- Set module enabled/initialized status. Self-registering: a name not in the
--- pre-seeded list is added, not dropped (a guard here once left the exposure
--- module uncounted in "modules loaded").
--- @param moduleName string
--- @param enabled boolean
function State.SetModuleStatus(moduleName, enabled)
    if type(moduleName) == "string" then
        state.modules[moduleName] = enabled
    end
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

-- ============== DEBUG ==============

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
