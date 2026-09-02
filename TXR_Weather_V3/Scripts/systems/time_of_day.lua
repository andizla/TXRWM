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
        -- Resume always lands in normal mode; the baseline enforcer
        -- re-asserts the matching speed within ~3s.
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

-- Photomode time freeze: photomode.lua calls this on session open/close.
-- Uses the Animate Time of Day bool (same lever as Pause/Resume), which is
-- orthogonal to Simulation Speed, so the transitions module's slow-window
-- speed writes cannot unfreeze the picture mid-session. Respects a manual
-- Alt+T pause: closing photomode never resumes a manually paused clock.
-- A teardown-close writes into a dying UDS and fails silently;
-- the next course load runs the normal Resume path anyway.
local photoFrozen = false
local photoWasPaused = false
local photoRetryAt = nil      -- next freeze-write retry (os.clock)
local photoRetryUntil = nil   -- retry give-up deadline

function TimeOfDay.SetPhotoFreeze(on)
    if on == photoFrozen then return end
    photoFrozen = on
    if on then
        -- An unreadable UDS (routine at the open instant, see the retry note
        -- below) reads as "not paused", which made the close resume a manual
        -- Alt+T pause; the module's own mode is the reliable record.
        photoWasPaused = (currentSpeedMode == "paused") or TimeOfDay.IsPaused()
        if not photoWasPaused then
            local ok = writeUDSProperty(PROP_ANIMATE_TOD, false)
            Log.Info(MODULE, "Photo freeze ON (time)", {ok = ok})
            if not ok then
                -- UDS is routinely invalid at the open instant (the game
                -- re-creates the sky actor on photomode open; 9 of 11
                -- opens failed on 08-31, sun drifting through the shoot).
                -- Retry until it returns or the window closes.
                photoRetryAt = os.clock() + 1.0
                photoRetryUntil = os.clock() + 8.0
            end
        end
    else
        photoRetryAt, photoRetryUntil = nil, nil
        if not photoWasPaused then
            local ok = writeUDSProperty(PROP_ANIMATE_TOD, true)
            Log.Info(MODULE, "Photo freeze OFF (time)", {ok = ok})
        end
        photoWasPaused = false
    end
end

--- Retry a failed photo-freeze write while the session is still open.
local function photoFreezeRetryTick()
    if not (photoFrozen and photoRetryAt) then return end
    local nowC = os.clock()
    if nowC < photoRetryAt then return end
    if photoRetryUntil and nowC > photoRetryUntil then
        Log.Warn(MODULE, "Photo freeze retry gave up (UDS never returned)")
        photoRetryAt, photoRetryUntil = nil, nil
        return
    end
    local ok = writeUDSProperty(PROP_ANIMATE_TOD, false)
    if ok then
        Log.Info(MODULE, "Photo freeze ON (retry ok)")
        photoRetryAt, photoRetryUntil = nil, nil
    else
        photoRetryAt = nowC + 1.0
    end
end

--- Clear the freeze latch without touching UDS. For the course-entry
--- init path: a teardown-close that never delivered SetPhotoFreeze(false)
--- would otherwise strand the latch and silently disable the next
--- shoot's freeze (SetPhotoFreeze early-outs on on==photoFrozen).
function TimeOfDay.ResetPhotoFreeze()
    photoFrozen = false
    photoWasPaused = false
    photoRetryAt, photoRetryUntil = nil, nil
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

--- Night-only cycle: if enabled and time has entered the day segment, jump
--- straight to the pre-dusk point so the cycle runs dusk -> night -> dawn.
--- Also catches persisted/restored daytime values landing mid-day.
--- @param tod number|nil Current TOD (reads it if nil)
function TimeOfDay.NightOnlyEnforce(tod)
    if not Config.TimeOfDay.NightOnly then return end
    if Config.TimeOfDay.DebugShortCycle then return end  -- short cycle wins
    tod = tod or TimeOfDay.GetCurrentTOD()
    if not tod then return end

    local skipFrom = Config.TimeOfDay.NightOnlySkipFrom or Config.TimeOfDay.DawnEnd
    local skipTo   = Config.TimeOfDay.NightOnlySkipTo or Config.TimeOfDay.DuskStart
    if skipFrom >= skipTo then return end  -- misconfigured window, do nothing

    if tod >= skipFrom and tod < skipTo then
        Log.Info(MODULE, "Night-only: skipping day", {from = tod, to = skipTo})
        TimeOfDay.SetTOD(skipTo)
    end
end

