-- TXR Weather Mod v3.0
-- systems/tuning.lua
-- Native tuning slider-range widening for the alignment tab (camber, toe,
-- ride height, wheel offset). Successor to the abandoned WheelOffsetUnlocker
-- (NadzW / FenderBender, 04.2025); approach credited to them, rebuilt against
-- the v1.5 API.
--
-- What the game does: the alignment settings menu (WBP_OutGame_Setting_List_
-- Aliment2) builds one row per setting, each with two WBP_Com_Slider_1 widgets
-- (front/rear) whose min/max come from the game's own SetSettingListInit. The
-- slider value is stored into the car save on Decide (values persist even past
-- stock range), but the game's LOAD path does not apply out-of-range values to
-- the car, so extremes need re-asserting on spawn (the physical setters accept
-- them fine).
--
-- What this module does (all game-thread, tick-driven like photomode's FOV
-- slider widening):
--  1. WIDEN: while the alignment tab exists, scale every unlocked row's slider
--     range to RangeMultiplier x its own stock range (multiplicative, so each
--     setting keeps its semantics; locked rows are skipped, this mod does NOT
--     unlock parts).
--  2. LIVE PREVIEW: post-hooks on the tab's own ValueChange events re-apply the
--     slider value through the physical setters (SetWheelOffset /
--     SetSettingHightOffsetRate / SetTireCamberAngle / SetToeAngleFromSetting)
--     so values beyond stock range show on the displayed car (the game's own
--     handler clamps).
--  3. RE-APPLY ON LOAD: on course load (settle-gated) and on garage car display,
--     read the stored setting parameters (UserInfoGameInstanceSubsystem:
--     GetSelectedCarSettingParameter) and push them through the setters, since
--     the game's own load path won't apply extremes.
--
-- v1.5 API notes (verified against the dump / shared types):
-- , stored-parameter scales: offset /1000, ride height /500, camber /-100,
--    toe raw; slider-value scales: offset /10, ride height /5, camber *-1,
--    toe raw (ECarSetting: camber 6/7, toe 8/9, ride height 18/19, offset 26/27).
-- , the old mod's MaxValue/MinValue/step_value wrapper properties do not exist
--    in 1.5 (only max_value/min_value/step_size + SetSliderInit).
-- , the tab now has FIVE element rows (tire width was added), so the old
--    hardcoded element mapping is stale; we iterate all rows and skip locked.

local Tuning = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")
local Config = require("config")

local Actors = nil  -- lazy
local UEH = nil     -- lazy

local MODULE = "Tuning"

-- ============== CONFIG (filled in Init) ==============
local enabled = true
local rangeMultiplier = 3.0
local skipLockedRows = true
local reapplyOnLoad = true
local debugRows = true

-- ============== GAME OBJECT NAMES (v1.5) ==============
local GARAGE_MANAGER_CLASS = "BP_OutGameGarageManager_C"
local USERINFO_CLASS = "UserInfoGameInstanceSubsystem"

-- The alignment rows are ListView ENTRY widgets built at runtime (the element
-- class implements OnListItemObjectSet); the named Element_1..4 fields on the
-- tab are design-time placeholders that read invalid on the live widget
-- (verified in-game 2026-07-02: only the placeholder row, name "パーツ名", was
-- reachable through the fields). So we enumerate live element instances by
-- CLASS instead of walking the tab's fields.
local ELEMENT_CLASS = "WBP_OutGame_Setting_List_Aliment_Element_C"
local CONTENT_CLASS = "WBP_OutGame_Setting_List_Element_Content_C"
local CONTENT_FIELDS = {
    "WBP_OutGame_Setting_List_Other_Element_Content",
    "WBP_OutGame_Setting_List_Other_Element_Content_1",
}

