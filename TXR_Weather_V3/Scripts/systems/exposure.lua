-- TXR Weather Mod v3.0
-- systems/exposure.lua
-- Phase 13: Auto-exposure scheduler (ported from the standalone VEAO mod)
-- Maps Time Of Day -> per-slot Lumen/eye-adaptation console variables.
-- 48 slots of 30 min each across 00:00-24:00 (TOD units 0..2400). Garage forces
-- the night slot. Unlike the standalone VEAO, this runs on TXR's tick loop and
-- uses TXR's TimeOfDay / Actors / logging instead of its own hooks and timers.

local Exposure = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")
local Config = require("config")

-- Lazy-loaded to avoid circular dependencies
local Actors = nil
local TimeOfDay = nil
local UEHelpers = nil

local MODULE = "Exposure"

-- ============== CONFIG-DERIVED (filled in Init, with safe fallbacks) ==============
local enabled = true
local SLOT_COUNT = 48
local SLOT_SIZE_TOD = 50.0          -- 50 TOD units = 30 minutes
local UPDATE_INTERVAL = 2.0         -- seconds between slot re-evaluations
local CVAR_SKY  = "r.SkylightIntensityMultiplier"
local CVAR_LEAK = "r.Lumen.SkylightLeaking.ReflectionAverageAlbedo"
local CVAR_LENS = "r.EyeAdaptation.LensAttenuation"

-- Slot table: [1..48] = { sky=<float>, leak=<float>, lens=<float> }
-- Populated from Config.Exposure.Slots in Init (falls back to empty -> no-op).
local slots = {}

-- ============== STATE ==============
local isInitialized = false
local currentSlot = nil             -- last evaluated slot (0-based), nil = none yet
local lastCheckClock = 0.0          -- os.clock() of last evaluation (throttle)
local lastInterpLens = nil          -- last interpolated lens (brightness proxy; see GetBrightnessLens)
local lastApplied = { sky = nil, leak = nil, lens = nil }  -- last pushed cvar values (skip redundant pushes)

-- ============== INTERNAL FUNCTIONS ==============

local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

local function getTimeOfDay()
    if not TimeOfDay then
        local ok, mod = pcall(require, "systems.time_of_day")
        if ok then TimeOfDay = mod end
    end
    return TimeOfDay
end

local function getUEHelpers()
    if not UEHelpers then
        pcall(function() UEHelpers = require("UEHelpers") end)
    end
    return UEHelpers
end

local function clamp(x, a, b)
    if x < a then return a end
    if x > b then return b end
    return x
end

--- Execute a single console command via the Kismet system library.
--- @param cmd string
--- @return boolean success
local function execConsole(cmd)
    if not cmd or cmd == "" then return false end

    local UEH = getUEHelpers()
    if not UEH or not UEH.GetKismetSystemLibrary then
        return false
    end

    local ksl = nil
    pcall(function() ksl = UEH.GetKismetSystemLibrary() end)
    if not (ksl and ksl:IsValid()) then return false end

    local eng = nil
    pcall(function() eng = FindFirstOf("Engine") end)
    if not (eng and eng:IsValid()) then return false end

    return pcall(function() ksl:ExecuteConsoleCommand(eng, cmd, nil) end)
end

--- Schedule a batch of console commands on the game thread. TXR's module ticks
--- run on UE4SS's async LoopAsync thread; issuing r.* render CVAR commands off
--- the game thread races the render thread and crashes (access violation) during
--- course load, so we marshal onto the game thread (as the standalone VEAO did).
--- @param cmds string[]
--- @return boolean scheduled
local function scheduleExec(cmds)
    if not cmds or #cmds == 0 then return false end
    if ExecuteInGameThread then
        return pcall(function()
            ExecuteInGameThread(function()
                for _, cmd in ipairs(cmds) do execConsole(cmd) end
            end)
        end)
    end
    -- Fallback (older UE4SS without ExecuteInGameThread): best-effort direct
    for _, cmd in ipairs(cmds) do execConsole(cmd) end
    return true
