-- TXR Weather Mod v3.0
-- systems/rainbow.lua
-- Enables UDW's rainbow. It is drawn on a world mesh (the "Rainbow Mesh"
-- component with the 2D / Volumetric rainbow materials), not as a post-process
-- weighted blendable, so unlike Screen Droplets / Frost / Heat Distortion / Sun
-- Lens Flare it renders in TXR (screening rule: a feature with a MID and a WB
-- is post-process and dead here; the rainbow has the MID but no WB).
-- UDW decides when it shows: rain or fog feeding it, camera in direct sun, sun
-- low enough, so it appears as rain clears toward sun. This module enables it,
-- sets the strength caps and calls UDW's rainbow Static Properties bake on the
-- game thread behind a settle gate; UDW drives the strength.

local Rainbow = {}

local Log = require("core.logging")
local GT = require("core.gt")
local Config = require("config")

local Actors = nil  -- lazy

local MODULE = "Rainbow"

-- UDW property / function names (verified from the v1.5 dump / shared types)
local PROP_ENABLE       = "Enable Rainbow"           -- Bool
local PROP_MAX_STRENGTH = "Max Rainbow Strength"     -- Double (0-1 cap on visibility)
local PROP_MASK_CLOUDS  = "Mask Rainbow Above Clouds" -- Double (how visible above cloud layer)
local PROP_MASK_WATER   = "Mask Rainbow Below Water"  -- Double (how visible below water level)
local FN_STATIC         = "Static Properties - Rainbow"

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
        pcall(function() GT.Run(applyOnGameThread) end)
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

--- Course edge (main.lua's debounced lifecycle): re-arm the one-shot.
function Rainbow.OnCourseUnload()
    settleTicks = 0
    appliedThisCourse = false
end

--- Per-tick: enable once per course, after the settle gate, if configured on.
function Rainbow.Tick()
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
            Log.Info(MODULE, "Rainbow enabled (UDW drives visibility from weather)")
        end
    end
end

return Rainbow