local HOOK_BASE = "/Game/ITSB/UI/OutGame/Setting/Widgets/WBP_OutGame_Setting_List_Aliment2.WBP_OutGame_Setting_List_Aliment2_C:"
local GARAGE_HOOK_BASE = "/Game/ITSB/UI/OutGame/Blueprints/BP_OutGameGarageManager.BP_OutGameGarageManager_C:"

-- Stored car-setting parameters (ECarSetting index -> physical setter + scale)
local STORED_SETTINGS = {
    { name = "camber_front",     idx = 6,  scale = -0.01,  fn = "SetTireCamberAngle",       front = true,  extra = false },
    { name = "camber_rear",      idx = 7,  scale = -0.01,  fn = "SetTireCamberAngle",       front = false, extra = false },
    { name = "toe_front",        idx = 8,  scale = 1.0,    fn = "SetToeAngleFromSetting",   front = true,  extra = false },
    { name = "toe_rear",         idx = 9,  scale = 1.0,    fn = "SetToeAngleFromSetting",   front = false, extra = false },
    { name = "ride_height_front", idx = 18, scale = 0.002, fn = "SetSettingHightOffsetRate", front = true,  extra = true },
    { name = "ride_height_rear",  idx = 19, scale = 0.002, fn = "SetSettingHightOffsetRate", front = false, extra = true },
    { name = "offset_front",     idx = 26, scale = 0.001,  fn = "SetWheelOffset",           front = true,  extra = false },
    { name = "offset_rear",      idx = 27, scale = 0.001,  fn = "SetWheelOffset",           front = false, extra = false },
}

-- Live-preview hooks: slider value -> physical setter (the game's own handler
-- applies a clamped copy; these post-hooks re-apply unclamped)
local VALUE_HOOKS = {
    { event = "OFFSETFrontValueChange",     fn = "SetWheelOffset",           front = true,  scale = 0.1, extra = false },
    { event = "OFFSETRearValueChange",      fn = "SetWheelOffset",           front = false, scale = 0.1, extra = false },
    { event = "RIDEHEIGHTFrontValueChange", fn = "SetSettingHightOffsetRate", front = true,  scale = 0.2, extra = true },
    { event = "RIDEHEIGHTRearValueChange",  fn = "SetSettingHightOffsetRate", front = false, scale = 0.2, extra = true },
    { event = "TOEFrontValueChange",        fn = "SetToeAngleFromSetting",   front = true,  scale = 1.0, extra = false },
    { event = "TOERearValueChange",         fn = "SetToeAngleFromSetting",   front = false, scale = 1.0, extra = false },
    { event = "CamberFrontChangeValue",     fn = "SetTireCamberAngle",       front = true,  scale = -1.0, extra = false },
    { event = "CamberRearChangeValue",      fn = "SetTireCamberAngle",       front = false, scale = -1.0, extra = false },
}

local SETTLE_TICKS = 32     -- ~4s at 8 Hz before the course re-apply
local SCAN_INTERVAL = 8     -- ~1s between menu scans

-- ============== STATE ==============
local isInitialized = false
local scanCounter = 0
local courseTicks = 0
local courseApplied = false
local pendingScan = false
local valueHooksRegistered = false
local garageHooksRegistered = false
local widened = {}     -- slider address -> {min, max} we last applied
local probedRows = {}  -- element address -> true (debug row logging, once each)
local skipLogged = {}  -- one skip/probe/hook-fail log per address (Debug)
                       -- (declared BEFORE registerValueHooksGT: it used to be
                       -- declared lower, so that function captured a nil GLOBAL
                       -- and the hook-retry path errored out of the whole scan)

-- ============== INTERNAL ==============

local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

local function getUEH()
    if not UEH then pcall(function() UEH = require("UEHelpers") end) end
    return UEH
end

local function valid(obj)
    return obj ~= nil and obj.IsValid and obj:IsValid()
end

local function runOnGameThread(fn)
    if ExecuteInGameThread then
        pcall(function() ExecuteInGameThread(fn) end)
    else
        fn()
    end
