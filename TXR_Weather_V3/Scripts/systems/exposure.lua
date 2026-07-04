-- TXR Weather Mod v3.0
-- systems/exposure.lua
-- Phase 13: Auto-exposure scheduler (ported from the standalone VEAO mod)
-- Maps Time Of Day -> per-slot Lumen/eye-adaptation console variables.
-- 144 slots of 10 min each across 00:00-24:00 (TOD units 0..2400). Garage forces
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
local SLOT_COUNT = 144
local SLOT_SIZE_TOD = 2400 / 144    -- 16.667 TOD units = 10 minutes
local UPDATE_INTERVAL = 2.0         -- seconds between slot re-evaluations
local CVAR_SKY  = "r.SkylightIntensityMultiplier"
local CVAR_LEAK = "r.Lumen.SkylightLeaking.ReflectionAverageAlbedo"
local CVAR_LENS = "r.EyeAdaptation.LensAttenuation"
local CVAR_ROUGH = "r.Lumen.SkylightLeaking.Roughness"  -- tuning keybinds only, not slot-driven
local TUNE_STEP = 0.05
local ROUGH_BASELINE = 1.0          -- engine.ini boot value; keep in sync (1.0 = max, engine clamps)

-- Slot table: [1..144] = { sky=<float>, leak=<float>, lens=<float> }
-- Populated from Config.Exposure.Slots in Init (falls back to empty -> no-op).
local slots = {}

-- ============== STATE ==============
local isInitialized = false
local currentSlot = nil             -- last evaluated slot (0-based), nil = none yet
local lastCheckClock = 0.0          -- os.clock() of last evaluation (throttle)
local lastInterpLens = nil          -- last interpolated lens (brightness proxy; see GetBrightnessLens)
local lastApplied = { sky = nil, leak = nil, lens = nil }  -- last pushed cvar values (skip redundant pushes)
-- Skylight tuning overrides (Alt+Z/X/C keybinds). While set, sky/leak take these
-- values instead of the slot curve (applyValues substitutes them, so they survive
-- slot flips and transitions). rough is not slot-driven: its override is pushed
-- once per nudge; a course load resets the cvar to engine.ini, re-nudge after loads.
local tune = { sky = nil, leak = nil, rough = nil }
local TUNE_LIMITS = {
    sky   = { min = 0.0, max = 4.0, fallback = 1.0 },
    leak  = { min = 0.0, max = 1.0, fallback = 0.07 },
    rough = { min = 0.0, max = 1.0 },   -- fallback = ROUGH_BASELINE (1.0 is the real max)
}

-- Per-weather compensation (Config.Exposure.WeatherLensMult / WeatherSkyMult).
-- The slot curve is tuned for clear skies; overcast/rain is darker at the same
-- TOD. The 2026-07-04 feedback runs showed the LENS lever barely reads on screen
-- (lens 34 -> 78 under overcast night = no perceived change), so the SKY
-- multiplier (r.SkylightIntensityMultiplier - the actual brightness lever, and
-- the very light overcast blocks) carries the compensation now; lens stays as a
-- secondary. Both are SMOOTHED toward the preset's target so changes don't pop.
local WEATHER_MULT = {}
local WEATHER_SKY_MULT = {}
local MULT_SMOOTH_SECONDS = 20.0
local weatherMult = 1.0
local weatherSkyMult = 1.0
local lastMultClock = nil
local armed = false                 -- course-exposure gate. False during a course/PA entry until
                                    -- the restore has run (OnCourseLoad). A freshly (re)spawned UDS
                                    -- reports Time Of Day = 0 before restore; without this gate the
                                    -- course branch reads that 0, picks the midnight slot, and flashes
                                    -- full-night exposure over a daytime scene for one tick. The garage
                                    -- branch is intentionally NOT gated by this.

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

-- Cached console singletons. The Engine and the KismetSystemLibrary are persistent
-- singletons, so resolving them ONCE and reusing avoids a FindFirstOf("Engine") (a
-- UObject-array scan) plus a GetKismetSystemLibrary per cvar per push. At the 0.5 s
-- re-eval rate that scan ran several times a second on the game thread during
-- transitions - the dawn/dusk frame hitches. Re-resolved only if they go invalid.
local cachedEngine = nil
local cachedKsl = nil

