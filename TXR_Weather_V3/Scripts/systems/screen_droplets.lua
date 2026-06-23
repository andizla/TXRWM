-- TXR Weather Mod v3.0
-- systems/screen_droplets.lua
-- Screen Droplets: UDW post-process effect that renders rain droplets on the
-- camera lens when exposed to rain. (UDS-docs "wet look" pivot - a screen-space
-- effect that, unlike ground puddles, needs no changes to the game's materials.)
--
-- SAFETY: enabling re-runs UDW's "Static Properties - Screen Droplets" function,
-- which calls CreateDynamicMaterialInstance - the same MID-creation pattern that
-- crashed Stars when run during course BeginPlay. So this module is INERT by
-- default (no writes, no function call) and only acts when:
--   - Config.ScreenDroplets.Enabled = true AND the world has settled (Tick gate), or
--   - the user presses the toggle keybind (Alt+D),
-- never during the BeginPlay/course-load window. All UDW work is marshalled to the
-- game thread via ExecuteInGameThread.
--
-- NOTE: the droplets only render while the camera is actually exposed to rain, so
-- to see anything you need a rain preset active.

local ScreenDroplets = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local Config = require("config")

local Actors = nil  -- lazy

local MODULE = "ScreenDroplets"

-- ============== PROPERTY / FUNCTION NAMES (verified from UE4SS_ObjectDump) ==============
local PROP_ENABLE      = "Enable Screen Droplets"        -- Bool
local PROP_CENTER      = "Screen Center Strength"        -- Double
local PROP_EDGE        = "Screen Edge Strength"          -- Double
local PROP_TILING      = "Droplet Tiling"               -- Double
local PROP_CLEAR_SPEED = "Screen Droplets Clear Speed"   -- Double
local FN_STATIC        = "Static Properties - Screen Droplets"  -- configures the droplet MID
-- Master assembler: rebuilds the PostProcess component's weighted-blendable ARRAY
-- from all enabled effects. The per-effect function only configures its MID; THIS
-- is what actually pushes the blendable onto the component (so it renders).
local FN_STATIC_PP     = "Static Properties - Post Processing"

-- Runtime-state props we read back for diagnostics (verified from the dump).
local PROP_ACTIVE      = "Screen Droplets Active"               -- Bool
local PROP_INTENSITY   = "Screen Droplets Target Drips Intensity" -- Double (rain-driven)
local PROP_EXPOSURE    = "Screen Droplets Camera Exposure"      -- Double
local PROP_MID         = "Screen Droplets MID"                  -- Object (the dynamic material)

-- UDW's single post-process component; ALL screen effects add their weighted
-- blendables here. For any of them to show, it must be enabled + unbound (affect
-- the whole view, not just near the UDW actor).
local PROP_PP          = "PostProcess"                          -- UPostProcessComponent

-- Ticks on course before we allow an auto-apply, to clear the BeginPlay window.
-- Main loop is 8 Hz, so 24 ticks ~= 3s (mirrors the shadow settle-gate lesson).
local SETTLE_TICKS = 24

-- Diagnostic readback cadence (ticks) while enabled, if Config.ScreenDroplets.Debug.
local DIAG_INTERVAL_TICKS = 24

-- ============== STATE ==============
local initialized = false
local desiredEnabled = false
local settleTicks = 0
local appliedThisCourse = false
local diagTicks = 0

-- ============== INTERNAL ==============

local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

--- Read back UDW's internal droplet state to classify why the effect renders or
--- not. midNil=true -> parent material soft-ref never resolved (MID not created).
--- midNil=false but intensity/exposure stay 0 in rain -> rain/exposure not driving
--- it (TXR camera-exposure integration). All non-zero but no visual -> the post-
--- process blendable isn't reaching TXR's camera (compositing dead-end).
local function logReadback(tag)
    local actors = getActors()
    if not actors then return end
    local udw = actors.GetUDW()
    if not udw then return end
    local function rd(p)
        local v = nil
        pcall(function() v = udw[p] end)
        return v
    end
    local mid = rd(PROP_MID)

    -- Inspect UDW's post-process component (the compositing target).
    local pp = rd(PROP_PP)
    local ppEnabled, ppUnbound, ppWeight, ppPriority
    if pp then
        pcall(function() ppEnabled = pp["bEnabled"] end)
        pcall(function() ppUnbound = pp["bUnbound"] end)
        pcall(function() ppWeight = pp["BlendWeight"] end)
        pcall(function() ppPriority = pp["Priority"] end)
    end

    Log.Info(MODULE, "Droplet readback", {
        tag = tag or "tick",
        enable = tostring(rd(PROP_ENABLE)),
        active = tostring(rd(PROP_ACTIVE)),
        intensity = tostring(rd(PROP_INTENSITY)),
        exposure = tostring(rd(PROP_EXPOSURE)),
        midNil = (mid == nil),
        ppNil = (pp == nil),
        ppEnabled = tostring(ppEnabled),
        ppUnbound = tostring(ppUnbound),
        ppWeight = tostring(ppWeight),
        ppPriority = tostring(ppPriority),
    })
end

--- Do the actual UDW work. MUST run on the game thread (creates a MID).
local function applyOnGameThread()
    local actors = getActors()
    if not actors then return end
    local udw = actors.GetUDW()
    if not udw then return end

    -- Primitive writes first (bool + optional doubles). Safe off-thread, but we're
    -- already on the game thread here.
    pcall(function() udw[PROP_ENABLE] = desiredEnabled end)

    if desiredEnabled then
        local c = Config.ScreenDroplets or {}
        if c.CenterStrength then pcall(function() udw[PROP_CENTER] = c.CenterStrength end) end
        if c.EdgeStrength then pcall(function() udw[PROP_EDGE] = c.EdgeStrength end) end
        if c.Tiling then pcall(function() udw[PROP_TILING] = c.Tiling end) end
        if c.ClearSpeed then pcall(function() udw[PROP_CLEAR_SPEED] = c.ClearSpeed end) end
    end

    -- Ensure UDW's post-process component will actually composite onto the view.
    -- If it's bounded/disabled in TXR's integration, the blendable never shows.
    if desiredEnabled then
        local pp = nil
        pcall(function() pp = udw[PROP_PP] end)
        if pp then
            pcall(function() pp["bEnabled"] = true end)
            pcall(function() pp["bUnbound"] = true end)
            pcall(function() pp["BlendWeight"] = 1.0 end)
            Log.Debug(MODULE, "Forced PostProcess component enabled + unbound")
        else
            Log.Warn(MODULE, "UDW PostProcess component not found")
        end
    end

    -- Re-run the static-properties function so the enable change actually takes
    -- effect at runtime (per UDS docs: static properties need this to apply).
    local fn = nil
    pcall(function() fn = udw[FN_STATIC] end)
    if fn then
        local ok, err = pcall(function() fn(udw) end)
        if ok then
            Log.Debug(MODULE, "Static Properties - Screen Droplets called")
        else
            Log.Warn(MODULE, "Static Properties call failed", {error = tostring(err)})
        end
    else
        Log.Warn(MODULE, "Static Properties - Screen Droplets function not found")
    end

    -- Re-assemble the component's weighted-blendable ARRAY so the droplet material
    -- is actually pushed onto the PostProcess component. The per-effect function
    -- above only configures the MID; this master function builds the live array
    -- from the enable flags (UDW ran it at startup when droplets were still off).
    local fnPP = nil
    pcall(function() fnPP = udw[FN_STATIC_PP] end)
    if fnPP then
        local ok, err = pcall(function() fnPP(udw) end)
        if ok then
            Log.Debug(MODULE, "Static Properties - Post Processing called")
        else
            Log.Warn(MODULE, "Static Properties - Post Processing failed", {error = tostring(err)})
        end
    else
        Log.Warn(MODULE, "Static Properties - Post Processing function not found")
    end

    -- Immediate readback so a single toggle gives us classification data.
    logReadback("apply")
end

-- ============== PUBLIC API ==============

--- Initialize the module (reads config; does NOT touch UDW).
function ScreenDroplets.Init()
    if initialized then return true end
    desiredEnabled = (Config.ScreenDroplets and Config.ScreenDroplets.Enabled) == true
    initialized = true
    Log.Info(MODULE, "Initializing screen droplets module", { enabled = desiredEnabled })
    return true
end

--- Apply the desired enable state to UDW, marshalled onto the game thread.
--- @param enabled boolean
--- @return boolean scheduled
function ScreenDroplets.Apply(enabled)
    desiredEnabled = enabled and true or false
    if ExecuteInGameThread then
        pcall(function() ExecuteInGameThread(applyOnGameThread) end)
    else
        -- Fallback for older UE4SS: best-effort direct call.
        applyOnGameThread()
    end
    Log.Info(MODULE, "Screen droplets applied", { enabled = desiredEnabled })
    return true
end

--- Toggle on/off (keybind handler). Returns the new state.
--- @return boolean
function ScreenDroplets.Toggle()
    ScreenDroplets.Apply(not desiredEnabled)
    return desiredEnabled
end

--- Per-tick: auto-apply once per course if configured on, after the settle gate.
function ScreenDroplets.Tick()
    if not initialized then return end

    local actors = getActors()
    if not actors or not actors.IsOnCourse() then
        settleTicks = 0
        appliedThisCourse = false
        return
    end

    settleTicks = settleTicks + 1

    local cfg = Config.ScreenDroplets or {}
    if cfg.Enabled and not appliedThisCourse and settleTicks >= SETTLE_TICKS then
        appliedThisCourse = true
        ScreenDroplets.Apply(true)
    end

    -- Periodic readback while enabled, to see if rain drives intensity over time.
    if desiredEnabled and cfg.Debug then
        diagTicks = diagTicks + 1
        if diagTicks >= DIAG_INTERVAL_TICKS then
            diagTicks = 0
            logReadback("tick")
        end
    end
end

--- @return boolean
function ScreenDroplets.IsEnabled()
    return desiredEnabled
end

--- @return table
function ScreenDroplets.GetStatus()
    return {
        initialized = initialized,
        enabled = desiredEnabled,
        appliedThisCourse = appliedThisCourse,
    }
end

return ScreenDroplets