end

--- Apply one physical setter on a vehicle (handles the ride-height out-param)
local function applySetter(car, fnName, front, value, hasExtra)
    return pcall(function()
        if hasExtra then
            car[fnName](car, front, value, {})
        else
            car[fnName](car, front, value)
        end
    end)
end

--- Push all stored alignment parameters through the physical setters.
--- Game thread only.
local function applyStoredToVehicleGT(car, context)
    if not valid(car) then return false end
    local ui = FindFirstOf(USERINFO_CLASS)
    if not valid(ui) then return false end

    local count = 0
    for _, s in ipairs(STORED_SETTINGS) do
        local raw = nil
        pcall(function() raw = tonumber(ui:GetSelectedCarSettingParameter(s.idx, {})) end)
        if raw then
            if applySetter(car, s.fn, s.front, raw * s.scale, s.extra) then
                count = count + 1
            end
        end
    end
    Log.Info(MODULE, "Re-applied stored alignment", {context = context, applied = count})
    return count > 0
end

--- Course-side re-apply target: the player pawn
local function applyStoredToPlayerGT()
    local ueh = getUEH()
    if not ueh then return end
    local pawn = nil
    pcall(function() pawn = ueh.GetPlayerController().Pawn end)
    if valid(pawn) then
        applyStoredToVehicleGT(pawn, "course")
    end
end

--- Garage-side re-apply target: the displayed vehicle (after a short delay so
--- the game's own display/load finishes first)
local function applyStoredToDisplayVehicleDeferred(context)
    local run = function()
        runOnGameThread(function()
            local gm = FindFirstOf(GARAGE_MANAGER_CLASS)
            if not valid(gm) then return end
            local out = {}
            local ok = pcall(function() gm:GetDisplayVehicle(out) end)
            if ok and valid(out.out_vehicle) then
                applyStoredToVehicleGT(out.out_vehicle, context)
            end
        end)
    end
    if ExecuteWithDelay then
        pcall(function() ExecuteWithDelay(250, run) end)
    else
        run()
    end
end

--- Register the live-preview hooks on the alignment tab's value events.
--- RegisterHook fires BEFORE the game's own handler (which clamps its apply to
--- the stock range), so the actual re-apply is deferred ~100ms to land after it.
--- Call only when the widget class is loaded (an instance exists). Game thread.
local hookDone = {}  -- per-event success (failed ones retry on later scans)

local function registerValueHooksGT()
    if valueHooksRegistered then return end
    local allOk = true
    for _, h in ipairs(VALUE_HOOKS) do
        if hookDone[h.event] then goto continue end
        local fnName, front, scale, extra = h.fn, h.front, h.scale, h.extra
        local ok, err = pcall(function()
            RegisterHook(HOOK_BASE .. h.event, function(Context, Value)
                local w, v = nil, nil
                pcall(function() w = Context:get() end)
                pcall(function() v = tonumber(Value:get()) end)
                if w == nil or v == nil then return end
                local reapply = function()
                    runOnGameThread(function()
                        pcall(function()
                            if not valid(w) then return end
                            local car = w.car
                            if valid(car) then
                                applySetter(car, fnName, front, v * scale, extra)
                            end
                        end)
                    end)
                end
                if ExecuteWithDelay then
                    pcall(function() ExecuteWithDelay(100, reapply) end)
                else
                    reapply()
                end
            end)
        end)
        if ok then
            hookDone[h.event] = true
        else
            allOk = false
            if not skipLogged["hookfail_" .. h.event] then
                skipLogged["hookfail_" .. h.event] = true
                Log.Warn(MODULE, "Value hook failed to register (will retry)", {event = h.event, error = tostring(err)})
            end
        end
        ::continue::
    end
    if allOk then
        valueHooksRegistered = true
        Log.Info(MODULE, "Alignment value hooks registered")
    end
end

