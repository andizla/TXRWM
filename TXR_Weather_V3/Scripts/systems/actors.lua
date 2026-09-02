-- TXR Weather Mod v3.0
-- systems/actors.lua
-- Actor discovery and management for UDS (Ultra Dynamic Sky) and UDW (Ultra Dynamic Weather)

local Actors = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local Utils = require("core.utils")
local State = require("core.state")
local Config = require("config")

local MODULE = "Actors"

-- ============== CONSTANTS ==============
local UDS_CLASS_NAME = "Ultra_Dynamic_Sky_C"
local UDW_PROPERTY_NAME = "Ultra Dynamic Weather"

-- ============== STATE ==============
local discoveryAttempts = 0
local lastDiscoveryTime = 0
local isSearching = false

-- Map-teardown guard. Between LoadMapPreHook (old world dying) and the next
-- sky-actor BeginPlay (new world constructing) the game thread is destroying
-- the object array; an async FindFirstOf in that window reads dying objects
-- (the suspected cause of the intermittent course-to-garage crash: access
-- violation inside the object search, "UDS found but not valid" spam right
-- before each one). Discovery is suspended for the window, with a time
-- failsafe for worlds where no sky actor ever begins play (menu-only).
local suspendedForTeardown = false
local suspendedAt = 0
local SUSPEND_FAILSAFE_SECONDS = 15

