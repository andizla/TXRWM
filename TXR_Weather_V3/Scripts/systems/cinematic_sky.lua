-- TXR Weather Mod v3.0
-- systems/cinematic_sky.lua
-- Cinematic daytime grade: volumetric-cloud shading, sky-atmosphere color,
-- cloud wisps (cirrus), cloud render quality and cloud movement mood.
--
-- Every target is a reflected primitive/struct on UDS verified against the v1.5
-- dump (shared/types/Ultra_Dynamic_Sky.lua) - nothing here is in the dead
-- post-process (MID + WeightedBlendable) family.
--
-- Knobs with undocumented internal scales are configured as MULTIPLIERS on the
-- value UDS spawned with. The sky actor is recreated on every course load, so
-- stock values are re-read fresh each course and scaling never compounds.
-- Applied once per course on the game thread after the settle gate, then baked
-- with UDS's own "Static Properties - X" calls (the stars/nebula/moon pattern).
-- Original -> tuned pairs are logged on each apply for easy retuning.

local CinematicSky = {}

local Log = require("core.logging")
local Config = require("config")

local Actors = nil  -- lazy

local MODULE = "CinematicSky"

-- ============== UDS PROPERTY NAMES (verified, v1.5 dump) ==============
-- Global grade (Basic Controls). Saturation stock = 1.0 (absolute is fine);
-- Contrast stock = 0.1, so it MUST be scaled, not overwritten.
local PROP_SATURATION = "Saturation"
local PROP_CONTRAST   = "Contrast"

-- Volumetric clouds (multipliers)
local PROP_EXTINCTION     = "Extinction Scale"
local PROP_DETAIL_NOISE   = "High Frequency Noise Amount"
local PROP_MULTISCATTER   = "Multiscattering Light Intensity"
local PROP_AMBIENT_INTENS = "Volumetric Cloud Ambient Light Intensity"
local PROP_AMBIENT_SAT    = "Volumetric Cloud Ambient Light Saturation"

-- Cloud wisps (multipliers)
local PROP_WISPS_OPACITY_CLEAR  = "Cloud Wisps Opacity (Clear)"
local PROP_WISPS_OPACITY_CLOUDY = "Cloud Wisps Opacity (Cloudy)"
local PROP_WISPS_COLOR_INTENS   = "Cloud Wisps Color Intensity"
local PROP_WISPS_SUN_BRIGHT     = "Increase Wisps Brightness Around Sun"

-- Sky atmosphere (multipliers; gated on UDS actually controlling the atmosphere)
local PROP_ATMO_CONTROL       = "Control Sky Atmosphere Settings"
local PROP_OVERCAST_LUMINANCE = "Sky Atmosphere Overcast Luminance"
local PROP_RAYLEIGH_DESAT     = "Desaturate Rayleigh Scattering When Cloudy"
local PROP_SUNSET_INTENSITY   = "Sunset/Sunrise Color Intensity (Absorption Scale)"

-- Cloud render quality (multipliers)
local PROP_VIEW_SAMPLES   = "View Sample Scale (Day)"
local PROP_SHADOW_SAMPLES = "Shadow Sample Scale"

-- Cloud movement
local PROP_CLOUD_SPEED   = "Cloud Speed"
local PROP_MOVE_WITH_TOD = "Clouds Move With Time Of Day"

-- Bakers (UDS re-reads the edited properties into its materials/components)
local STATIC_FNS = {
    "Static Properties - Sky Material",
    "Static Properties - Volumetric Clouds",
    "Static Properties - Sky Atmosphere",
    "Static Properties - Cloud Movement",
}

local SETTLE_TICKS = 32  -- ~4s at 8 Hz past BeginPlay (proven settle gate)

-- ============== STATE ==============
local initialized = false
local enabled = false
local cfg = nil
local debugMode = false
local settleTicks = 0
local appliedThisCourse = false
local lastApplySummary = nil

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

-- ============== APPLY HELPERS (game thread only) ==============

--- Write an absolute value; records "old->new" in the changes table.
local function setAbs(uds, prop, value, changes)
    if value == nil then return end
    local old = nil
    pcall(function() old = uds[prop] end)
    local ok = pcall(function() uds[prop] = value end)
    if ok then
        changes[prop] = string.format("%s->%s", tostring(old), tostring(value))
    elseif debugMode then
        Log.Warn(MODULE, "Write failed", {prop = prop})
    end
end

