-- TXR Weather Mod v3.0
-- systems/stars.lua
-- Phase 12: High-resolution (HD) real-stars night sky
--
-- SAFE REWRITE (2026-06-24). The old version resolved the Real_Stars texture asset
-- and wrote it into the OBJECT-typed "Real Stars Texture" UProperty off-thread
-- during course BeginPlay, corrupting UE4SS reflection -> 0xC0000005 crash. Even a
-- game-thread wrap didn't save it.
--
-- New approach (from the UE4SS_ObjectDump + UDS v9.5 docs): we do NOT touch the
-- texture object at all. "Real Stars Texture" is a SoftObjectProperty already
-- assigned in UDS, and "Static Properties - Stars" is UDS's own function that
-- resolves that soft-ref and applies it (SoftObjectToObject -> Cast Texture2D ->
-- SetScalarParameterValue, all internally). So we only:
--   1. set "Simulate Real Stars" = true (a primitive bool), + optional intensity/tiling,
--   2. call "Static Properties - Stars" on the GAME THREAD (UDS loads its own texture),
--   3. defer past the BeginPlay window with a settle gate (the shadow-module lesson).
-- No asset load, no object-typed write, nothing during construction.

local Stars = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")
local Config = require("config")

local Actors = nil  -- lazy

local MODULE = "Stars"

-- ============== UDS PROPERTY / FUNCTION NAMES (verified from dump) ==============
local PROP_SIMULATE_REAL_STARS = "Simulate Real Stars"   -- Bool
local PROP_STARS_INTENSITY     = "Stars Intensity"       -- Double
local PROP_STARS_TILING        = "Stars Tiling"          -- Double
local FN_STATIC_STARS          = "Static Properties - Stars"  -- applies stars (loads soft-ref texture itself)

-- Ticks on course before applying, to clear the BeginPlay construction window.
-- 8 Hz loop, so 32 ticks ~= 4s.
local SETTLE_TICKS = 32

-- ============== CONFIG (filled in Init) ==============
local enabled = true
local intensity = nil  -- nil = keep UDS default
local tiling = nil     -- nil = keep UDS default

-- ============== STATE ==============
local isInitialized = false
local applied = false
local settleTicks = 0
local appliedThisCourse = false

-- ============== INTERNAL ==============

local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

local function getUDS()
    local actors = getActors()
    if not actors then return nil end
    return actors.GetUDS()
end

--- The actual UDS work. MUST run on the game thread. NO asset load, NO object
--- write - only a primitive bool/doubles plus UDS's own apply function.
local function enableStarsOnGameThread()
    local uds = getUDS()
    if not uds then return end

    pcall(function() uds[PROP_SIMULATE_REAL_STARS] = true end)
    if intensity ~= nil then pcall(function() uds[PROP_STARS_INTENSITY] = intensity end) end
    if tiling ~= nil then pcall(function() uds[PROP_STARS_TILING] = tiling end) end

    -- UDS resolves its own Real Stars Texture soft-ref and applies it here.
    local fn = nil
    pcall(function() fn = uds[FN_STATIC_STARS] end)
    if fn then
        local ok, err = pcall(function() fn(uds) end)
        if ok then
            Log.Debug(MODULE, "Static Properties - Stars called")
        else
            Log.Warn(MODULE, "Static Properties - Stars failed", { error = tostring(err) })
        end
    else
        Log.Warn(MODULE, "Static Properties - Stars function not found")
    end
end

local function applyStars()
    if not getUDS() then return false end
    if ExecuteInGameThread then
        pcall(function() ExecuteInGameThread(enableStarsOnGameThread) end)
    else
        enableStarsOnGameThread()
    end
    return true
end

-- ============== PUBLIC API ==============

function Stars.Init()
    if isInitialized then return true end
    local cfg = Config.Stars
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.Intensity ~= nil then intensity = cfg.Intensity end
        if cfg.Tiling ~= nil then tiling = cfg.Tiling end
    end
    isInitialized = true
    State.SetModuleStatus("stars", true)
    Log.Info(MODULE, "Initializing stars module", { enabled = enabled })
    return true
end

--- Called per course load. Just re-arms the settle gate; the actual apply happens
--- in Tick, well after BeginPlay (NOT during the construction window).
function Stars.Setup()
    settleTicks = 0
    appliedThisCourse = false
end

--- Per-tick: apply once per course, after the settle gate, if enabled.
function Stars.Tick()
    if not isInitialized or not enabled then return end

    local actors = getActors()
    if not actors or not actors.IsOnCourse() then
        settleTicks = 0
        appliedThisCourse = false
        return
    end

    settleTicks = settleTicks + 1
    if not appliedThisCourse and settleTicks >= SETTLE_TICKS then
        appliedThisCourse = true
        applied = applyStars()
        if applied then
            Log.Info(MODULE, "Stars applied (real-stars enabled, deferred past BeginPlay)")
        end
    end
end

--- Set star intensity at runtime (primitive write + re-apply).
function Stars.SetIntensity(value)
    intensity = value
    local uds = getUDS()
    if uds then pcall(function() uds[PROP_STARS_INTENSITY] = value end) end
    applyStars()
    Log.Info(MODULE, "Stars intensity set", { intensity = value })
    return true
end

function Stars.GetStatus()
    return {
        initialized = isInitialized,
        enabled = enabled,
        applied = applied,
        appliedThisCourse = appliedThisCourse,
        intensity = intensity,
        tiling = tiling,
    }
end

function Stars.IsInitialized()
    return isInitialized
end

return Stars
