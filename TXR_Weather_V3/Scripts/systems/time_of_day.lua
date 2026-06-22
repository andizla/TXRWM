-- TXR Weather Mod v3.0
-- systems/time_of_day.lua
-- Time of Day control using UDS properties

local TimeOfDay = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local Utils = require("core.utils")
local State = require("core.state")
local Config = require("config")
local Actors = require("systems.actors")

local MODULE = "TimeOfDay"

-- ============== STATE ==============
local currentSpeedMode = "normal"  -- "normal", "fast", "paused"
local baselineEnforceAccum = 0
local lastKnownTOD = nil

-- ============== PROPERTY NAMES ==============
local PROP_TIME_OF_DAY = "Time Of Day"
local PROP_SIMULATION_SPEED = "Simulation Speed"
local PROP_TIME_SPEED = "Time Speed"
local PROP_ANIMATE_TOD = "Animate Time of Day"

-- ============== INTERNAL FUNCTIONS ==============

--- Read a property directly from UDS with pcall protection
--- @param propName string
--- @return any|nil
local function readUDSProperty(propName)
    local uds = Actors.GetUDS()
    if not uds then return nil end
    
    local value = nil
    local success = pcall(function()
        value = uds[propName]
    end)
    
    if success then
        return value
    end
    return nil
end

--- Write a property directly to UDS with pcall protection
--- @param propName string
--- @param value any
--- @return boolean success
local function writeUDSProperty(propName, value)
    local uds = Actors.GetUDS()
    if not uds then return false end
    
    local success = pcall(function()
        uds[propName] = value
    end)
    
    if success then
        Log.Debug(MODULE, "Set property", {prop = propName, value = tostring(value)})
    end
    
    return success
end

-- ============== PUBLIC API ==============

--- Initialize time of day module
function TimeOfDay.Init()
    Log.Info(MODULE, "Initializing time of day module")
    currentSpeedMode = "normal"
    baselineEnforceAccum = 0
    State.SetModuleStatus("timeOfDay", true)
    return true
end

--- Get current time of day (0-2400)
--- @return number|nil
function TimeOfDay.GetCurrentTOD()
    local todRaw = readUDSProperty(PROP_TIME_OF_DAY)
    local tod = Utils.ToNumber(todRaw, nil)
    
    if tod then
        tod = tod % 2400  -- Wrap to 0-2400 range
        lastKnownTOD = tod
        State.SetLastKnownTOD(tod)
    end
    
    return tod
end

--- Set time of day (0-2400)
--- @param value number
--- @return boolean success
function TimeOfDay.SetTOD(value)
    value = Utils.Clamp(value, 0, 2400)
    local success = writeUDSProperty(PROP_TIME_OF_DAY, value)
    
    if success then
        Log.Info(MODULE, "Set time of day", {tod = value})
        lastKnownTOD = value
        State.SetLastKnownTOD(value)
    end
    
    return success
end

--- Get current simulation speed
--- @return number|nil
function TimeOfDay.GetSpeed()
    local speed = readUDSProperty(PROP_SIMULATION_SPEED)
    return Utils.ToNumber(speed, nil)
end

--- Set simulation speed
--- @param speed number
--- @return boolean success
function TimeOfDay.SetSpeed(speed)
    local success = writeUDSProperty(PROP_SIMULATION_SPEED, speed)
    
    if success then
        -- Also set Time Speed for consistency
        writeUDSProperty(PROP_TIME_SPEED, 1.0)
        
        -- Update mode tracking
        if speed == 0 then
            currentSpeedMode = "paused"
        elseif math.abs(speed - Config.TimeOfDay.DefaultSpeed) < 1 then
            currentSpeedMode = "normal"
        else
            currentSpeedMode = "fast"
        end
        
        State.SetTimeSpeed(speed)
        Log.Info(MODULE, "Set speed", {speed = speed, mode = currentSpeedMode})
    end
    
    return success
end

--- Get current speed mode
--- @return string "normal", "fast", or "paused"
function TimeOfDay.GetSpeedMode()
    return currentSpeedMode
end

--- Pause time (freeze)
--- @return boolean success
function TimeOfDay.Pause()
    local success = writeUDSProperty(PROP_ANIMATE_TOD, false)
    
    if success then
        currentSpeedMode = "paused"
        State.SetTimePaused(true)
        Log.Info(MODULE, "Time paused")
    end
    
    return success
end

--- Resume time (unfreeze)
--- @return boolean success
function TimeOfDay.Resume()
    local success = writeUDSProperty(PROP_ANIMATE_TOD, true)
    
    if success then
        -- Restore speed based on what we had before
        currentSpeedMode = "normal"
        State.SetTimePaused(false)
        Log.Info(MODULE, "Time resumed")
    end
    
    return success
end

--- Check if time is paused
--- @return boolean
function TimeOfDay.IsPaused()
    local animate = readUDSProperty(PROP_ANIMATE_TOD)
    return animate == false
end

--- Toggle pause state
--- @return boolean newPausedState
function TimeOfDay.TogglePause()
    if TimeOfDay.IsPaused() then
        TimeOfDay.Resume()
        return false
    else
        TimeOfDay.Pause()
        return true
    end
end

--- Cycle through speed modes: Normal -> Fast -> Paused -> Normal
--- @return string newMode
function TimeOfDay.CycleSpeed()
    local isPaused = TimeOfDay.IsPaused()
    
    local newSpeed
    local newMode
    
    if isPaused then
        -- Was paused, go to normal
        TimeOfDay.Resume()
        newSpeed = Config.TimeOfDay.DefaultSpeed
        newMode = "normal"
    elseif currentSpeedMode == "normal" then
        -- Was normal, go to fast
        newSpeed = Config.TimeOfDay.FastSpeed
        newMode = "fast"
    else
        -- Was fast (or other), go to paused
        TimeOfDay.Pause()
        return "paused"
    end
    
    TimeOfDay.SetSpeed(newSpeed)
    return newMode
