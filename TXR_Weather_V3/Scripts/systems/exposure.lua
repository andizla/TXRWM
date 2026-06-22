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
local currentSlot = nil             -- last applied slot (0-based), nil = none yet
local lastCheckClock = 0.0          -- os.clock() of last evaluation (throttle)

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

--- Apply a slot's CVARs.
--- @param slotZeroBased number 0..SLOT_COUNT-1
--- @param tod number for logging
--- @return boolean success (commands scheduled)
local function applySlot(slotZeroBased, tod)
    local idx = slotZeroBased + 1   -- 0-based slot -> 1-based table index
    local cfg = slots[idx]
    if not cfg then
        Log.Warn(MODULE, "Slot has no config", {slot = slotZeroBased, idx = idx, tod = tod})
        return false
    end

    local scheduled = scheduleExec({
        string.format("%s %.6f", CVAR_SKY,  cfg.sky),
        string.format("%s %.6f", CVAR_LEAK, cfg.leak),
        string.format("%s %.6f", CVAR_LENS, cfg.lens),
    })

    Log.Info(MODULE, "Applied exposure slot", {
        slot = slotZeroBased,
        tod = string.format("%.0f", tod),
        sky = cfg.sky,
        leak = cfg.leak,
        lens = cfg.lens,
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
        if currentSlot ~= 0 then
            currentSlot = 0
            applySlot(0, 0.0)
        end
        return true
    end

    -- Course: pick the slot from current TOD.
    local tod = getTimeOfDay()
    if not tod then return true end
    local currentTOD = tod.GetCurrentTOD()
    if not currentTOD then return true end   -- no valid UDS read this cycle

    currentTOD = clamp(currentTOD, 0.0, 2400.0)
    local slot = clamp(math.floor(currentTOD / SLOT_SIZE_TOD), 0, SLOT_COUNT - 1)

    if slot ~= currentSlot then
        currentSlot = slot
        applySlot(slot, currentTOD)
    end

    return true
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