--- Register the garage re-apply hooks (car displayed / car changed).
--- Call only when the garage manager class is loaded. Game thread.
local function registerGarageHooksGT()
    if garageHooksRegistered then return end
    garageHooksRegistered = true
    for _, ev in ipairs({ "DisplayMyCar", "Change My Vehicle" }) do
        local ok, err = pcall(function()
            RegisterHook(GARAGE_HOOK_BASE .. ev, function()
                applyStoredToDisplayVehicleDeferred("garage_" .. ev)
            end)
        end)
        if not ok then
            Log.Warn(MODULE, "Garage hook failed to register", {event = ev, error = tostring(err)})
        end
    end
    Log.Info(MODULE, "Garage re-apply hooks registered")
end

local function textOf(widget)
    local s = nil
    pcall(function() s = widget:GetText():ToString() end)
    return s or "?"
end

local function logSkipOnce(addr, rowName, side, reason)
    if not debugRows or not addr or skipLogged[addr] then return end
    skipLogged[addr] = true
    Log.Info(MODULE, "Slider skipped", {row = rowName, side = side, reason = reason})
end

--- Widen one slider to rangeMultiplier x its current (stock) range.
--- In-game probe 2026-07-02: this menu never fills the WRAPPER's
--- min_value/max_value (they read 0/0 on live rows); the working range lives
--- on the inner AnalogSlider (USlider MinValue/MaxValue floats). So the
--- AnalogSlider is what we probe and widen; the wrapper props and SetSliderInit
--- are left alone. Guard: an AnalogSlider reading exactly 0..1 is a normalized
--- display slider (real range in BP math); logged and not touched.
--- Idempotent per slider instance via the `widened` cache. Game thread.
local function widenSliderGT(slider, rowName, side)
    if not valid(slider) then return end
    local analog = nil
    pcall(function() analog = slider.AnalogSlider end)
    if not valid(analog) then
        local addr = nil
        pcall(function() addr = slider:GetAddress() end)
        logSkipOnce(addr, rowName, side, "no_analog_slider")
        return
    end

    local mn, mx, st, val = nil, nil, nil, nil
    pcall(function() mn = tonumber(analog.MinValue) end)
    pcall(function() mx = tonumber(analog.MaxValue) end)
    pcall(function() st = tonumber(analog.StepSize) end)
    pcall(function() val = tonumber(analog.Value) end)

    local addr = nil
    pcall(function() addr = slider:GetAddress() end)
    if not addr then return end

    -- One-shot probe of the live values (this is the ground truth for where
    -- the range lives; wrapper trio included for comparison)
    if debugRows and not skipLogged["probe_" .. addr] then
        skipLogged["probe_" .. addr] = true
        local wmn, wmx, wst = nil, nil, nil
        pcall(function() wmn = tonumber(slider.min_value) end)
        pcall(function() wmx = tonumber(slider.max_value) end)
        pcall(function() wst = tonumber(slider.step_size) end)
        Log.Info(MODULE, "Slider probe", {
            row = rowName, side = side,
            analog = string.format("min=%s max=%s step=%s value=%s", tostring(mn), tostring(mx), tostring(st), tostring(val)),
            wrapper = string.format("min=%s max=%s step=%s", tostring(wmn), tostring(wmx), tostring(wst)),
        })
    end

    if mn == nil or mx == nil or mx <= mn then
        logSkipOnce("range_" .. addr, rowName, side, string.format("no_range (min=%s max=%s)", tostring(mn), tostring(mx)))
        return
    end
    if mn > -0.0001 and mn < 0.0001 and mx > 0.9999 and mx < 1.0001 then
        logSkipOnce("norm_" .. addr, rowName, side, "normalized_0_1 (range lives in BP math, not the slider)")
        return
    end

    local rec = widened[addr]
    if rec and math.abs(mx - rec.max) < 1e-6 and math.abs(mn - rec.min) < 1e-6 then
        return  -- still ours from a previous pass
    end

    -- Current values are stock (fresh menu or the game re-initialized the row)
    local newMin, newMax = mn * rangeMultiplier, mx * rangeMultiplier
    pcall(function() analog:SetMinValue(newMin) end)
    pcall(function() analog:SetMaxValue(newMax) end)

    widened[addr] = {min = newMin, max = newMax}
    if debugRows then
        Log.Info(MODULE, "Slider widened", {
            row = rowName, side = side,
            stock = string.format("%.2f..%.2f", mn, mx),
            new = string.format("%.2f..%.2f", newMin, newMax),
        })
    end