--- Scale a numeric property by a multiplier (1.0/nil = leave stock).
local function setMult(uds, prop, mult, changes)
    if mult == nil or mult == 1.0 then return end
    local old = nil
    pcall(function() old = uds[prop] end)
    old = tonumber(old)
    if old == nil then
        if debugMode then Log.Warn(MODULE, "Read failed (skipping)", {prop = prop}) end
        return
    end
    local new = old * mult
    local ok = pcall(function() uds[prop] = new end)
    if ok then
        changes[prop] = string.format("%.3f->%.3f", old, new)
    elseif debugMode then
        Log.Warn(MODULE, "Write failed", {prop = prop})
    end
end

local function applyOnGameThread()
    local uds = getUDS()
    if not uds then return end

    local changes = {}

    -- Global grade
    setAbs(uds, PROP_SATURATION, cfg.Saturation, changes)
    setMult(uds, PROP_CONTRAST, cfg.ContrastMult, changes)

    -- Volumetric cloud look
    setMult(uds, PROP_EXTINCTION, cfg.ExtinctionMult, changes)
    setMult(uds, PROP_DETAIL_NOISE, cfg.DetailNoiseMult, changes)
    setMult(uds, PROP_MULTISCATTER, cfg.MultiscatterMult, changes)
    setMult(uds, PROP_AMBIENT_INTENS, cfg.AmbientLightMult, changes)
    setMult(uds, PROP_AMBIENT_SAT, cfg.AmbientSaturationMult, changes)

    -- Cloud wisps
    setMult(uds, PROP_WISPS_OPACITY_CLEAR, cfg.WispsOpacityMult, changes)
    setMult(uds, PROP_WISPS_OPACITY_CLOUDY, cfg.WispsOpacityMult, changes)
    setMult(uds, PROP_WISPS_COLOR_INTENS, cfg.WispsColorIntensityMult, changes)
    setMult(uds, PROP_WISPS_SUN_BRIGHT, cfg.WispsSunBrightnessMult, changes)

    -- Sky atmosphere: only when UDS drives the atmosphere (otherwise the values
    -- are inert and writing them would just be misleading in the log)
    local atmoControl = nil
    pcall(function() atmoControl = uds[PROP_ATMO_CONTROL] end)
    if atmoControl == true then
        setMult(uds, PROP_OVERCAST_LUMINANCE, cfg.OvercastLuminanceMult, changes)
        setMult(uds, PROP_RAYLEIGH_DESAT, cfg.RayleighDesatMult, changes)
        setMult(uds, PROP_SUNSET_INTENSITY, cfg.SunsetIntensityMult, changes)
    else
        Log.Warn(MODULE, "UDS not controlling sky atmosphere - atmo tweaks skipped",
            {controlFlag = tostring(atmoControl)})
    end

    -- Render quality
    setMult(uds, PROP_VIEW_SAMPLES, cfg.ViewSampleQualityMult, changes)
    setMult(uds, PROP_SHADOW_SAMPLES, cfg.ShadowSampleQualityMult, changes)

    -- Movement mood
    setMult(uds, PROP_CLOUD_SPEED, cfg.CloudSpeedMult, changes)
    setAbs(uds, PROP_MOVE_WITH_TOD, cfg.CloudsMoveWithTimeOfDay, changes)

    -- Bake: have UDS re-read everything into its materials/components
    for _, fnName in ipairs(STATIC_FNS) do
        local fn = nil
        pcall(function() fn = uds[fnName] end)
        if fn then
            local ok, err = pcall(function() fn(uds) end)
            if not ok then
                Log.Warn(MODULE, "Static apply failed", {fn = fnName, error = tostring(err)})
            end
        else
            Log.Warn(MODULE, "Static apply function not found", {fn = fnName})
        end
    end

    lastApplySummary = changes
    Log.Info(MODULE, "Cinematic sky applied", changes)
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

function CinematicSky.Init()
    if initialized then return true end
    cfg = Config.CinematicSky or {}
    enabled = cfg.Enabled == true
    debugMode = cfg.Debug == true
    initialized = true
    Log.Info(MODULE, "Initializing cinematic sky module", {enabled = enabled})
    return true
end

--- Per-tick: apply once per course, after the settle gate.
function CinematicSky.Tick()
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
        apply()
    end
end

function CinematicSky.GetStatus()
    return {
        initialized = initialized,
        enabled = enabled,
        appliedThisCourse = appliedThisCourse,
        lastApply = lastApplySummary,
    }
end

return CinematicSky
