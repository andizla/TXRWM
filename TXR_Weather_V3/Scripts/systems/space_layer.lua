-- TXR Weather Mod v3.0
-- systems/space_layer.lua
-- UDS Space Layer: a layer of Nebula (plus the space-glow brightness control)
-- rendered INTO the sky material, the same way the stars and moon are. So it works
-- in TXR like the stars/moon; it is not a post-process effect.
--
-- The space layer composites using DBuffer Decals (r.DBuffer 1). The installer's
-- Engine.ini profile sets that cvar; this module also requests it on the game thread
-- (the safe console path in core/utils) as a fallback for manual installs. Setting it
-- at runtime is best-effort; if the renderer initialised without DBuffer support the
-- nebula just won't render until the cvar is set in Engine.ini. No crash either way.
--
-- We set the nebula/glow properties + call UDS's "Static Properties - Space Layer"
-- on the game thread, deferred past BeginPlay by a settle gate (the proven Stars /
-- Moon / WindDebris / LightRays pattern). UDS fades the layer in/out by day/night
-- itself via "Space Layer Brightness (Day/Night)", so this is a one-shot apply.

local SpaceLayer = {}

local Log = require("core.logging")
local Utils = require("core.utils")
local Config = require("config")

local Actors = nil  -- lazy

local MODULE = "SpaceLayer"

-- UDS property / function names (verified from the v1.5 dump / shared types)
local PROP_RENDER_NEBULA   = "Render Nebula"                  -- Bool
local PROP_NEBULA_INTENS   = "Nebula Intensity"               -- Double
local PROP_NEBULA_COLOR1   = "Nebula Color 1"                 -- FLinearColor
local PROP_NEBULA_COLOR2   = "Nebula Color 2"                 -- FLinearColor
local PROP_NEBULA_COLOR3   = "Nebula Color 3"                 -- FLinearColor
local PROP_NEBULA_SCALE    = "Nebula Noise Scale"             -- Double
local PROP_BRIGHT_NIGHT    = "Space Layer Brightness (Night)" -- Double
local PROP_BRIGHT_DAY      = "Space Layer Brightness (Day)"   -- Double
local PROP_SPACE_GLOW      = "Space Glow Brightness"          -- Double
local FN_STATIC            = "Static Properties - Space Layer"
local PROP_LAYER_ACTIVE    = "Space Layer Active"             -- Bool (read-only-ish; static fn sets it)

local SETTLE_TICKS = 32  -- ~4s at 8 Hz before applying, to clear the BeginPlay window

local initialized = false
local enabled = false
local renderNebula = true
local nebulaIntensity = nil   -- nil = UDS default
local nebulaNoiseScale = nil
local nebulaColor1 = nil
local nebulaColor2 = nil
local nebulaColor3 = nil
local brightnessNight = nil
local brightnessDay = nil
local spaceGlow = nil
local setDBuffer = true
local applied = false
local settleTicks = 0
local appliedThisCourse = false
local dbufferPushed = false

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

    pcall(function() uds[PROP_RENDER_NEBULA] = renderNebula end)
    if nebulaIntensity ~= nil then pcall(function() uds[PROP_NEBULA_INTENS] = nebulaIntensity end) end
    if nebulaNoiseScale ~= nil then pcall(function() uds[PROP_NEBULA_SCALE] = nebulaNoiseScale end) end
    if nebulaColor1 ~= nil then pcall(function() uds[PROP_NEBULA_COLOR1] = nebulaColor1 end) end
    if nebulaColor2 ~= nil then pcall(function() uds[PROP_NEBULA_COLOR2] = nebulaColor2 end) end
    if nebulaColor3 ~= nil then pcall(function() uds[PROP_NEBULA_COLOR3] = nebulaColor3 end) end
    if brightnessNight ~= nil then pcall(function() uds[PROP_BRIGHT_NIGHT] = brightnessNight end) end
    if brightnessDay ~= nil then pcall(function() uds[PROP_BRIGHT_DAY] = brightnessDay end) end
    if spaceGlow ~= nil then pcall(function() uds[PROP_SPACE_GLOW] = spaceGlow end) end

    local fn = nil
    pcall(function() fn = uds[FN_STATIC] end)
    if fn then
        local ok, err = pcall(function() fn(uds) end)
        if ok then
            Log.Debug(MODULE, "Static Properties - Space Layer called")
        else
            Log.Warn(MODULE, "Static Properties - Space Layer failed", { error = tostring(err) })
        end
    else
        Log.Warn(MODULE, "Static Properties - Space Layer function not found")
    end

    local active = nil
    pcall(function() active = uds[PROP_LAYER_ACTIVE] end)
    Log.Info(MODULE, "Space layer applied", { renderNebula = renderNebula, active = tostring(active) })
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

function SpaceLayer.Init()
    if initialized then return true end
    local cfg = Config.SpaceLayer
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.RenderNebula ~= nil then renderNebula = cfg.RenderNebula end
        if cfg.NebulaIntensity ~= nil then nebulaIntensity = cfg.NebulaIntensity end
        if cfg.NebulaNoiseScale ~= nil then nebulaNoiseScale = cfg.NebulaNoiseScale end
        if cfg.NebulaColor1 ~= nil then nebulaColor1 = cfg.NebulaColor1 end
        if cfg.NebulaColor2 ~= nil then nebulaColor2 = cfg.NebulaColor2 end
        if cfg.NebulaColor3 ~= nil then nebulaColor3 = cfg.NebulaColor3 end
        if cfg.BrightnessNight ~= nil then brightnessNight = cfg.BrightnessNight end
        if cfg.BrightnessDay ~= nil then brightnessDay = cfg.BrightnessDay end
        if cfg.SpaceGlowBrightness ~= nil then spaceGlow = cfg.SpaceGlowBrightness end
        if cfg.SetDBuffer ~= nil then setDBuffer = cfg.SetDBuffer end
    end
    initialized = true
    Log.Info(MODULE, "Initializing space layer module", { enabled = enabled })
    return true
end

--- Per-tick: enable once per course, after the settle gate, if configured on.
function SpaceLayer.Tick()
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
        -- DBuffer decals are required for the space layer to composite into the sky.
        if setDBuffer and not dbufferPushed then
            dbufferPushed = true
            Utils.ExecConsoleCommands({ "r.DBuffer 1" })
            Log.Debug(MODULE, "Requested r.DBuffer 1 (required for space-layer compositing)")
        end
        applied = apply()
    end
end

function SpaceLayer.GetStatus()
    return {
        initialized = initialized,
        enabled = enabled,
        applied = applied,
        appliedThisCourse = appliedThisCourse,
        renderNebula = renderNebula,
    }
end

return SpaceLayer