end

local function lerp(a, b, t) return a + (b - a) * t end

--- Push exposure cvars for explicit sky/leak/lens values. Skips the push when the
--- values are unchanged from the last one (the day/night cores are flat for hours),
--- so the smooth ramp only emits console commands during the transition windows.
--- @param sky number
--- @param leak number
--- @param lens number
--- @param tod number for logging
--- @param reason string for logging
--- @return boolean success (commands scheduled, or true if skipped as unchanged)
local function applyValues(sky, leak, lens, tod, reason)
    local eps = 1e-4
    if lastApplied.sky
        and math.abs(sky  - lastApplied.sky)  < eps
        and math.abs(leak - lastApplied.leak) < eps
        and math.abs(lens - lastApplied.lens) < eps then
        return true   -- unchanged: skip redundant push
    end

    local scheduled = scheduleExec({
        string.format("%s %.6f", CVAR_SKY,  sky),
        string.format("%s %.6f", CVAR_LEAK, leak),
        string.format("%s %.6f", CVAR_LENS, lens),
    })

    lastApplied.sky, lastApplied.leak, lastApplied.lens = sky, leak, lens

    Log.Info(MODULE, "Applied exposure", {
        tod = string.format("%.0f", tod or 0),
        reason = reason or "",
        sky = sky, leak = leak, lens = lens,
        scheduled = scheduled,
    })
    return scheduled
end

-- ============== PUBLIC API ==============

--- Initialize the exposure module.
--- @return boolean success
function Exposure.Init()
    if isInitialized then
        Log.Warn(MODULE, "Already initialized")
        return true
    end

    local cfg = Config.Exposure
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.SlotCount then SLOT_COUNT = cfg.SlotCount end
        if cfg.SlotSizeTOD then SLOT_SIZE_TOD = cfg.SlotSizeTOD end
        if cfg.UpdateIntervalSeconds then UPDATE_INTERVAL = cfg.UpdateIntervalSeconds end
        if cfg.CvarSky then CVAR_SKY = cfg.CvarSky end
        if cfg.CvarLeak then CVAR_LEAK = cfg.CvarLeak end
        if cfg.CvarLens then CVAR_LENS = cfg.CvarLens end
        if type(cfg.Slots) == "table" then slots = cfg.Slots end
    end

    isInitialized = true
    State.SetModuleStatus("exposure", true)

    if not enabled then
        Log.Info(MODULE, "Exposure module disabled in config")
        return true
    end

    Log.Info(MODULE, "Initializing exposure module", {
        slots = SLOT_COUNT,
        intervalSec = UPDATE_INTERVAL,
        haveTable = (next(slots) ~= nil),
    })
    return true
end

--- Force the next tick to re-apply the current slot (e.g. after a course load,
--- where a map change may have reset engine CVARs).
function Exposure.OnCourseLoad()
    currentSlot = nil
    lastCheckClock = 0.0
    lastApplied.sky, lastApplied.leak, lastApplied.lens = nil, nil, nil
end

