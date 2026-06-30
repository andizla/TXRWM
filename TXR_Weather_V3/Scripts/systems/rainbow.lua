-- TXR Weather Mod v3.0
-- systems/rainbow.lua
-- Enables UDW's rainbow effect. The rainbow is rendered on a world MESH (UDW's
-- "Rainbow Mesh" static-mesh component, drawn with "Rainbow Material 2D" /
-- "Rainbow Material Volumetric"), NOT as a post-process weighted blendable - so
-- unlike Screen Droplets / Frost / Heat Distortion / Sun Lens Flare it renders in
-- TXR. (Screening rule: a feature with a "... MID" + a "... WB"/WeightedBlendable
-- is post-process and dead in TXR; rainbow has the MID but no WB, and has a Mesh
-- + 2D/Volumetric materials, i.e. scene-rendered.)
--
-- UDW decides WHEN a rainbow is visible from the weather state: there must be rain
-- (or fog) feeding it, the camera must be in direct sun (not under overcast), and
-- the sun must be low enough. So this won't show in every weather - it appears
-- naturally as rain clears toward sun, which is exactly the intended behaviour.
--
-- We just enable it + set the strength caps and call UDW's "Static Properties -
-- Rainbow" on the game thread, deferred past BeginPlay by a settle gate (the proven
-- Stars / WindDebris / Moon / LightRays pattern). UDW drives the actual strength.

local Rainbow = {}

local Log = require("core.logging")
local Config = require("config")

local Actors = nil  -- lazy

local MODULE = "Rainbow"

-- UDW property / function names (verified from the v1.5 dump / shared types)
local PROP_ENABLE       = "Enable Rainbow"           -- Bool
local PROP_MAX_STRENGTH = "Max Rainbow Strength"     -- Double (0-1 cap on visibility)
local PROP_MASK_CLOUDS  = "Mask Rainbow Above Clouds" -- Double (how visible above cloud layer)
local PROP_MASK_WATER   = "Mask Rainbow Below Water"  -- Double (how visible below water level)
local FN_STATIC         = "Static Properties - Rainbow"
-- Diagnostics
local PROP_CUR_STRENGTH = "Current Rainbow Strength"  -- Double (UDW-driven, read-only)

local SETTLE_TICKS = 32  -- ~4s at 8 Hz before applying, to clear the BeginPlay window

local initialized = false
local enabled = false
local maxStrength = nil   -- nil = keep UDW default
local maskAboveClouds = nil
local maskBelowWater = nil
local applied = false
local settleTicks = 0
local appliedThisCourse = false

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

local function applyOnGameThread()
    local udw = getUDW()
    if not udw then return end

    pcall(function() udw[PROP_ENABLE] = true end)
    if maxStrength ~= nil then pcall(function() udw[PROP_MAX_STRENGTH] = maxStrength end) end
    if maskAboveClouds ~= nil then pcall(function() udw[PROP_MASK_CLOUDS] = maskAboveClouds end) end
    if maskBelowWater ~= nil then pcall(function() udw[PROP_MASK_WATER] = maskBelowWater end) end

    local fn = nil
    pcall(function() fn = udw[FN_STATIC] end)
    if fn then
        local ok, err = pcall(function() fn(udw) end)
        if ok then
            Log.Debug(MODULE, "Static Properties - Rainbow called")
        else
            Log.Warn(MODULE, "Static Properties - Rainbow failed", { error = tostring(err) })
        end
    else
        Log.Warn(MODULE, "Static Properties - Rainbow function not found")
    end
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

function Rainbow.Init()
    if initialized then return true end
    local cfg = Config.Rainbow
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.MaxStrength ~= nil then maxStrength = cfg.MaxStrength end
        if cfg.MaskAboveClouds ~= nil then maskAboveClouds = cfg.MaskAboveClouds end
        if cfg.MaskBelowWater ~= nil then maskBelowWater = cfg.MaskBelowWater end
    end
    initialized = true
    Log.Info(MODULE, "Initializing rainbow module", { enabled = enabled })
    return true
end

--- Per-tick: enable once per course, after the settle gate, if configured on.
function Rainbow.Tick()
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
            Log.Info(MODULE, "Rainbow enabled (UDW drives visibility from weather)")
        end
    end
end

function Rainbow.GetStatus()
    local cur = nil
    local udw = getUDW()
    if udw then pcall(function() cur = udw[PROP_CUR_STRENGTH] end) end
    return {
        initialized = initialized,
        enabled = enabled,
        applied = applied,
        appliedThisCourse = appliedThisCourse,
        currentStrength = cur,
    }
end

return Rainbow
