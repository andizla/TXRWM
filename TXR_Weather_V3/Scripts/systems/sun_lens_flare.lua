-- TXR Weather Mod v3.0
-- systems/sun_lens_flare.lua
-- Enables UDS's own filmic sun lens flare. This is the sky-drawn flare on the sun
-- (UDS docs note it is separate from the engine's image-based post-process flare),
-- so unlike the screen-space effects it renders in TXR.
--
-- Enabling at runtime needs UDS's "Static Properties - Lens Flare" to apply the
-- change (the static-properties footgun). We set the bool, optionally the type,
-- then call that function on the GAME THREAD, deferred past BeginPlay by a settle
-- gate (the same safe pattern proven by the Stars rewrite). No asset load, no
-- object-typed write.

local LensFlare = {}

local Log = require("core.logging")
local Config = require("config")

local Actors = nil  -- lazy

local MODULE = "LensFlare"

-- UDS property / function names (verified from UE4SS_ObjectDump)
local PROP_ENABLE = "Enable Sun Lens Flare"            -- Bool
local PROP_TYPE   = "Lens Flare Type"                  -- Byte (enum; nil = keep UDS default)
local FN_STATIC   = "Static Properties - Lens Flare"   -- applies the flare (scalar params on the sun)

local SETTLE_TICKS = 32  -- ~4s at 8 Hz before applying, to clear the BeginPlay window

local initialized = false
local enabled = false
local flareType = nil   -- nil = keep UDS default
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

--- Set the bool (+ optional type) and run UDS's apply function. Game thread only.
local function applyOnGameThread()
    local uds = getUDS()
    if not uds then return end

    pcall(function() uds[PROP_ENABLE] = true end)
    if flareType ~= nil then pcall(function() uds[PROP_TYPE] = flareType end) end

    local fn = nil
    pcall(function() fn = uds[FN_STATIC] end)
    if fn then
        local ok, err = pcall(function() fn(uds) end)
        if ok then
            Log.Debug(MODULE, "Static Properties - Lens Flare called")
        else
            Log.Warn(MODULE, "Static Properties - Lens Flare failed", { error = tostring(err) })
        end
    else
        Log.Warn(MODULE, "Static Properties - Lens Flare function not found")
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

function LensFlare.Init()
    if initialized then return true end
    local cfg = Config.LensFlare
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.Type ~= nil then flareType = cfg.Type end
    end
    initialized = true
    Log.Info(MODULE, "Initializing sun lens flare module", { enabled = enabled })
    return true
end

--- Per-tick: enable once per course, after the settle gate, if configured on.
function LensFlare.Tick()
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
            Log.Info(MODULE, "Sun lens flare applied")
        end
    end
end

function LensFlare.GetStatus()
    return {
        initialized = initialized,
        enabled = enabled,
        applied = applied,
        appliedThisCourse = appliedThisCourse,
        flareType = flareType,
    }
end

return LensFlare
