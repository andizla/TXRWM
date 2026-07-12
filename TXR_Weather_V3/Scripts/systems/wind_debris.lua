-- TXR Weather Mod v3.0
-- systems/wind_debris.lua
-- Enables UDW's wind debris: small particles (leaves/dust) flying through the air,
-- scaled by the Wind Intensity of the current weather state (so it shows in windy /
-- stormy presets). It's a Niagara effect, the same render path as rain, so it works
-- in TXR (unlike the post-process effects).
--
-- Enabling at runtime needs UDW's "Static Properties - Wind Debris" to apply (the
-- static-properties footgun). We set the bool (+ optional spawn count) and call that
-- function on the GAME THREAD, deferred past BeginPlay by a settle gate (same safe
-- pattern as Stars / Moon). This is separate from the do-not-touch rain/dry
-- pipeline in weather.lua and does not interact with it.

local WindDebris = {}

local Log = require("core.logging")
local Config = require("config")

local Actors = nil  -- lazy

local MODULE = "WindDebris"

-- UDW property / function names (verified from UE4SS_ObjectDump)
local PROP_ENABLE = "Enable Wind Debris"               -- Bool
local PROP_SPAWN  = "Wind Debris Particle Spawn Count"  -- Double (nil = keep UDW default)
local FN_STATIC   = "Static Properties - Wind Debris"   -- applies/creates the debris Niagara
-- Diagnostics: the Niagara component object and the current wind intensity.
local PROP_PARTICLES = "Wind Debris Particles"          -- Object (nil = not created)
local PROP_WIND      = "Wind Intensity"                 -- Double (current weather-state wind, 0-10)

local SETTLE_TICKS = 32  -- ~4s at 8 Hz before applying, to clear the BeginPlay window
local DIAG_INTERVAL_TICKS = 24  -- ~3s readback cadence while enabled + Debug

local initialized = false
local enabled = false
local spawnCount = nil  -- nil = keep UDW default
local applied = false
local settleTicks = 0
local appliedThisCourse = false
local diagTicks = 0

local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

local function getUDW()
    local actors = getActors()
    if not actors then return nil end
    return actors.GetUDW()
end

--- Read back UDW state to classify a no-show. enable=false -> didn't stick;
--- particlesNil=true -> Niagara not created (needs a make step); wind low -> just
--- not windy enough (debris scales with Wind Intensity).
local function logReadback(tag)
    local udw = getUDW()
    if not udw then return end
    local function rd(p)
        local v = nil
        pcall(function() v = udw[p] end)
        return v
    end
    local parts = rd(PROP_PARTICLES)
    Log.Info(MODULE, "Wind debris readback", {
        tag = tag or "tick",
        enable = tostring(rd(PROP_ENABLE)),
        spawnCount = tostring(rd(PROP_SPAWN)),
        windIntensity = tostring(rd(PROP_WIND)),
        particlesNil = (parts == nil),
    })
end

--- Set the bool (+ optional spawn count) and run UDW's apply function. Game thread only.
local function applyOnGameThread()
    local udw = getUDW()
    if not udw then return end

    pcall(function() udw[PROP_ENABLE] = true end)
    if spawnCount ~= nil then pcall(function() udw[PROP_SPAWN] = spawnCount end) end

    local fn = nil
    pcall(function() fn = udw[FN_STATIC] end)
    if fn then
        local ok, err = pcall(function() fn(udw) end)
        if ok then
            Log.Debug(MODULE, "Static Properties - Wind Debris called")
        else
            Log.Warn(MODULE, "Static Properties - Wind Debris failed", { error = tostring(err) })
        end
    else
        Log.Warn(MODULE, "Static Properties - Wind Debris function not found")
    end

    logReadback("apply")
end

local function apply()
    if not getUDW() then return false end
    if ExecuteInGameThread then
        pcall(function() ExecuteInGameThread(applyOnGameThread) end)
    else
        applyOnGameThread()
    end
    return true
end

-- ============== PUBLIC API ==============

function WindDebris.Init()
    if initialized then return true end
    local cfg = Config.WindDebris
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.SpawnCount ~= nil then spawnCount = cfg.SpawnCount end
    end
    initialized = true
    Log.Info(MODULE, "Initializing wind debris module", { enabled = enabled })
    return true
end

--- Per-tick: enable once per course, after the settle gate, if configured on.
function WindDebris.Tick()
    if not initialized or not enabled then return end

    local actors = getActors()
    if not actors or not actors.IsOnCourse() then
        settleTicks = 0
        appliedThisCourse = false
        return
    end

    settleTicks = settleTicks + 1
    if not appliedThisCourse and settleTicks >= SETTLE_TICKS then
        appliedThisCourse = true
        applied = apply()
        if applied then
            Log.Info(MODULE, "Wind debris applied")
        end
    end

    -- Periodic readback so we can watch wind intensity as you cycle presets.
    if appliedThisCourse and (Config.WindDebris or {}).Debug then
        diagTicks = diagTicks + 1
        if diagTicks >= DIAG_INTERVAL_TICKS then
            diagTicks = 0
            logReadback("tick")
        end
    end
end

function WindDebris.GetStatus()
    return {
        initialized = initialized,
        enabled = enabled,
        applied = applied,
        appliedThisCourse = appliedThisCourse,
        spawnCount = spawnCount,
    }
end

return WindDebris
