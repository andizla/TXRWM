-- TXR Weather Mod v3.0
-- systems/volumetric_light_rays.lua
-- Volumetric Cloud Light Rays: UDS god-ray shafts that stab down through gaps in
-- the cloud cover. Rendered by a Niagara system of additive ray cards (the same
-- render path as rain / wind debris, so it works in TXR). NOT a post-process effect
-- (no MID, no weighted blendable), so it does not hit the screen-effect dead-end.
--
-- Enabled + applied via UDS's "Static Properties - Volumetric Cloud Light Rays" on
-- the game thread, deferred past BeginPlay by a settle gate (the proven Stars /
-- WindDebris pattern). `Individual Clouds Light Rays` > 0 casts rays through NATURAL
-- cloud gaps, so we get them on overcast skies without painting cloud coverage.
-- Shows in daytime under broken/overcast cloud with the sun behind the clouds.

local LightRays = {}

local Log = require("core.logging")
local Config = require("config")

local Actors = nil  -- lazy

local MODULE = "LightRays"

-- UDS property / function names (verified from UE4SS_ObjectDump)
local PROP_ENABLE     = "Enable Volumetric Cloud Light Rays"  -- Bool
local PROP_USING_SUN  = "Light Rays Using Sun"                -- Bool (sun as the ray source)
local PROP_INDIVIDUAL = "Individual Clouds Light Rays"        -- Double 0-1 (>0 = natural gaps)
local PROP_INTENSITY  = "Light Ray Intensity"                -- Double
local FN_STATIC       = "Static Properties - Volumetric Cloud Light Rays"
local PROP_INTERNAL   = "Using Volumetric Light Rays"        -- Bool (UDS internal state, readback only)
-- Distance/geometry knobs (2026-07-28: rays fire off nearby
-- buildings): depth fade softens rays against close scene depth, max
-- distance bounds the field, spacing/length shape the cards.
local PROP_MAXDIST    = "Light Rays Max Distance (Km)"       -- Double
local PROP_DEPTHFADE  = "Light Rays Depth Fade Distance"     -- Double
local PROP_SPACING    = "Light Rays Point Spacing"           -- Double
local PROP_LEN        = "Light Ray Length"                   -- Double
local PROP_MAXLEN     = "Max Light Ray Length"               -- Double

local SETTLE_TICKS = 32  -- ~4s at 8 Hz before applying, to clear the BeginPlay window
local DIAG_INTERVAL_TICKS = 24  -- ~3s readback cadence while Debug

local initialized = false
local enabled = false
local intensity = nil   -- nil = keep UDS default
local individual = 1.0  -- 0-1; >0 so rays show through natural cloud gaps
local usingSun = true
local applied = false
local settleTicks = 0
local appliedThisCourse = false
local diagTicks = 0
-- Plausibility gate (2026-07-28): sun shafts through cloud gaps
-- are nonsense under a solid deck, in fog, or in rain: these presets force
-- the rays OFF; a change back to broken cover brings them back. Override
-- the set via Config.LightRays.DisabledPresets (array of preset names).
local weatherBlocked = false
local DISABLED_PRESETS = {
    Overcast = true, Overcast_Heavy = true, Foggy = true,
    Rain_Light = true, Rain = true, Rain_Thunderstorm = true,
}
-- nil = keep the UDS default (stock values land in the apply readback:
-- tune Config.LightRays from a logged session)
local maxDistanceKm = nil
local depthFade = nil
local pointSpacing = nil
local rayLength = nil
local maxRayLength = nil

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

local function logReadback(tag)
    local uds = getUDS()
    if not uds then return end
    local function rd(p)
        local v = nil
        pcall(function() v = uds[p] end)
        return v
    end
    Log.Info(MODULE, "Light rays readback", {
        tag = tag or "tick",
        enable = tostring(rd(PROP_ENABLE)),
        individual = tostring(rd(PROP_INDIVIDUAL)),
        intensity = tostring(rd(PROP_INTENSITY)),
        active = tostring(rd(PROP_INTERNAL)),  -- UDS says the rays are actually in use
        maxDistKm = tostring(rd(PROP_MAXDIST)),
        depthFade = tostring(rd(PROP_DEPTHFADE)),
        spacing = tostring(rd(PROP_SPACING)),
        rayLen = tostring(rd(PROP_LEN)),
        maxRayLen = tostring(rd(PROP_MAXLEN)),
    })
