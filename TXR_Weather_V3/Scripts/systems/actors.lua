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

-- Map-teardown guard. Between LoadMapPreHook (old world starts dying) and the
-- next sky-actor BeginPlay (new world constructing), the game thread is
-- destroying the object array. Searching it from the async tick during that
-- window (FindFirstOf) reads dying objects, the suspected cause of the
-- intermittent course-to-garage transition crash (access violation inside the
-- object search; see the "UDS found but not valid" spam right before each one).
-- Discovery is suspended for the window, with a time failsafe in case no sky
-- actor ever begins play (menu-only worlds).
local suspendedForTeardown = false
local suspendedAt = 0
local SUSPEND_FAILSAFE_SECONDS = 15

-- Outgame settle (2026-07-21, the map-open crash fix). In the GARAGE outgame
-- world the UDS always resolves but its UDW never validates ("UDW found but
-- not valid" once per second, forever), while in the PA outgame world both
-- validate within ~2 attempts of world load. So after the garage signature
-- repeats, further polling is pure exposure: every FindFirstOf/property read
-- from the async tick can land on an object the map screen's streaming just
-- freed (the 07-18/07-20 dump class). Once settled, discovery goes quiet for
-- the rest of the world's life; every scene change on this game is a map swap,
-- so the next world resets the settle in SuspendDiscovery/OnMapLoad.
local outgameSettled = false
local udwInvalidStreak = 0
local resumedAt = 0
local OUTGAME_SETTLE_STREAK = 2      -- consecutive garage-signature hits
local OUTGAME_SETTLE_MIN_SECONDS = 3 -- never settle before PA discovery could land

-- Event-driven outgame signal: set from main.lua's BeginPlayPreHook when an
-- OutGameGarageManager/OutGameMode actor begins play (game thread, actor in
-- hand, no probing). While set, isInGarage() serves it without ever running
-- its FindFirstOf probe. Cleared with the world.
local garageEventThisWorld = false

-- Course post-race settle (2026-07-21 field find): after a race ends the
-- course world lingers (result/photo screens) with the sky torn down, and
-- rediscovery probed the dead UDS every 2s indefinitely. Once we HAD valid
-- actors in this world and then hit a run of UDS-invalid finds, the sky is
-- gone for this world's life: stop probing. A sky BeginPlay (race retry
-- respawning it) re-runs OnMapLoad and resets this, as does any map swap.
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

    -- GetFullName, NOT tostring: tostring(world) is just "UWorld: 0x..." (the
    -- userdata address, no map path), so the old tostring version never
    -- matched anything and always fell through to "course" here (the
    -- garage-manager probe below rescued outgame detection).
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

--- Force the next isInGarage() call to re-probe instead of returning the cache.
--- Called when cached actors are lost so the first check after a world transition
--- is fresh (no up-to-interval stale window on garage/course entry).
local function invalidateGarageCache()
    garageCheckCache.lastCheck = 0
end

