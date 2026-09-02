-- TXR Weather Mod v3.0
-- systems/wind_debris.lua
-- Enables UDW's wind debris: small particles (leaves/dust) scaled by the Wind
-- Intensity of the weather state, so it shows in windy / stormy presets. A
-- Niagara effect on the rain render path, so it works in TXR. Enabling at
-- runtime needs UDW's wind-debris Static Properties bake (the static-properties
-- footgun): set the bool (+ optional spawn count) and call it on the game
-- thread behind a settle gate (the Stars / Moon pattern). Separate from the
-- do-not-touch rain/dry pipeline in weather.lua.

local WindDebris = {}

local Log = require("core.logging")
local GT = require("core.gt")
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

--- Read back UDW state to classify a no-show: enable=false means the write did
--- not stick, particlesNil=true means the Niagara was not created (needs a make
--- step), low wind means it is just not windy enough.
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
        pcall(function() GT.Run(applyOnGameThread) end)
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

--- Course edge (main.lua's debounced lifecycle): re-arm the one-shot.
function WindDebris.OnCourseUnload()
    settleTicks = 0
    appliedThisCourse = false
end

--- Per-tick: enable once per course, after the settle gate, if configured on.
function WindDebris.Tick()
    if not initialized or not enabled then return end

    -- Actors missing = a blip or a real exit: no re-arm here (a photomode
    -- open used to re-run the bake); OnCourseUnload does it
    local actors = getActors()
    if not actors or not actors.IsOnCourse() then return end

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

return WindDebris