end

--- Scan the alignment tab (if open): register hooks, widen unlocked rows.
--- Game thread.
local function scanAndWidenGT()
    -- The scan was scheduled from the async tick; if a map teardown started in
    -- the meantime, do not walk the object array (dying widgets = read AV).
    local actors = getActors()
    if actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
        return
    end

    -- Lazy hook registration: garage manager exists in the whole OutGame world
    if not garageHooksRegistered and reapplyOnLoad then
        local gm = FindFirstOf(GARAGE_MANAGER_CLASS)
        if valid(gm) then registerGarageHooksGT() end
    end

    -- Live alignment rows: ListView entries, enumerated by class (the tab's
    -- named element fields only reach the design-time placeholder row).
    -- FILTERS (from the 2026-07-02 probe run): live UI objects sit under
    -- /Engine/Transient.GameEngine... (everything else is the blueprint's
    -- design-time archetype: invalid sliders, endless noise), and the element
    -- class is REUSED by the LSD tab, so require "Aliment2" (the tab) in the
    -- path, not just the class name.
    local sawLiveTab = false
    local elems = nil
    pcall(function() elems = FindAllOf(ELEMENT_CLASS) end)

    for _, elem in ipairs(elems or {}) do
        if valid(elem) then
            local efull = ""
            pcall(function() efull = elem:GetFullName() end)
            if efull:find("Transient", 1, true) and efull:find("Aliment2", 1, true) then
                sawLiveTab = true
                local rowName = "?"
                pcall(function() rowName = textOf(elem.Text_Name_Parts) end)
                local num = nil
                pcall(function() num = elem.in_item_num end)
                local rowTag = string.format("%s#%s", rowName, tostring(num))

                if debugRows then
                    local addr = nil
                    pcall(function() addr = elem:GetAddress() end)
                    if addr and not probedRows[addr] then
                        probedRows[addr] = true
                        Log.Info(MODULE, "Alignment row", {name = rowName, itemNum = tostring(num)})
                    end
                end

                for ci, contentField in ipairs(CONTENT_FIELDS) do
                    local content = nil
                    pcall(function() content = elem[contentField] end)
                    if valid(content) then
                        local locked = false
                        if skipLockedRows then
                            pcall(function() locked = content.is_locked == true end)
                        end
                        if locked then
                            local caddr = nil
                            pcall(function() caddr = content:GetAddress() end)
                            logSkipOnce(caddr, rowTag, ci == 1 and "front" or "rear", "locked")
                        else
                            local slider = nil
                            pcall(function() slider = content.WBP_Com_Slider end)
                            widenSliderGT(slider, rowTag, ci == 1 and "front" or "rear")
                        end
                    end
                end
            end
        end
    end

    -- Belt-and-braces: sweep live CONTENT widgets directly (catches rows built
    -- from a class we did not anticipate), same live + alignment-tab filters.
    -- The widened cache dedupes against the loop above.
    local contents = nil
    pcall(function() contents = FindAllOf(CONTENT_CLASS) end)
    if contents then
        for _, content in ipairs(contents) do
            if valid(content) then
                local full = ""
                pcall(function() full = content:GetFullName() end)
                if full:find("Transient", 1, true) and full:find("Aliment2", 1, true) then
                    sawLiveTab = true
                    local locked = false
                    if skipLockedRows then
                        pcall(function() locked = content.is_locked == true end)
                    end
                    if not locked then
                        local slider = nil
                        pcall(function() slider = content.WBP_Com_Slider end)
                        -- Row tag from the tail of the object path (element +
                        -- content names), enough to tell rows/sides apart
                        local tag = full:match("([%w_]+%.[%w_]+)$") or full
                        widenSliderGT(slider, tag, "path")
                    end
                end
            end
        end
    end

    -- Register the value hooks only once a LIVE alignment tab exists; at boot
    -- only the archetype is loaded and registration fails with UFunction::Func
    -- 0x0 (seen for OFFSETFrontValueChange on the 2026-07-02 run)
    if sawLiveTab and not valueHooksRegistered then
        registerValueHooksGT()
    end