local function validRef(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function getEngineRef()
    if validRef(cachedEngine) then return cachedEngine end
    local eng = nil
    pcall(function() eng = FindFirstOf("Engine") end)
    if validRef(eng) then cachedEngine = eng; return eng end
    return nil
end

local function getKslRef()
    if validRef(cachedKsl) then return cachedKsl end
    local UEH = getUEHelpers()
    if not UEH or not UEH.GetKismetSystemLibrary then return nil end
    local ksl = nil
    pcall(function() ksl = UEH.GetKismetSystemLibrary() end)
    if validRef(ksl) then cachedKsl = ksl; return ksl end
    return nil
end

--- Schedule a batch of console commands on the game thread. TXR's module ticks
--- run on UE4SS's async LoopAsync thread; issuing r.* render CVAR commands off
--- the game thread races the render thread and crashes (access violation) during
--- course load, so we marshal onto the game thread (as the standalone VEAO did).
--- The Engine/Kismet refs are resolved ONCE per batch (cached), not per command.
--- @param cmds string[]
--- @return boolean scheduled
local function scheduleExec(cmds)
    if not cmds or #cmds == 0 then return false end
    local run = function()
        local ksl = getKslRef()
        local eng = getEngineRef()
        if not ksl or not eng then return end
        for _, cmd in ipairs(cmds) do
            pcall(function() ksl:ExecuteConsoleCommand(eng, cmd, nil) end)
        end
    end
    if ExecuteInGameThread then
        return pcall(function() ExecuteInGameThread(run) end)
    end
    -- Fallback (older UE4SS without ExecuteInGameThread): best-effort direct
    run()
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
    -- Skylight tuning overrides win over the slot curve (see NudgeSkylight)
    if tune.sky  then sky  = tune.sky  end
    if tune.leak then leak = tune.leak end
    -- Push ONLY the cvars that actually changed. leak is constant across the whole
    -- table, so after the first push it is never re-emitted - that drops a third of
    -- the console commands (and a Lumen cvar write) on every transition step. sky and
    -- lens only emit while they are ramping; the flat day/night cores emit nothing.
    local cmds = {}
    if not lastApplied.sky  or math.abs(sky  - lastApplied.sky)  >= eps then
        cmds[#cmds + 1] = string.format("%s %.6f", CVAR_SKY,  sky)
    end
    if not lastApplied.leak or math.abs(leak - lastApplied.leak) >= eps then
        cmds[#cmds + 1] = string.format("%s %.6f", CVAR_LEAK, leak)
    end
    if not lastApplied.lens or math.abs(lens - lastApplied.lens) >= eps then
        cmds[#cmds + 1] = string.format("%s %.6f", CVAR_LENS, lens)
    end
    if #cmds == 0 then return true end   -- unchanged: skip redundant push

    local scheduled = scheduleExec(cmds)

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
        if type(cfg.Tune) == "table" then
            if cfg.Tune.Step then TUNE_STEP = cfg.Tune.Step end
            if cfg.Tune.CvarRough then CVAR_ROUGH = cfg.Tune.CvarRough end
            if cfg.Tune.RoughnessBaseline then ROUGH_BASELINE = cfg.Tune.RoughnessBaseline end
        end
        if type(cfg.WeatherLensMult) == "table" then WEATHER_MULT = cfg.WeatherLensMult end
        if type(cfg.WeatherSkyMult) == "table" then WEATHER_SKY_MULT = cfg.WeatherSkyMult end
        if cfg.WeatherLensSmoothSeconds then MULT_SMOOTH_SECONDS = cfg.WeatherLensSmoothSeconds end
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
--- where a map change may have reset engine CVARs). Called by main AFTER the state
--- restore, so this is also where we arm the course branch (see `armed`).
function Exposure.OnCourseLoad()
    currentSlot = nil
    lastCheckClock = 0.0
    lastApplied.sky, lastApplied.leak, lastApplied.lens = nil, nil, nil
    -- Clear the brightness proxy too: a stale night-lens from the previous course
    -- would otherwise make the headlight auto assert lights ON at a daytime entry
    -- before the first re-evaluation. nil makes headlights fall back to TOD instead.
    lastInterpLens = nil
    armed = true
end

--- Disarm the course branch when the course unloads / actors are lost. Until the
--- next OnCourseLoad (post-restore) the course branch is suppressed, so the
--- entry-transient TOD=0 read can't flash the midnight slot. Garage is unaffected.
function Exposure.OnCourseUnload()
    armed = false
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

    -- Course: skip until the entry restore has armed us. A just-(re)spawned UDS
    -- reads Time Of Day = 0 before restore; applying that would flash the midnight
    -- slot (full-night sky/lens) over a daytime scene for one tick on every PA/course
    -- entry. Armed in OnCourseLoad (post-restore), disarmed in OnCourseUnload.
    if not armed then return true end

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
    local b = slots[(slot + 1) % SLOT_COUNT + 1] or a  -- next slot, wraps last->1

    local sky  = lerp(a.sky,  b.sky,  frac)
    local leak = lerp(a.leak, b.leak, frac)
    local lens = lerp(a.lens, b.lens, frac)

    -- Weather compensation: scale sky (the effective brightness lever) and lens
    -- by the active preset's multipliers, smoothed toward the targets so preset
    -- changes don't pop the exposure. Lens is intentionally applied to the
    -- headlight brightness proxy too (lastInterpLens): lamps should come on
    -- earlier under overcast.
    local target, skyTarget = 1.0, 1.0
    local preset = nil
    pcall(function() preset = State.GetCurrentPreset() end)
    if preset then
        if WEATHER_MULT[preset] then target = WEATHER_MULT[preset] end
        if WEATHER_SKY_MULT[preset] then skyTarget = WEATHER_SKY_MULT[preset] end
    end
    local dtm = 0.5
    if lastMultClock then dtm = clamp(now - lastMultClock, 0.0, 5.0) end
    lastMultClock = now
    if MULT_SMOOTH_SECONDS > 0 then
        local blend = clamp(dtm / MULT_SMOOTH_SECONDS, 0.0, 1.0)
        weatherMult = weatherMult + (target - weatherMult) * blend
        weatherSkyMult = weatherSkyMult + (skyTarget - weatherSkyMult) * blend
    else
        weatherMult = target
        weatherSkyMult = skyTarget
    end
    lens = lens * weatherMult
    sky = sky * weatherSkyMult

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
--- Capture the shared tuning-log context: time, weather preset, world tag.
--- @return number|nil tod, string todStr, string preset, string where
local function captureContext()
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

    return tod, todStr, preset, where
end

--- @param direction string "dark" (too dark) | "bright" (too bright)
function Exposure.LogFeedback(direction)
    local tod, todStr, preset, where = captureContext()

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
        weather_mult = weatherMult,       -- lens = slot curve * this (per-weather comp)
        weather_sky_mult = weatherSkyMult, -- sky = slot curve * this (the brightness lever)
    })
end

--- Nudge one of the skylight cvars by one Tune.Step (skylight tuning keybinds).
--- The new value becomes an override: sky/leak hold it across slot flips and
--- transitions until ResetSkylightTune; rough is pushed directly (nothing else
--- writes it at runtime, but a course load resets it to the engine.ini value).
--- @param which string "sky" | "leak" | "rough"
--- @param dir number +1 (raise) | -1 (lower)
function Exposure.NudgeSkylight(which, dir)
    local lim = TUNE_LIMITS[which]
    if not lim then
        Log.Warn(MODULE, "NudgeSkylight: unknown cvar key", {which = tostring(which)})
        return
    end

    local cur = tune[which]
    if cur == nil then
        if which == "rough" then
            cur = ROUGH_BASELINE
        else
            cur = lastApplied[which] or lim.fallback
        end
    end

    local new = clamp(cur + dir * TUNE_STEP, lim.min, lim.max)

    -- Already at the limit (key-repeat holds spam this case): nothing changes,
    -- so don't queue a no-op game-thread console push or log a NUDGE line.
    if new == cur then return end

    tune[which] = new

    local cvar = (which == "sky" and CVAR_SKY) or (which == "leak" and CVAR_LEAK) or CVAR_ROUGH
    scheduleExec({ string.format("%s %.6f", cvar, new) })
    -- Keep the change-detection in sync so the next slot evaluation does not
    -- immediately re-emit the same (overridden) value.
    if which ~= "rough" then lastApplied[which] = new end

    Log.Info("SkylightTune", "NUDGE " .. which .. (dir > 0 and " +" or " -"), {
        cvar = cvar,
        from = string.format("%.3f", cur),
        to   = string.format("%.3f", new),
        slot = currentSlot,
    })
end

--- Log one skylight tuning datapoint (confirm keybind): time, weather, world
--- context, and the three skylight values in effect. Greppable tag: "SkylightTune".
--- rough falls back to the engine.ini baseline when never nudged this session.
function Exposure.LogSkylightConfirm()
    local tod, todStr, preset, where = captureContext()

    local overridden = {}
    for _, k in ipairs({"sky", "leak", "rough"}) do
        if tune[k] then overridden[#overridden + 1] = k end
    end

    Log.Info("SkylightTune", "CONFIRM", {
        time      = todStr,
        tod       = tod and string.format("%.0f", tod) or "nil",
        weather   = preset,
        where     = where,
        slot      = currentSlot,
        albedo    = tune.leak or lastApplied.leak,
        rough     = tune.rough or ROUGH_BASELINE,
        sky       = tune.sky or lastApplied.sky,
        overrides = (#overridden > 0) and table.concat(overridden, ",") or "none",
    })
end

--- Drop all skylight tuning overrides: rough goes back to the engine.ini
--- baseline now, sky/leak fall back to the slot curve on the next evaluation.
function Exposure.ResetSkylightTune()
    tune.sky, tune.leak, tune.rough = nil, nil, nil
    scheduleExec({ string.format("%s %.6f", CVAR_ROUGH, ROUGH_BASELINE) })
    -- Force the next Update to re-emit the slot values immediately
    lastApplied.sky, lastApplied.leak = nil, nil
    lastCheckClock = 0.0
    Log.Info("SkylightTune", "RESET to slot curve", {slot = currentSlot})
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