--- Check if we're in the garage / outgame menus (cached for performance).
--- Two signals, both outgame-only (destroyed on travel into a course/PA, so neither
--- can false-positive in-game and re-trigger the night exposure during course entry):
---   1. BP_OutGameGarageManager_C: the garage manager (garage screen specifically).
---   2. BP_OutGameMode_C:           the outgame GameMode (distinct from the course's
---      BP_RaceGameMode_C). Covers car-select/menus too and spawns early in the
---      outgame level load, so it usually detects sooner than the garage manager.
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
local function validateCachedActors()
    -- Teardown window: do not even touch the cached objects. IsValidObject
    -- on a freed object is UNDEFINED and can read true (2026-07-14 beta
    -- crash: the dead course UDS kept "validating" in the PA world until a
    -- property read hit freed memory).
    if suspendedForTeardown then return false end

    local uds = State.GetUDS()
    local udw = State.GetUDW()
    
    if not uds or not udw then
        return false
    end
    
    -- Check if actors are still valid (not destroyed)
    local udsValid = Utils.IsValidObject(uds)
    local udwValid = Utils.IsValidObject(udw)
    
    if not udsValid or not udwValid then
        Log.Info(MODULE, "Cached actors became invalid", {
            udsValid = udsValid,
            udwValid = udwValid
        })
        State.ClearActors()
        invalidateGarageCache()  -- world is changing: re-probe garage/outgame immediately
        return false
    end
    
    return true
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
        -- Course post-race signature: we HAD live actors in this world and
        -- now the found UDS repeatedly fails validation = the sky is torn
        -- down for good (result screens). Settle; a sky BeginPlay or map
        -- swap resets it.
        if hadActorsThisWorld and not garageEventThisWorld then
            udsInvalidStreak = udsInvalidStreak + 1
            if not courseSettled and udsInvalidStreak >= COURSE_SETTLE_STREAK then
                courseSettled = true
                Log.Info(MODULE, "Course discovery settled (sky gone, probes off until next sky/map event)")
            end
        end
        -- EARLY TEARDOWN SUSPENSION (2026-08-10): in a world that HAD
        -- live actors, a found-but-invalid UDS means the world is dying
        -- RIGHT NOW, up to ~2s BEFORE LoadMapPreHook fires (the 08-08
        -- PA-exit timing finding). Crash dumps sit second-exact on this
        -- log line while a GT closure faulted on a freed object (the
        -- +0x0C family). Suspend immediately: drops every cached ref and
        -- closes the pre-hook window for every IsDiscoverySuspended-gated
        -- closure. False positives (post-race result screens) cost
        -- nothing: the sky is gone there anyway and the 15s failsafe
        -- re-arms discovery; SuspendDiscovery resets hadActorsThisWorld,
        -- so this fires once per teardown.
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
        Log.Warn(MODULE, "UDW found but not valid")
        -- EARLY TEARDOWN SUSPENSION (2026-08-10): outside the garage
        -- signature below, a dying UDW in a world that HAD live actors is
        -- the same pre-LoadMapPreHook death window as the UDS branch
        -- above (some exit paths kill the UDW first). Suspend and DROP
        -- the caches instead of falling through to SetUDS, which used to
        -- re-cache a UDS that is dying with its world and kept a doomed
        -- ref alive for the whole window.
        if hadActorsThisWorld and not garageEventThisWorld then
            Actors.SuspendDiscovery()
            return false
        end
        State.SetUDS(uds)
        -- Garage signature: UDS resolves, UDW never validates. In a known
        -- outgame world, repeated hits settle discovery for this world (see
        -- the settle block at the top of the file). The nil-UDW branch above
        -- does NOT count: a PA world mid-init can legitimately show that.
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

--- Check if we're in the PA scene. There is NO separate "pa" world: the PA
--- lives in the same outgame world as the garage but has its OWN working
--- UDS/UDW. Discovery succeeding there is the reliable signal; the garage's
--- UDS never validates, so validated cached actors + outgame context = PA.
--- @return boolean
function Actors.IsInPAScene()
    if State.GetWorldContext() ~= "outgame" then return false end
    return validateCachedActors()
end

--- Check if in outgame (garage/menu)
--- @return boolean
function Actors.IsInOutgame()
    return State.GetWorldContext() == "outgame"
end

--- Check if specifically in garage (using BP_OutGameGarageManager_C detection)
--- @return boolean
function Actors.IsInGarage()
    return isInGarage()
end

--- Force a discovery attempt
--- @return boolean True if actors found
function Actors.Discover()
    return discoverActors()
end