end

local function applyOnGameThread()
    local uds = getUDS()
    if not uds then return end

    local rayOn = enabled and not weatherBlocked
    pcall(function() uds[PROP_ENABLE] = rayOn end)
    pcall(function() uds[PROP_USING_SUN] = usingSun end)
    if individual ~= nil then pcall(function() uds[PROP_INDIVIDUAL] = individual end) end
    if intensity ~= nil then pcall(function() uds[PROP_INTENSITY] = intensity end) end
    if maxDistanceKm ~= nil then pcall(function() uds[PROP_MAXDIST] = maxDistanceKm end) end
    if depthFade ~= nil then pcall(function() uds[PROP_DEPTHFADE] = depthFade end) end
    if pointSpacing ~= nil then pcall(function() uds[PROP_SPACING] = pointSpacing end) end
    if rayLength ~= nil then pcall(function() uds[PROP_LEN] = rayLength end) end
    if maxRayLength ~= nil then pcall(function() uds[PROP_MAXLEN] = maxRayLength end) end

    local fn = nil
    pcall(function() fn = uds[FN_STATIC] end)
    if fn then
        local ok, err = pcall(function() fn(uds) end)
        if ok then
            Log.Debug(MODULE, "Static Properties - Volumetric Cloud Light Rays called")
        else
            Log.Warn(MODULE, "Static Properties - Light Rays failed", { error = tostring(err) })
        end
    else
        Log.Warn(MODULE, "Static Properties - Volumetric Cloud Light Rays function not found")
    end

    logReadback("apply")
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

function LightRays.Init()
    if initialized then return true end
    local cfg = Config.LightRays
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.Intensity ~= nil then intensity = cfg.Intensity end
        if cfg.IndividualClouds ~= nil then individual = cfg.IndividualClouds end
        if cfg.UsingSun ~= nil then usingSun = cfg.UsingSun end
        if type(cfg.DisabledPresets) == "table" then
            DISABLED_PRESETS = {}
            for _, name in ipairs(cfg.DisabledPresets) do
                DISABLED_PRESETS[name] = true
            end
        end
        if tonumber(cfg.MaxDistanceKm) then maxDistanceKm = tonumber(cfg.MaxDistanceKm) end
        if tonumber(cfg.DepthFadeDistance) then depthFade = tonumber(cfg.DepthFadeDistance) end
        if tonumber(cfg.PointSpacing) then pointSpacing = tonumber(cfg.PointSpacing) end
        if tonumber(cfg.RayLength) then rayLength = tonumber(cfg.RayLength) end
        if tonumber(cfg.MaxRayLength) then maxRayLength = tonumber(cfg.MaxRayLength) end
    end
    initialized = true
    Log.Info(MODULE, "Initializing volumetric light rays module", { enabled = enabled })
    return true
end

--- Per-tick: enable once per course, after the settle gate, if configured on.
function LightRays.Tick()
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
            Log.Info(MODULE, "Volumetric cloud light rays applied")
        end
    end

    if appliedThisCourse and (Config.LightRays or {}).Debug then
        diagTicks = diagTicks + 1
        if diagTicks >= DIAG_INTERVAL_TICKS then
            diagTicks = 0
            logReadback("tick")
        end
    end
end

--- Weather plausibility: weather.Apply reports every preset change here.
--- On a state change the same GT apply path re-runs (no extra settle: any
--- mid-course weather change means the course settled long ago), so a
--- turn to Overcast kills the rays and a clearing sky restores them.
function LightRays.OnWeatherChange(presetName)
    if not initialized then return end
    local blocked = DISABLED_PRESETS[presetName] == true
    if blocked == weatherBlocked then return end
    weatherBlocked = blocked
    Log.Info(MODULE, blocked and "Light rays OFF (implausible weather)"
        or "Light rays ON (weather clears)", { preset = tostring(presetName) })
    if appliedThisCourse and enabled then
        apply()
    end
end

function LightRays.GetStatus()
    return {
        initialized = initialized,
        enabled = enabled,
        applied = applied,
        appliedThisCourse = appliedThisCourse,
        intensity = intensity,
        individual = individual,
    }
end

return LightRays
