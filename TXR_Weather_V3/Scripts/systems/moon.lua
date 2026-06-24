-- TXR Weather Mod v3.0
-- systems/moon.lua
-- Moon appearance: realistic moon phases (instead of a flat full disc), optional
-- phase change over time, and a scale knob for a bigger, more cinematic moon. All
-- of this is sky-rendered on the moon (no MID, no weighted blendable), so it works
-- in TXR like the stars.
--
-- Applied via UDS's "Static Properties - Moon" on the game thread, deferred past
-- BeginPlay by a settle gate (the proven Stars / WindDebris / LightRays pattern).
--
-- Note: Moon Phase Changes Over Time and a fixed Moon Phase conflict (over-time
-- wins). Set PhaseOverTime=false if you want to pin a specific phase.

local Moon = {}

local Log = require("core.logging")
local Config = require("config")

local Actors = nil  -- lazy

local MODULE = "Moon"

-- UDS property / function names (verified from UE4SS_ObjectDump)
local PROP_RENDER_PHASES  = "Render Moon Phases"            -- Bool
local PROP_PHASE_OVERTIME = "Moon Phase Changes Over Time"  -- Bool
local PROP_PHASE          = "Moon Phase"                    -- Double 0-1
local PROP_SCALE          = "Moon Scale"                    -- Double
local PROP_CONTRAST       = "Moon Phase Contrast"           -- Double
local FN_STATIC           = "Static Properties - Moon"

local SETTLE_TICKS = 32  -- ~4s at 8 Hz before applying, to clear the BeginPlay window

local initialized = false
local enabled = false
local renderPhases = true
local phaseOverTime = true
local phase = nil      -- nil = leave to UDS / date
local scale = nil      -- nil = UDS default
local contrast = nil   -- nil = UDS default
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

local function getUDS()
    local actors = getActors()
    if not actors then return nil end
    return actors.GetUDS()
end

local function applyOnGameThread()
    local uds = getUDS()
    if not uds then return end

    pcall(function() uds[PROP_RENDER_PHASES] = renderPhases end)
    pcall(function() uds[PROP_PHASE_OVERTIME] = phaseOverTime end)
    if phase ~= nil then pcall(function() uds[PROP_PHASE] = phase end) end
    if scale ~= nil then pcall(function() uds[PROP_SCALE] = scale end) end
    if contrast ~= nil then pcall(function() uds[PROP_CONTRAST] = contrast end) end

    local fn = nil
    pcall(function() fn = uds[FN_STATIC] end)
    if fn then
        local ok, err = pcall(function() fn(uds) end)
        if ok then
            Log.Debug(MODULE, "Static Properties - Moon called")
        else
            Log.Warn(MODULE, "Static Properties - Moon failed", { error = tostring(err) })
        end
    else
        Log.Warn(MODULE, "Static Properties - Moon function not found")
    end
end

local function apply()
    if not getUDS() then return false end
    if ExecuteInGameThread then
        pcall(function() ExecuteInGameThread(applyOnGameThread) end)
    else
        applyOnGameThread()
    end
    return true
end

-- ============== PUBLIC API ==============

function Moon.Init()
    if initialized then return true end
    local cfg = Config.Moon
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.RenderPhases ~= nil then renderPhases = cfg.RenderPhases end
        if cfg.PhaseOverTime ~= nil then phaseOverTime = cfg.PhaseOverTime end
        if cfg.Phase ~= nil then phase = cfg.Phase end
        if cfg.Scale ~= nil then scale = cfg.Scale end
        if cfg.Contrast ~= nil then contrast = cfg.Contrast end
    end
    initialized = true
    Log.Info(MODULE, "Initializing moon module", { enabled = enabled })
    return true
end

--- Per-tick: apply once per course, after the settle gate, if configured on.
function Moon.Tick()
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
            Log.Info(MODULE, "Moon appearance applied")
        end
    end
end

function Moon.GetStatus()
    return {
        initialized = initialized,
        enabled = enabled,
        applied = applied,
        renderPhases = renderPhases,
        phaseOverTime = phaseOverTime,
        scale = scale,
    }
end

return Moon
