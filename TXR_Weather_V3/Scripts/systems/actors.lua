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
-- window (FindFirstOf) reads dying objects - the suspected cause of the
-- intermittent course-to-garage transition crash (access violation inside the
-- object search; see the "UDS found but not valid" spam right before each one).
-- Discovery is suspended for the window, with a time failsafe in case no sky
-- actor ever begins play (menu-only worlds).
local suspendedForTeardown = false
local suspendedAt = 0
local SUSPEND_FAILSAFE_SECONDS = 15

-- ============== INTERNAL FUNCTIONS ==============

--- Get world tag from actor's world object
--- @param actor userdata
--- @return string "course", "pa", "outgame", or "unknown"
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
---   1. BP_OutGameGarageManager_C - the garage manager (garage screen specifically).
---   2. BP_OutGameMode_C           - the outgame GameMode (distinct from the course's
---      BP_RaceGameMode_C). Covers car-select/menus too and spawns early in the
---      outgame level load, so it usually detects sooner than the garage manager.
--- @return boolean
local function isInGarage()
    -- During map teardown, don't probe the object array - serve the cache
    if suspendedForTeardown then
        return garageCheckCache.isInGarage
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
        Log.Error(MODULE, "FindFirstOf not available - not running in UE4SS?")
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
        Log.Warn(MODULE, "UDS found but not valid")
        return false
    end
    
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
        State.SetUDS(uds)
        return false
    end
    
    -- Both found and valid!
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
--- @return string "course", "pa", "outgame", or "unknown"
function Actors.GetWorldTag()
    return State.GetWorldContext()
end

--- Check if we're in the PA scene. There is NO separate "pa" world: the PA
--- lives in the same outgame world as the garage but has its OWN working
--- UDS/UDW. Discovery succeeding there is the reliable signal - the garage's
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

--- Suspend discovery while the old world tears down (from LoadMapPreHook)
function Actors.SuspendDiscovery()
    if not suspendedForTeardown then
        suspendedForTeardown = true
        suspendedAt = os.time()
        Log.Info(MODULE, "Discovery suspended (map teardown)")
    end
end

--- Resume discovery once a new world is constructing (from BeginPlay hooks)
function Actors.ResumeDiscovery()
    if suspendedForTeardown then
        suspendedForTeardown = false
        Log.Info(MODULE, "Discovery resumed (new world alive)")
    end
end

--- Whether the map-teardown window is active (world being destroyed)
--- @return boolean
function Actors.IsDiscoverySuspended()
    return suspendedForTeardown
end

--- Called when a map loads (from BeginPlay hook)
function Actors.OnMapLoad()
    Log.Info(MODULE, "Map load detected - starting actor discovery")
    suspendedForTeardown = false
    isSearching = true
    discoveryAttempts = 0
    
    -- Attempt immediate discovery
    if discoverActors() then
        Log.Info(MODULE, "Actors found on map load")
    else
        Log.Debug(MODULE, "Actors not immediately available, will retry")
    end
end

--- Called when a map unloads (from EndPlay hook)
function Actors.OnMapUnload()
    Log.Info(MODULE, "Map unload detected - clearing actors")
    State.ClearActors()
    State.SetWorldContext("unknown")
    isSearching = false
    discoveryAttempts = 0
    
    -- Reset garage cache
    garageCheckCache.isInGarage = false
    garageCheckCache.lastCheck = 0
end

--- Tick function - called from main loop
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
        Log.Warn(MODULE, "Cannot set UDS property - no actor", {property = propertyName})
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
        Log.Warn(MODULE, "Cannot set UDW property - no actor", {property = propertyName})
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
        Log.Warn(MODULE, "Cannot call UDW function - no actor", {func = functionName})
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