--- Per-tick update. Cheap: only re-evaluates the slot every UPDATE_INTERVAL
--- seconds, and only issues console commands when the slot actually changes.
function Exposure.Update()
    if not enabled then return true end

    -- Throttle: this is driven by the 8 Hz main loop but only needs ~0.5 Hz.
    local now = os.clock()
    if (now - lastCheckClock) < UPDATE_INTERVAL then return true end
    lastCheckClock = now

    local actors = getActors()
    if not actors then return true end

    -- Garage: force the night slot (slot 0). Works without UDS actors.
    if actors.IsInGarage and actors.IsInGarage() then
        local cfg = slots[1]
        if cfg then
            currentSlot = 0
            lastInterpLens = cfg.lens
            applyValues(cfg.sky, cfg.leak, cfg.lens, 0.0, "garage")
        end
        return true
    end

    -- Course: interpolate between the current slot and the next so the exposure
    -- ramps continuously instead of snapping at 30-min boundaries (kills the
    -- dawn/dusk cliffs). The interpolated lens is also the brightness signal the
    -- headlights module consumes (GetBrightnessLens).
    local tod = getTimeOfDay()
    if not tod then return true end
    local currentTOD = tod.GetCurrentTOD()
    if not currentTOD then return true end   -- no valid UDS read this cycle

    currentTOD = clamp(currentTOD, 0.0, 2400.0)
    local f = currentTOD / SLOT_SIZE_TOD
    local slot = clamp(math.floor(f), 0, SLOT_COUNT - 1)
    local frac = clamp(f - slot, 0.0, 1.0)

    local a = slots[slot + 1]
    if not a then return true end
    local b = slots[(slot + 1) % SLOT_COUNT + 1] or a  -- next slot, wraps 48->1

    local sky  = lerp(a.sky,  b.sky,  frac)
    local leak = lerp(a.leak, b.leak, frac)
    local lens = lerp(a.lens, b.lens, frac)

    currentSlot = slot
    lastInterpLens = lens
    applyValues(sky, leak, lens, currentTOD, "slot " .. slot)
    return true
end

--- Current interpolated lens value: the exposure brightness proxy (~0.78 bright
--- day .. ~30 deep night). The headlights module reads this so the lamps track
--- exposure instead of a hardcoded clock. nil until the first on-course evaluation.
--- @return number|nil
function Exposure.GetBrightnessLens()
    return lastInterpLens
end

--- Log one tuning datapoint when the player flags the current lighting as too
--- dark / too bright (debug keybinds). Captures the time, weather, world context,
--- and the exposure values actually in effect, so reading the log afterwards tells
--- us which slot to nudge and in which direction. Greppable tag: "ExposureTune".
--- The `where` field also diagnoses the "exposure not active in cutscenes" report:
--- if it isn't "course" during a cutscene, the cutscene world isn't being driven.
--- @param direction string "dark" (too dark) | "bright" (too bright)
function Exposure.LogFeedback(direction)
    local tod, todStr = nil, "--:--"
    local t = getTimeOfDay()
    if t then
        local ok, v = pcall(t.GetCurrentTOD)
        if ok then tod = v end
        if t.FormatTime then pcall(function() todStr = t.FormatTime(tod) end) end
    end

    local preset = "unknown"
    pcall(function() preset = State.GetCurrentPreset() or "none" end)

    local where = "unknown"
    local actors = getActors()
    if actors then
        if actors.IsInGarage and actors.IsInGarage() then
            where = "garage"
        elseif actors.GetWorldTag then
            pcall(function() where = actors.GetWorldTag() or "unknown" end)
        end
    end

    Log.Info("ExposureTune", "FEEDBACK too-" .. tostring(direction), {
        verdict      = direction,                 -- "dark" or "bright"
        time         = todStr,
        tod          = tod and string.format("%.0f", tod) or "nil",
        weather      = preset,
        where        = where,                     -- course/pa/garage/outgame/unknown
        slot         = currentSlot,
        applied_sky  = lastApplied.sky,
        applied_leak = lastApplied.leak,
        applied_lens = lastApplied.lens,
        interp_lens  = lastInterpLens,
    })
end

-- Alias so the module can be ticked as either Tick() or Update().
Exposure.Tick = Exposure.Update

--- Status for debugging.
--- @return table
function Exposure.GetStatus()
    return {
        initialized = isInitialized,
        enabled = enabled,
        currentSlot = currentSlot,
        slotCount = SLOT_COUNT,
        haveTable = (next(slots) ~= nil),
    }
end

--- @return boolean
function Exposure.IsInitialized()
    return isInitialized
end

return Exposure