-- Outgame settle (2026-07-21, the map-open crash fix). In the garage outgame
-- world the UDS resolves but its UDW never validates ("UDW found but not
-- valid" once per second, forever); in the PA outgame world both validate
-- within ~2 attempts. After the garage signature repeats, further polling is
-- pure exposure (every async FindFirstOf/property read can land on an object
-- the map screen's streaming just freed: the 07-18/07-20 dump class), so
-- discovery goes quiet for the rest of the world's life. Every scene change
-- on this game is a map swap, and SuspendDiscovery resets the settle.
local outgameSettled = false
local udwInvalidStreak = 0
local resumedAt = 0
-- Garage settle. The garage's UDS never gets a valid UDW; the PA's does, a
-- few seconds after its UDS validates. Two hits inside 3 s settled the
-- world before the PA's UDW was up, and a settled world was never probed
-- again, so the PA went undetected: no time carry, no PA autosave, and the
-- course returned to its exit time. Settle later, and keep one slow probe
-- alive afterwards (OUTGAME_REPROBE_S) for a PA scene that validates late
-- or is entered from the garage menus.
local OUTGAME_SETTLE_STREAK = 6       -- consecutive garage-signature hits
local OUTGAME_SETTLE_MIN_SECONDS = 12 -- never settle before PA discovery could land
local OUTGAME_REPROBE_S = 30          -- settled outgame world: one probe per this

-- Event-driven outgame signal: set from main.lua's BeginPlayPreHook when an
-- OutGameGarageManager/OutGameMode actor begins play (game thread, actor in
-- hand, no probing). While set, isInGarage() serves it without ever running
-- its FindFirstOf probe. Cleared with the world.
local garageEventThisWorld = false

-- Course post-race settle (2026-07-21 field find): after a race the course
-- world lingers (result/photo screens) with the sky torn down, and
-- rediscovery probed the dead UDS every 2s indefinitely. Once this world had
-- valid actors and then hits a run of UDS-invalid finds, the sky is gone for
-- the world's life: stop probing. A map swap resets this (SuspendDiscovery)
-- and a successful discovery clears it.
local courseSettled = false
local hadActorsThisWorld = false
local udsInvalidStreak = 0
local udsInvalidWarnAt = 0.0   -- warn throttle (menu worlds spam 1-2Hz forever)
local COURSE_SETTLE_STREAK = 5

-- ============== INTERNAL FUNCTIONS ==============

--- Get world tag from actor's world object
--- @param actor userdata
--- @return string "course", "outgame", or "unknown"
local function getWorldTagFromActor(actor)
    if not Utils.IsValidObject(actor) then return "unknown" end

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

    -- GetFullName, not tostring: tostring(world) is "UWorld: 0x..." (address,
    -- no map path), so a tostring match never fired and always fell through
    -- to "course".
    local ws = nil
    pcall(function() ws = worldObj:GetFullName() end)

    if type(ws) == "string" then
        local lw = ws:lower()
        -- There is NO separate "pa" world: the PA scene lives inside the
        -- outgame world (see Actors.IsInPAScene).
        if lw:find("garage") or lw:find("outgame") or lw:find("ls_") then
            return "outgame"
        end
    end

    return "course"
end

-- Garage/outgame detection cache. Interval kept short so exposure brightens
-- quickly on entry (the garage/menu wants the night gain); the previous 5 s let
-- the scene sit on the stale daytime exposure for several seconds after entry.
local garageCheckCache = {
    isInGarage = false,
    lastCheck = 0,
    checkInterval = 1.5  -- seconds
}

--- Force the next isInGarage() call to re-probe: called when cached actors
--- are lost, so the first check after a world transition is fresh.
local function invalidateGarageCache()
    garageCheckCache.lastCheck = 0
end

--- In the garage / outgame menus? (cached). Two signals, both outgame-only
--- (destroyed on travel into a course/PA, so neither can false-positive
--- in-game and re-trigger the night exposure during course entry):
---   1. BP_OutGameGarageManager_C: the garage screen specifically.
---   2. BP_OutGameMode_C: the outgame GameMode (the course runs
---      BP_RaceGameMode_C); covers car-select/menus too and spawns early in
---      the outgame level load, so it usually detects sooner.
--- @return boolean
local function isInGarage()
    -- During map teardown, don't probe the object array; serve the cache
    if suspendedForTeardown then
        return garageCheckCache.isInGarage
    end

    -- Event-driven fast path: the outgame managers' BeginPlay already told us
    -- (via main.lua, on the game thread). No probe needed for this world.
    if garageEventThisWorld then
        return true
    end

    local now = os.clock()

    -- Return cached value if checked recently
    if now - garageCheckCache.lastCheck < garageCheckCache.checkInterval then
        return garageCheckCache.isInGarage
    end

    garageCheckCache.lastCheck = now

    local matched = nil
    pcall(function()
        local gm = FindFirstOf("BP_OutGameGarageManager_C")
        if gm and gm.IsValid and gm:IsValid() then matched = "garage_manager" return end
        local om = FindFirstOf("BP_OutGameMode_C")
        if om and om.IsValid and om:IsValid() then matched = "outgame_mode" end
    end)

    garageCheckCache.isInGarage = (matched ~= nil)

    if garageCheckCache.isInGarage then
        Log.Debug(MODULE, "Outgame detected (garage/menu)", {signal = matched})
    end

    return garageCheckCache.isInGarage
end

--- Attempt to find the UDS actor in the world
--- @return userdata|nil UDS actor or nil
local function findUDSActor()
    -- Check if FindFirstOf is available (UE4SS function)
    if not FindFirstOf then
        Log.Error(MODULE, "FindFirstOf not available: not running in UE4SS?")
        return nil
    end
    
    local success, result = pcall(function()
        return FindFirstOf(UDS_CLASS_NAME)
    end)
    
    if success and result then
        Log.Debug(MODULE, "FindFirstOf returned result", {
            class = UDS_CLASS_NAME,
            address = Utils.FormatAddress(result)
        })
        return result
    elseif not success then
        Log.Error(MODULE, "FindFirstOf failed: " .. tostring(result))
    end
    
    return nil
end

--- Get UDW component from UDS actor
--- @param udsActor userdata Valid UDS actor
--- @return userdata|nil UDW actor or nil
local function getUDWFromUDS(udsActor)
    if not Utils.IsValidObject(udsActor) then
        return nil
    end
    
    local udw, success = Utils.SafeGetProperty(udsActor, UDW_PROPERTY_NAME, nil)
    
    if success and udw then
        Log.Debug(MODULE, "Got UDW from UDS", {
            property = UDW_PROPERTY_NAME,
            address = Utils.FormatAddress(udw)
        })
        return udw
    end
    
    return nil
end

--- Validate that cached actors are still valid
--- @return boolean True if both actors are valid
-- Per-tick memo: modules call GetUDS/GetUDW dozens of times per tick and
-- each call re-ran both IsValid checks; one verdict per loop count and
-- actor pair covers them all (a fresh pair from discovery misses the memo).
local validMemoLoop, validMemoUds, validMemoUdw, validMemoResult = -1, nil, nil, false

local function validateCachedActors()
    -- Teardown window: do not even touch the cached objects. IsValidObject
    -- on a freed object is undefined and can read true (2026-07-14 beta
    -- crash: the dead course UDS kept "validating" in the PA world until a
    -- property read hit freed memory).
    if suspendedForTeardown then return false end

    local uds = State.GetUDS()
    local udw = State.GetUDW()
    if uds and udw then
        local loop = State.GetLoopCount()
        if loop == validMemoLoop and uds == validMemoUds and udw == validMemoUdw then
            return validMemoResult
        end
        validMemoLoop, validMemoUds, validMemoUdw = loop, uds, udw
        validMemoResult = Utils.IsValidObject(uds) and Utils.IsValidObject(udw)
        if not validMemoResult then
            Log.Info(MODULE, "Cached actors became invalid")
            State.ClearActors()
            invalidateGarageCache()  -- world is changing: re-probe garage/outgame immediately
        end
        return validMemoResult
    end
    
    return false
end

--- Perform actor discovery
--- @return boolean True if both actors found
local function discoverActors()
    discoveryAttempts = discoveryAttempts + 1
    lastDiscoveryTime = os.time()
    
    if Config.Debug.LogActorDiscovery then
        Log.Debug(MODULE, "Discovery attempt", {attempt = discoveryAttempts})
    end
    
    -- Find UDS
    local uds = findUDSActor()
    if not uds then
        if discoveryAttempts <= 5 or discoveryAttempts % 10 == 0 then
            Log.Debug(MODULE, "UDS not found", {attempt = discoveryAttempts})
        end
        return false
    end
    
    -- Validate UDS
    if not Utils.IsValidObject(uds) then
        -- Throttled: title/menu worlds hold an invalid UDS forever and
        -- neither settle path arms there (4.5 straight minutes of 1-2Hz
        -- warns on 08-31). First hit per world still logs immediately
        -- (crash forensics key on this line's timing).
        local nowW = os.clock()
        if nowW >= udsInvalidWarnAt then
            udsInvalidWarnAt = nowW + 30.0
            Log.Warn(MODULE, "UDS found but not valid (repeats muted 30s)")
        end
        -- Course post-race signature (see courseSettled): live actors
        -- earlier in this world, now a UDS that repeatedly fails validation.
        if hadActorsThisWorld and not garageEventThisWorld then
            udsInvalidStreak = udsInvalidStreak + 1
            if not courseSettled and udsInvalidStreak >= COURSE_SETTLE_STREAK then
                courseSettled = true
                Log.Info(MODULE, "Course discovery settled (sky gone, probes off until next sky/map event)")
            end
        end
        -- Early teardown suspension (2026-08-10): in a world that had live
        -- actors, a found-but-invalid UDS means the world is dying now, up
        -- to ~2s before LoadMapPreHook (the 08-08 PA-exit timing finding;
        -- crash dumps sit second-exact on this log line while a GT closure
        -- faulted on a freed object, the +0x0C family). Suspending drops
        -- every cached ref and closes that window for every
        -- IsDiscoverySuspended-gated closure. False positives (post-race
        -- result screens) cost nothing: the sky is gone there anyway and
        -- the 15s failsafe re-arms discovery. Fires once per teardown
        -- (SuspendDiscovery resets hadActorsThisWorld).
        if hadActorsThisWorld then
            Actors.SuspendDiscovery()
        end
        return false
    end
    udsInvalidStreak = 0

    -- Get UDW from UDS
    local udw = getUDWFromUDS(uds)
    if not udw then
        Log.Warn(MODULE, "UDS found but UDW property not available", {
            udsAddress = Utils.FormatAddress(uds)
        })
        -- Still cache UDS even if UDW not found yet
        State.SetUDS(uds)
        return false
    end
    
    -- Validate UDW
    if not Utils.IsValidObject(udw) then
        -- A settled garage re-probes every 30 s and always lands here:
        -- Debug then, Warn only while the verdict is still open
        if outgameSettled then
            Log.Debug(MODULE, "UDW found but not valid")
        else
            Log.Warn(MODULE, "UDW found but not valid")
        end
        -- Same early teardown suspension as the UDS branch: outside the
        -- garage signature, a dying UDW in a world that had live actors is
        -- the same pre-LoadMapPreHook death window (some exit paths kill
        -- the UDW first). Falling through to SetUDS re-cached a UDS dying
        -- with its world and kept a doomed ref alive for the whole window.
        if hadActorsThisWorld and not garageEventThisWorld then
            Actors.SuspendDiscovery()
            return false
        end
        State.SetUDS(uds)
        -- Garage signature: UDS resolves, UDW never validates (see
        -- outgameSettled). The nil-UDW branch above does not count: a PA
        -- world mid-init can legitimately show that.
        if garageEventThisWorld then
            udwInvalidStreak = udwInvalidStreak + 1
            if not outgameSettled
               and udwInvalidStreak >= OUTGAME_SETTLE_STREAK
               and os.time() - resumedAt >= OUTGAME_SETTLE_MIN_SECONDS then
                outgameSettled = true
                Log.Info(MODULE, "Outgame discovery settled (garage, probes off until next map load)")
            end
        end
        return false
    end

    -- Both found and valid!
    udwInvalidStreak = 0
    udsInvalidStreak = 0
    hadActorsThisWorld = true
    courseSettled = false
    State.SetUDS(uds)
    State.SetUDW(udw)
    
    -- Detect world tag from actor
    local worldTag = getWorldTagFromActor(uds)
    
    -- Also check for garage manager (more reliable than world name)
    if worldTag == "course" and isInGarage() then
        worldTag = "outgame"
        Log.Debug(MODULE, "World tag overridden to outgame due to garage manager")
    end
    
    State.SetWorldContext(worldTag)
    
    Log.Info(MODULE, "Actors discovered successfully", {
        uds = Utils.FormatAddress(uds),
        udw = Utils.FormatAddress(udw),
        worldTag = worldTag,
        attempts = discoveryAttempts
    })
    
    -- Reset attempt counter on success
    discoveryAttempts = 0
    isSearching = false
    
    return true
end

-- ============== PUBLIC API ==============

--- Initialize the actors module
function Actors.Init()
    Log.Info(MODULE, "Initializing actors module")
    discoveryAttempts = 0
    lastDiscoveryTime = 0
    isSearching = false
    State.SetModuleStatus("actors", true)
    return true
end

--- Get UDS actor (cached, validated)
--- @return userdata|nil
function Actors.GetUDS()
    if validateCachedActors() then
        return State.GetUDS()
    end
    return nil
end

--- Get UDW actor (cached, validated)
--- @return userdata|nil
function Actors.GetUDW()
    if validateCachedActors() then
        return State.GetUDW()
    end
    return nil
end

--- Check if we're on a course with valid actors (not in garage)
--- @return boolean
function Actors.IsOnCourse()
    -- First validate actors
    if not validateCachedActors() then
        return false
    end
    
    -- Check if in garage (cached check)
    if isInGarage() then
        return false
    end
    
    return State.IsOnCourse()
end

--- Check if actors are available (quick check without full validation)
--- @return boolean
function Actors.HasActors()
    return State.HasActors()
end

--- Get current world tag
--- @return string "course", "outgame", or "unknown"
function Actors.GetWorldTag()
    return State.GetWorldContext()
end

--- In the PA scene? There is no separate "pa" world: the PA lives in the
--- same outgame world as the garage but has its own working UDS/UDW.
--- Discovery succeeding there is the reliable signal; the garage's UDS
--- never validates, so validated cached actors + outgame context = PA.
--- @return boolean
function Actors.IsInPAScene()
    if State.GetWorldContext() ~= "outgame" then return false end
    return validateCachedActors()
end

--- Check if specifically in garage (using BP_OutGameGarageManager_C detection)
--- @return boolean
function Actors.IsInGarage()
    return isInGarage()
end

--- Suspend discovery while the old world tears down (from LoadMapPreHook)
--- and drop every cached actor ref on the spot: a ref that survives the
--- swap can falsely validate against freed memory and crash the next
--- property read (the 2026-07-14 PA-transition beta crash, dump rsi = the
--- previous course's UDS). No actor ref may outlive its world.
function Actors.SuspendDiscovery()
    if not suspendedForTeardown then
        suspendedForTeardown = true
        suspendedAt = os.time()
        State.ClearActors()
        invalidateGarageCache()
        -- New world coming: reset the settle + event state
        outgameSettled = false
        courseSettled = false
        hadActorsThisWorld = false
        udwInvalidStreak = 0
        udsInvalidStreak = 0
        udsInvalidWarnAt = 0.0   -- new world: first invalid hit logs at once
        garageEventThisWorld = false
        Log.Info(MODULE, "Discovery suspended (map teardown, actor cache dropped)")
    else
        -- A second teardown during an active suspension (bounced out of a
        -- no-signal world before any resume fired): restart the failsafe
        -- clock so it cannot expire mid-teardown of the NEWER world.
        suspendedAt = os.time()
    end
end

--- Resume discovery once a new world is constructing (from BeginPlay hooks)
function Actors.ResumeDiscovery()
    if suspendedForTeardown then
        suspendedForTeardown = false
        resumedAt = os.time()
        -- Fresh world = fresh retry budget: without this a world where
        -- discovery never succeeded (title, menus) carried the exhausted
        -- counter into the next course, which then probed at the slow
        -- PeriodicCheckInterval until its first hit
        discoveryAttempts = 0
        Log.Info(MODULE, "Discovery resumed (new world alive)")
    end
end

--- Outgame signal from main.lua's BeginPlayPreHook (game thread, actor in
--- hand): marks the world outgame so the async garage probe never runs and
--- the garage settle logic can engage. PA worlds carry these managers too,
--- matching what the FindFirstOf probe answered there; IsInPAScene keys on
--- validated actors, which only the PA scene provides, so it is unaffected.
function Actors.OnOutgameManagerBeginPlay()
    garageEventThisWorld = true
    garageCheckCache.isInGarage = true
    garageCheckCache.lastCheck = os.clock()
end

--- Mid-course weather-cluster churn (weather.lua's ClientRestart hook,
--- 2026-08-10 20:14 crash): the game rebuilds the weather actor mid-course
--- (a fresh UDW instance appeared 4x in the 13:55 session and 13s before
--- the 20:14:28 crash), so every cached ref may be a corpse when this
--- fires. Drop the caches without suspending: discovery re-finds within
--- ~1s, and the 5s revalidation can no longer be the first (faulting)
--- touch of a freed object. Not a teardown: settle/garage state stays.
function Actors.OnWeatherClusterChurn()
    State.ClearActors()
    udwInvalidStreak = 0
    udsInvalidStreak = 0
end

--- Whether the map-teardown window is active (world being destroyed)
--- @return boolean
function Actors.IsDiscoverySuspended()
    return suspendedForTeardown
end

--- Tick function, called from main loop
function Actors.Tick()
    -- Map teardown window: leave the object array alone while the old world is
    -- being destroyed. Failsafe-resume in case no sky actor ever begins play.
    if suspendedForTeardown then
        if os.time() - suspendedAt >= SUSPEND_FAILSAFE_SECONDS then
            suspendedForTeardown = false
            Log.Warn(MODULE, "Discovery resume failsafe hit (no BeginPlay seen)")
        else
            return
        end
    end

    -- Settled: the post-race course (sky gone for good) stays quiet until
    -- the next map load; a settled outgame world keeps one slow probe so a
    -- PA scene that validates late, or is entered from the garage menus,
    -- is still found
    if not State.HasActors() then
        if courseSettled then return end
        if outgameSettled then
            if os.time() - lastDiscoveryTime >= OUTGAME_REPROBE_S then
                discoverActors()
            end
            return
        end
    end

    -- If we already have valid actors, just validate periodically
    if State.HasActors() then
        -- Validate every few seconds
        local now = os.time()
        if now - lastDiscoveryTime >= 5 then
            lastDiscoveryTime = now
            if not validateCachedActors() then
                Log.Info(MODULE, "Actors became invalid, will search")
                isSearching = true
            end
        end
        return
    end
    
    -- If not searching and no actors, start searching
    if not isSearching then
        isSearching = true
    end
    
    -- Respect retry limits
    if discoveryAttempts >= Config.ActorDiscovery.MaxRetries then
        -- Only log occasionally after max retries
        if discoveryAttempts == Config.ActorDiscovery.MaxRetries then
            Log.Debug(MODULE, "Max discovery attempts reached, reducing search frequency")
        end
        
        -- Periodic retry at slower rate
        local now = os.time()
        if now - lastDiscoveryTime >= Config.ActorDiscovery.PeriodicCheckInterval then
            discoverActors()
        end
        return
    end
    
    -- Normal retry with interval
    local now = os.time()
    if now - lastDiscoveryTime >= Config.ActorDiscovery.RetryInterval then
        discoverActors()
    end
end

--- Get discovery status for debugging
--- @return table
function Actors.GetStatus()
    return {
        hasUDS = State.GetUDS() ~= nil,
        hasUDW = State.GetUDW() ~= nil,
        isOnCourse = State.IsOnCourse(),
        isInGarage = garageCheckCache.isInGarage,
        isSearching = isSearching,
        discoveryAttempts = discoveryAttempts,
        lastDiscoveryTime = lastDiscoveryTime,
        suspendedForTeardown = suspendedForTeardown,
        outgameSettled = outgameSettled,
        courseSettled = courseSettled,
        garageEvent = garageEventThisWorld,
    }
end

--- Safely write a property to UDW
--- @param propertyName string
--- @param value any
--- @return boolean success
function Actors.SetUDWProperty(propertyName, value)
    local udw = Actors.GetUDW()
    if not udw then
        Log.Warn(MODULE, "Cannot set UDW property: no actor", {property = propertyName})
        return false
    end
    
    local success = Utils.SafeSetProperty(udw, propertyName, value)
    if success then
        Log.Debug(MODULE, "Set UDW property", {property = propertyName, value = tostring(value)})
    else
        Log.Error(MODULE, "Failed to set UDW property", {property = propertyName})
    end
    return success
end

--- Get a function from UDW actor
--- @param functionName string
--- @return function|nil, boolean success
function Actors.GetUDWFunction(functionName)
    local udw = Actors.GetUDW()
    if not udw then
        return nil, false
    end
    return Utils.SafeGetFunction(udw, functionName)
end

-- Initialize on load
Actors.Init()

return Actors