end

--- Get fraction of day (0.0 - 1.0)
--- @return number
function TimeOfDay.GetFracDay()
    local tod = TimeOfDay.GetCurrentTOD()
    if tod then
        return (tod % 2400) / 2400
    end
    return 0.5
end

--- Check if currently in dawn window
--- @param tod number|nil Optional TOD value, reads current if nil
--- @return boolean
function TimeOfDay.IsInDawnWindow(tod)
    tod = tod or TimeOfDay.GetCurrentTOD()
    if not tod then return false end
    return tod >= Config.TimeOfDay.DawnStart and tod <= Config.TimeOfDay.DawnEnd
end

--- Check if currently in dusk window
--- @param tod number|nil Optional TOD value, reads current if nil
--- @return boolean
function TimeOfDay.IsInDuskWindow(tod)
    tod = tod or TimeOfDay.GetCurrentTOD()
    if not tod then return false end
    return tod >= Config.TimeOfDay.DuskStart and tod <= Config.TimeOfDay.DuskEnd
end

--- Check if in any transition window (dawn or dusk)
--- @param tod number|nil
--- @return boolean
function TimeOfDay.IsInTransitionWindow(tod)
    return TimeOfDay.IsInDawnWindow(tod) or TimeOfDay.IsInDuskWindow(tod)
end

--- Get time period name
--- @param tod number|nil
--- @return string "night", "dawn", "day", "dusk"
function TimeOfDay.GetPeriod(tod)
    tod = tod or TimeOfDay.GetCurrentTOD()
    if not tod then return "unknown" end
    
    if tod < Config.TimeOfDay.DawnStart then
        return "night"
    elseif tod <= Config.TimeOfDay.DawnEnd then
        return "dawn"
    elseif tod < Config.TimeOfDay.DuskStart then
        return "day"
    elseif tod <= Config.TimeOfDay.DuskEnd then
        return "dusk"
    else
        return "night"
    end
end

--- Format TOD as time string (e.g., "14:30")
--- @param tod number|nil
--- @return string
function TimeOfDay.FormatTime(tod)
    tod = tod or TimeOfDay.GetCurrentTOD()
    if not tod then return "--:--" end
    
    local hours = math.floor(tod / 100)
    local minutes = math.floor(tod % 100 * 0.6)  -- Convert 0-99 to 0-59
    return string.format("%02d:%02d", hours, minutes)
end

--- Baseline enforcement tick - ensures time keeps advancing correctly
--- @param dt number Delta time in seconds
function TimeOfDay.BaselineEnforceTick(dt)
    if not Actors.IsOnCourse() then return end
    if currentSpeedMode == "paused" then return end
    
    baselineEnforceAccum = baselineEnforceAccum + dt
    if baselineEnforceAccum < 3.0 then return end
    baselineEnforceAccum = 0
    
    -- Skip speed enforcement if Transitions module is controlling speed
    local Transitions = nil
    pcall(function() Transitions = require("systems.transitions") end)
    if Transitions and Transitions.IsInSlowWindow and Transitions.IsInSlowWindow() then
        return  -- Let transitions module control speed
    end
    
    -- Check and fix Simulation Speed if it drifted
    local curSpeed = TimeOfDay.GetSpeed()
    local targetSpeed = currentSpeedMode == "fast" 
        and Config.TimeOfDay.FastSpeed 
        or Config.TimeOfDay.DefaultSpeed
    
    if curSpeed and math.abs(curSpeed - targetSpeed) > 0.1 then
        writeUDSProperty(PROP_SIMULATION_SPEED, targetSpeed)
        Log.Debug(MODULE, "Baseline enforce: speed corrected", {
            was = curSpeed,
            now = targetSpeed
        })
    end
    
    -- Ensure time is animating (unless paused)
    if currentSpeedMode ~= "paused" then
        local animate = readUDSProperty(PROP_ANIMATE_TOD)
        if animate == false then
            writeUDSProperty(PROP_ANIMATE_TOD, true)
            Log.Debug(MODULE, "Baseline enforce: re-enabled animation")
        end
    end
end

--- Main tick function
--- @param dt number|nil Delta time (defaults to estimating from tick interval)
function TimeOfDay.Tick(dt)
    dt = dt or (Config.MainLoop.TickIntervalMs / 1000)
    
    if not Actors.IsOnCourse() then return end
    
    -- Update last known TOD
    TimeOfDay.GetCurrentTOD()
    
    -- Baseline enforcement
    TimeOfDay.BaselineEnforceTick(dt)
end

--- Get status for debugging
--- @return table
function TimeOfDay.GetStatus()
    return {
        currentTOD = lastKnownTOD,
        formattedTime = TimeOfDay.FormatTime(lastKnownTOD),
        period = TimeOfDay.GetPeriod(lastKnownTOD),
        speedMode = currentSpeedMode,
        speed = TimeOfDay.GetSpeed(),
        isPaused = TimeOfDay.IsPaused(),
    }
end

--- Apply starting time of day if configured
function TimeOfDay.OnCourseLoad()
    if Config.TimeOfDay.StartingTOD then
        Log.Info(MODULE, "Applying starting TOD", {tod = Config.TimeOfDay.StartingTOD})
        TimeOfDay.SetTOD(Config.TimeOfDay.StartingTOD)
    end
    
    -- Ensure default speed
    TimeOfDay.SetSpeed(Config.TimeOfDay.DefaultSpeed)
    TimeOfDay.Resume()
end

-- Initialize on load
TimeOfDay.Init()

return TimeOfDay