--- Suspend discovery while the old world tears down (from LoadMapPreHook).
--- ALSO drops every cached actor ref on the spot: the EndPlay-driven
--- OnMapUnload does not fire on this game's world swaps, and a ref that
--- survives the swap can falsely validate against freed memory and crash
--- the next property read (the 2026-07-14 PA-transition beta crash, dump
--- rsi = the previous course's UDS). No actor ref may outlive its world.
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
        Log.Info(MODULE, "Discovery resumed (new world alive)")
    end
end

--- Event-driven outgame signal from main.lua's BeginPlayPreHook: an
--- OutGameGarageManager/OutGameMode actor is beginning play in the new world
--- (game-thread context, actor already in hand). Marks the world outgame so
--- the async garage probe never needs to run, and lets the garage settle
--- logic engage. PA worlds carry these managers too; that matches what the
--- old FindFirstOf probe answered there, and IsInPAScene is unaffected (it
--- keys on validated actors, which only the PA scene provides).
function Actors.OnOutgameManagerBeginPlay()
    garageEventThisWorld = true
    garageCheckCache.isInGarage = true
    garageCheckCache.lastCheck = os.clock()
end

--- Mid-course weather-cluster churn signal (weather.lua's ClientRestart
--- hook, 2026-08-10 20:14 crash): the game rebuilds the weather actor
--- MID-COURSE (a fresh UDW instance appeared 4x in the 13:55 session and
--- 13s before the 20:14:28 crash), so every cached actor ref may be a
--- corpse the moment this fires. Drop the caches WITHOUT suspending:
--- discovery stays live in this world and re-finds within ~1s, and the
--- 5s revalidation cycle can no longer be the first (faulting) touch of
--- a freed object. NOT a teardown: settle/garage state stays untouched.
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

--- Called when a map loads (from BeginPlay hook)
function Actors.OnMapLoad()
    Log.Info(MODULE, "Map load detected: starting actor discovery")
    suspendedForTeardown = false
    isSearching = true
    discoveryAttempts = 0
    outgameSettled = false
    courseSettled = false
    hadActorsThisWorld = false
    udwInvalidStreak = 0
    udsInvalidStreak = 0
    resumedAt = os.time()
    
    -- Attempt immediate discovery
    if discoverActors() then
        Log.Info(MODULE, "Actors found on map load")
    else
        Log.Debug(MODULE, "Actors not immediately available, will retry")
    end
end

--- Called when a map unloads (from EndPlay hook)
function Actors.OnMapUnload()
    Log.Info(MODULE, "Map unload detected: clearing actors")
    State.ClearActors()
    State.SetWorldContext("unknown")
    isSearching = false
    discoveryAttempts = 0
    
    -- Reset garage cache + settle/event state
    garageCheckCache.isInGarage = false
    garageCheckCache.lastCheck = 0
    garageEventThisWorld = false
    outgameSettled = false
    courseSettled = false
    hadActorsThisWorld = false
    udwInvalidStreak = 0
    udsInvalidStreak = 0
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

    -- Settled (garage determined, or course sky gone post-race): zero object
    -- touches until the next sky BeginPlay / map load
    if (outgameSettled or courseSettled) and not State.HasActors() then
        return
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

--- Safely read a property from UDS
--- @param propertyName string
--- @param default any
--- @return any value, boolean success
function Actors.GetUDSProperty(propertyName, default)
    local uds = Actors.GetUDS()
    if not uds then
        return default, false
    end
    return Utils.SafeGetProperty(uds, propertyName, default)
end

--- Safely write a property to UDS
--- @param propertyName string
--- @param value any
--- @return boolean success
function Actors.SetUDSProperty(propertyName, value)
    local uds = Actors.GetUDS()
    if not uds then
        Log.Warn(MODULE, "Cannot set UDS property: no actor", {property = propertyName})
        return false
    end
    
    local success = Utils.SafeSetProperty(uds, propertyName, value)
    if success then
        Log.Debug(MODULE, "Set UDS property", {property = propertyName, value = tostring(value)})
    else
        Log.Error(MODULE, "Failed to set UDS property", {property = propertyName})
    end
    return success
end

--- Safely read a property from UDW
--- @param propertyName string
--- @param default any
--- @return any value, boolean success
function Actors.GetUDWProperty(propertyName, default)
    local udw = Actors.GetUDW()
    if not udw then
        return default, false
    end
    return Utils.SafeGetProperty(udw, propertyName, default)
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

--- Call a function on UDW actor
--- @param functionName string
--- @param ... any Arguments
--- @return any result, boolean success
function Actors.CallUDWFunction(functionName, ...)
    local udw = Actors.GetUDW()
    if not udw then
        Log.Warn(MODULE, "Cannot call UDW function: no actor", {func = functionName})
        return nil, false
    end
    
    local fn, found = Utils.SafeGetFunction(udw, functionName)
    if not found then
        Log.Error(MODULE, "UDW function not found", {func = functionName})
        return nil, false
    end
    
    local args = {...}
    local success, result = pcall(function()
        return fn(table.unpack(args))
    end)
    
    if success then
        Log.Debug(MODULE, "Called UDW function", {func = functionName})
        return result, true
    else
        Log.Error(MODULE, "UDW function call failed", {func = functionName, error = tostring(result)})
        return nil, false
    end
end

-- Initialize on load
Actors.Init()

return Actors