end

local function scheduleScan()
    if pendingScan then return end
    pendingScan = true
    local scheduled = false
    if ExecuteInGameThread then
        scheduled = pcall(function()
            ExecuteInGameThread(function()
                pcall(scanAndWidenGT)
                pendingScan = false
            end)
        end)
    end
    if not scheduled then
        pcall(scanAndWidenGT)
        pendingScan = false
    end
end

-- ============== PUBLIC API ==============

function Tuning.Init()
    if isInitialized then return true end
    local cfg = Config.Tuning
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.RangeMultiplier ~= nil then rangeMultiplier = cfg.RangeMultiplier end
        if cfg.SkipLockedRows ~= nil then skipLockedRows = cfg.SkipLockedRows end
        if cfg.ReapplyOnLoad ~= nil then reapplyOnLoad = cfg.ReapplyOnLoad end
        if cfg.Debug ~= nil then debugRows = cfg.Debug end
    end
    if rangeMultiplier <= 1.0 then
        Log.Info(MODULE, "RangeMultiplier <= 1, tuning module inactive")
        enabled = false
    end
    isInitialized = true
    State.SetModuleStatus("tuning", true)
    Log.Info(MODULE, "Initializing tuning module", {enabled = enabled, multiplier = rangeMultiplier})
    return true
end

--- Per-tick (8 Hz, runs in AND out of course; the tuning menu is in the garage)
function Tuning.Tick()
    if not isInitialized or not enabled then return end

    -- Course-side re-apply of stored alignment, settle-gated once per course
    local onCourse = false
    local actors = getActors()
    if actors then onCourse = actors.IsOnCourse() end
    if reapplyOnLoad then
        if onCourse then
            courseTicks = courseTicks + 1
            if not courseApplied and courseTicks >= SETTLE_TICKS then
                courseApplied = true
                runOnGameThread(applyStoredToPlayerGT)
            end
        else
            courseTicks = 0
            courseApplied = false
        end
    end

    -- Menu scan (~1s): widen sliders, lazily register hooks. The tuning menu
    -- only exists in the garage/outgame. The old gate was just "not on course",
    -- which ALSO matched map transitions (IsOnCourse flips false the moment a
    -- course starts unloading) and PA, so the FindAllOf/GetFullName scans ran
    -- on the game thread while the world was being torn down, walking dying
    -- widget objects: the garage-transition crash. Scan only when the
    -- garage/outgame is POSITIVELY detected and no teardown is in progress.
    if onCourse then return end
    if not actors then return end
    if actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
        scanCounter = 0
        return
    end
    if not (actors.IsInGarage and actors.IsInGarage()) then return end
    scanCounter = scanCounter + 1
    if scanCounter >= SCAN_INTERVAL then
        scanCounter = 0
        scheduleScan()
    end
end

function Tuning.GetStatus()
    return {
        initialized = isInitialized,
        enabled = enabled,
        multiplier = rangeMultiplier,
        valueHooks = valueHooksRegistered,
        garageHooks = garageHooksRegistered,
        courseApplied = courseApplied,
    }
end

return Tuning