--- Debug short cycle: keep dawn and dusk full length, but cut the flat day
--- and night cores to about an hour each (exposure tuning aid). The day core
--- is a plain skip window; the night core window wraps midnight. Takes
--- precedence over NightOnly (which early-returns while this is enabled).
--- @param tod number|nil Current TOD (reads it if nil)
function TimeOfDay.ShortCycleEnforce(tod)
    if not Config.TimeOfDay.DebugShortCycle then return end
    tod = tod or TimeOfDay.GetCurrentTOD()
    if not tod then return end

    local dayFrom   = Config.TimeOfDay.ShortCycleDaySkipFrom or 830
    local dayTo     = Config.TimeOfDay.ShortCycleDaySkipTo or 1630
    local nightFrom = Config.TimeOfDay.ShortCycleNightSkipFrom or 2230
    local nightTo   = Config.TimeOfDay.ShortCycleNightSkipTo or 420

    if dayFrom < dayTo and tod >= dayFrom and tod < dayTo then
        Log.Info(MODULE, "Short cycle: skipping day core", {from = tod, to = dayTo})
        TimeOfDay.SetTOD(dayTo)
        return
    end

    -- Night window: wrapping config = [nightFrom..2400) U [0..nightTo);
    -- plain config = [nightFrom..nightTo). Orientation matters: treating a
    -- plain window as wrapping would match every TOD and pin the clock.
    local inNight
    if nightFrom > nightTo then
        inNight = (tod >= nightFrom or tod < nightTo)
    else
        inNight = (tod >= nightFrom and tod < nightTo)
    end
    if inNight then
        Log.Info(MODULE, "Short cycle: skipping night core", {from = tod, to = nightTo})
        TimeOfDay.SetTOD(nightTo)
    end
end

--- Baseline enforcement tick: ensures time keeps advancing correctly
--- @param dt number Delta time in seconds
function TimeOfDay.BaselineEnforceTick(dt)
    if not Actors.IsOnCourse() then return end
    if currentSpeedMode == "paused" then return end
    
    baselineEnforceAccum = baselineEnforceAccum + dt
    if baselineEnforceAccum < 3.0 then return end
    baselineEnforceAccum = 0
    
    -- Skip speed enforcement only while Transitions actually controls speed.
    -- Its slow-time applies in normal mode only (fast-forward is exempt by
    -- design), so deferring unconditionally left nobody writing speed when a
    -- course loaded into a slow window in fast mode: the sky kept its
    -- spawn-default Simulation Speed (~1.0, a real-time crawl) until a manual
    -- Alt+T (the "stuck clock" bug, 2026-07-06/07, TOD frozen at 1739 and
    -- 530 for 70-90 s).
    if currentSpeedMode == "normal" then
        local Transitions = nil
        pcall(function() Transitions = require("systems.transitions") end)
        if Transitions and Transitions.IsInSlowWindow and Transitions.IsInSlowWindow() then
            return  -- Let transitions module control speed
        end
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
    
    -- Ensure time is animating (unless paused, or a photo session froze it:
    -- SetPhotoFreeze deliberately leaves currentSpeedMode alone, so without
    -- this gate the enforcer re-animated the sun ~3s into every shoot)
    if currentSpeedMode ~= "paused" and not photoFrozen then
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
    local tod = TimeOfDay.GetCurrentTOD()

    -- Debug short cycle first (takes precedence), then night-only
    TimeOfDay.ShortCycleEnforce(tod)
    TimeOfDay.NightOnlyEnforce(tod)

    -- A photo freeze that failed at the open instant retries here
    photoFreezeRetryTick()

    -- Baseline enforcement
    TimeOfDay.BaselineEnforceTick(dt)
end

--- Apply starting time of day if configured
function TimeOfDay.OnCourseLoad()
    -- Fresh course, fresh photo-freeze latch (mirrors light_cycle's
    -- metering-latch reset). With persistence enabled main only calls this
    -- when restore fails; the restore-success path calls ResetPhotoFreeze
    -- from main's setup block.
    TimeOfDay.ResetPhotoFreeze()

    if Config.TimeOfDay.StartingTOD then
        Log.Info(MODULE, "Applying starting TOD", {tod = Config.TimeOfDay.StartingTOD})
        TimeOfDay.SetTOD(Config.TimeOfDay.StartingTOD)
    end

    -- Skip modes: if the course loaded inside a skipped segment, jump now
    TimeOfDay.ShortCycleEnforce()
    TimeOfDay.NightOnlyEnforce()

    -- Ensure default speed
    TimeOfDay.SetSpeed(Config.TimeOfDay.DefaultSpeed)
    TimeOfDay.Resume()
end

-- Initialize on load
TimeOfDay.Init()

return TimeOfDay
