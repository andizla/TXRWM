-- TXR Weather Mod v3.0
-- systems/keybinds.lua
-- Keyboard input handling for weather and time control

local Keybinds = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")
local Config = require("config")

-- Lazy-load these to avoid circular dependencies
local Weather = nil
local TimeOfDay = nil
local Shadows = nil
local Headlights = nil
local Scheduler = nil

local MODULE = "Keybinds"

-- ============== STATE ==============
local isInitialized = false
local registeredKeys = {}

-- ============== KEY MAPPING ==============
-- UE4SS Key constants (common ones)
local KEY_MAP = {
    -- Letters
    A = "A", B = "B", C = "C", D = "D", E = "E", F = "F", G = "G", H = "H",
    I = "I", J = "J", K = "K", L = "L", M = "M", N = "N", O = "O", P = "P",
    Q = "Q", R = "R", S = "S", T = "T", U = "U", V = "V", W = "W", X = "X",
    Y = "Y", Z = "Z",
    -- Numbers
    ["0"] = "ZERO", ["1"] = "ONE", ["2"] = "TWO", ["3"] = "THREE", ["4"] = "FOUR",
    ["5"] = "FIVE", ["6"] = "SIX", ["7"] = "SEVEN", ["8"] = "EIGHT", ["9"] = "NINE",
    -- Function keys
    F1 = "F1", F2 = "F2", F3 = "F3", F4 = "F4", F5 = "F5", F6 = "F6",
    F7 = "F7", F8 = "F8", F9 = "F9", F10 = "F10", F11 = "F11", F12 = "F12",
    -- Special
    SPACE = "SPACE", ENTER = "ENTER", ESCAPE = "ESCAPE",
    TAB = "TAB", BACKSPACE = "BACKSPACE",
    -- Arrow keys
    UP = "UP", DOWN = "DOWN", LEFT = "LEFT", RIGHT = "RIGHT",
    -- Numpad
    NUMPAD0 = "NUM_ZERO", NUMPAD1 = "NUM_ONE", NUMPAD2 = "NUM_TWO",
    NUMPAD3 = "NUM_THREE", NUMPAD4 = "NUM_FOUR", NUMPAD5 = "NUM_FIVE",
    NUMPAD6 = "NUM_SIX", NUMPAD7 = "NUM_SEVEN", NUMPAD8 = "NUM_EIGHT",
    NUMPAD9 = "NUM_NINE",
    -- numpad symbols (UE4SS Key names; unknown ones just warn + skip)
    NUMPADDOT = "DECIMAL", NUMPADPLUS = "ADD", NUMPADMINUS = "SUBTRACT",
    NUMPADMUL = "MULTIPLY", NUMPADDIV = "DIVIDE",
}

-- Modifier key bit flags for UE4SS
-- These may vary by UE4SS version, trying common values
local MODIFIER_FLAGS = {
    Shift = 1,
    Ctrl = 2,
    Control = 2,
    Alt = 4,
}

-- ============== INTERNAL FUNCTIONS ==============

--- Get lazy-loaded modules
local function getWeather()
    if not Weather then
        local success, mod = pcall(require, "systems.weather")
        if success then Weather = mod end
    end
    return Weather
end

local function getTimeOfDay()
    if not TimeOfDay then
        local success, mod = pcall(require, "systems.time_of_day")
        if success then TimeOfDay = mod end
    end
    return TimeOfDay
end

local function getShadows()
    if not Shadows then
        local success, mod = pcall(require, "systems.shadows")
        if success then Shadows = mod end
    end
    return Shadows
end

local function getHeadlights()
    if not Headlights then
        local success, mod = pcall(require, "systems.headlights")
        if success then Headlights = mod end
    end
    return Headlights
end

local function getScheduler()
    if not Scheduler then
        local success, mod = pcall(require, "systems.scheduler")
        if success then Scheduler = mod end
    end
    return Scheduler
end

-- Exposure provider for the Alt+D feedback/tuning family (LogFeedback /
-- NudgeSkylight / LogSkylightConfirm / ResetSkylightTune).
local LightCycleMod = nil
local function getExposure()
    if not LightCycleMod then
        local success, mod = pcall(require, "systems.light_cycle")
        if success then LightCycleMod = mod end
    end
    if LightCycleMod and LightCycleMod.IsActive and LightCycleMod.IsActive() then
        return LightCycleMod
    end
    return nil
end

--- Convert modifier array to flags
--- @param modifiers table Array of modifier names {"Alt", "Ctrl", "Shift"}
--- @return number Combined modifier flags
local function getModifierFlags(modifiers)
    local flags = 0
    if modifiers then
        for _, mod in ipairs(modifiers) do
            if MODIFIER_FLAGS[mod] then
                flags = flags | MODIFIER_FLAGS[mod]
            end
        end
    end
    return flags
end

--- Build key descriptor string for logging
--- @param keyConfig table Key configuration with Key and Modifiers
--- @return string Human-readable key combo
local function getKeyDescriptor(keyConfig)
    local parts = {}
    if keyConfig.Modifiers then
        for _, mod in ipairs(keyConfig.Modifiers) do
            table.insert(parts, mod)
        end
    end
    table.insert(parts, keyConfig.Key)
    return table.concat(parts, "+")
end

-- Per-bind refire guard: the 2026-08-24 UE4SS build delivers EXTRA fire
-- events per physical press (field: every Alt+J landed as ON then a
-- phantom OFF within a second, un-doing leak mode all day; the pinned
-- build fired once). Fires inside the window are dropped. Mode toggles
-- latch long, spawn/clone/delete one-shots latch mid, nudge keys stay
-- fast for sculpting; everything else gets the default.
local DEBOUNCE_DEFAULT_S = 0.25
local DEBOUNCE_S = {
    LeakTestToggle = 1.0, SlabTunerToggle = 1.0, CycleHeadlights = 1.0,
    PhotoDarkLook = 1.0, ToggleTimeSpeed = 1.0, ExposureDebugOverlay = 1.0,
    PrecipSuppressTest = 1.0,
    SlabSpawnHere = 0.4, SlabPadSpawn = 0.4, SlabPadJump = 0.4,
    SlabPadClone = 0.4, SlabPadRayClone = 0.4, SlabPadDelete = 0.4,
    SlabPadConfirm = 0.3, SlabPadSelectNearest = 0.2,
    SlabPadParamNext = 0.15, SlabPadParamPrev = 0.15,
    SlabPadInc = 0.12, SlabPadDec = 0.12,
    BrightnessUp = 0.12, BrightnessDown = 0.12,
    ShadowDistanceUp = 0.12, ShadowDistanceDown = 0.12,
    PhotoExposureUp = 0.12, PhotoExposureDown = 0.12,
    SkylightAlbedoUp = 0.12, SkylightAlbedoDown = 0.12,
    SkylightRoughUp = 0.12, SkylightRoughDown = 0.12,
    SkylightMultUp = 0.12, SkylightMultDown = 0.12,
    StarIntensityUp = 0.12, StarIntensityDown = 0.12,
}
local lastKeyFire = {}   -- bind name -> os.clock of the last accepted fire

--- Register a single keybind
--- @param name string Keybind name for logging
--- @param keyConfig table {Key = "S", Modifiers = {"Alt"}}
--- @param callback function Function to call when key pressed
--- @return boolean success
local function registerKeybind(name, keyConfig, callback)
    if not RegisterKeyBind then
        Log.Warn(MODULE, "RegisterKeyBind not available")
        return false
    end
    
    if not keyConfig or not keyConfig.Key then
        Log.Warn(MODULE, "Invalid key config", {name = name})
        return false
    end
    
    -- Get the key from UE4SS Key table
    local keyName = keyConfig.Key
    local key = nil
    
    -- Try direct key name first (e.g., Key.S)
    if Key then
        key = Key[keyName]
        -- Also try common mappings
        if not key and KEY_MAP[keyName] then
            key = Key[KEY_MAP[keyName]]
        end
    end
    
    if not key then
        Log.Warn(MODULE, "Unknown key", {name = name, key = keyName})
        return false
    end
    
    local descriptor = getKeyDescriptor(keyConfig)
    
    -- Build modifier table for UE4SS
    local modifierTable = {}
    if keyConfig.Modifiers and ModifierKey then
        for _, mod in ipairs(keyConfig.Modifiers) do
            local modKey = ModifierKey[mod:upper()]
            if modKey then
                table.insert(modifierTable, modKey)
            end
        end
    end
    
    -- One runner for every registration variant: refire guard first,
    -- then the pcall'd callback.
    local runner = function()
        local now = os.clock()
        local last = lastKeyFire[name]
        if last and (now - last) < (DEBOUNCE_S[name] or DEBOUNCE_DEFAULT_S) then
            Log.Debug(MODULE, "Key refire dropped", {bind = name})
            return
        end
        lastKeyFire[name] = now
        Log.Debug(MODULE, "Key pressed", {bind = name, key = descriptor})
        local ok, callErr = pcall(callback)
        if not ok then
            Log.Error(MODULE, "Keybind callback error", {bind = name, error = tostring(callErr)})
        end
    end
    local success, err = pcall(function()
        if #modifierTable > 0 then
            -- Register with modifier table (UE4SS v3.x style)
            RegisterKeyBind(key, modifierTable, runner)
        else
            -- Try with integer modifiers as fallback
            local modFlags = getModifierFlags(keyConfig.Modifiers)
            if modFlags > 0 then
                RegisterKeyBind(key, modFlags, runner)
            else
                -- Register without modifiers
                RegisterKeyBind(key, runner)
            end
        end
    end)
    
    if success then
        Log.Info(MODULE, "Registered keybind", {name = name, key = descriptor})
        registeredKeys[name] = descriptor
        return true
    else
        Log.Error(MODULE, "Failed to register keybind", {name = name, error = tostring(err)})
        return false
    end
end

-- ============== KEYBIND ACTIONS ==============

-- WEATHER-KEY DEBOUNCE (2026-08-12): spamming Alt+S crashed the session
-- (symbolized dump: get_userdata AV inside a UObject member call fired
-- from the apply path; a rapid re-apply races the previous apply's
-- teardown of the same objects, and pcall cannot catch the native
-- fault). One apply per 350 ms is imperceptible to a human press and
-- removes the overlap window entirely.
local WEATHER_KEY_DEBOUNCE_S = 0.35
local lastWeatherKeyAt = 0.0
local function weatherKeyDebounced()
    local now = os.clock()
    if (now - lastWeatherKeyAt) < WEATHER_KEY_DEBOUNCE_S then return true end
    lastWeatherKeyAt = now
    return false
end

local function onCycleWeatherNext()
    if weatherKeyDebounced() then return end
    local weather = getWeather()
    if not weather then
        Log.Warn(MODULE, "Weather module not available")
        return
    end

    local newPreset = weather.CycleNext()
    if newPreset then
        Log.Info(MODULE, "Weather cycled", {to = newPreset})
    end
end

local function onCycleWeatherPrev()
    if weatherKeyDebounced() then return end
    local weather = getWeather()
    if not weather then
        Log.Warn(MODULE, "Weather module not available")
        return
    end

    local newPreset = weather.CyclePrev()
    if newPreset then
        Log.Info(MODULE, "Weather cycled back", {to = newPreset})
    end
end

local function onResetWeather()
    if weatherKeyDebounced() then return end
    local weather = getWeather()
    if not weather then
        Log.Warn(MODULE, "Weather module not available")
        return
    end

    weather.ApplyDefault()
    Log.Info(MODULE, "Weather reset to default")
end

local function onRandomPreset()
    if weatherKeyDebounced() then return end
    local scheduler = getScheduler()
    if not scheduler then
        Log.Warn(MODULE, "Scheduler module not available")
        return
    end

    local newPreset = scheduler.PickNow()
    if newPreset then
        Log.Info(MODULE, "Random preset applied", {to = newPreset})
    end
end

local function onForceClear()
    local weather = getWeather()
    if not weather then
        Log.Warn(MODULE, "Weather module not available")
        return
    end

    weather.ForceClear()
    Log.Info(MODULE, "Weather force-cleared")
end

local function onToggleTimeSpeed()
    local tod = getTimeOfDay()
    if not tod then
        Log.Warn(MODULE, "TimeOfDay module not available")
        return
    end
    
    -- Use the CycleSpeed function which handles Normal -> Fast -> Pause -> Normal
    local newMode = tod.CycleSpeed()
    Log.Info(MODULE, "Time speed toggled", {mode = newMode})
end

local function onShadowDistanceUp()
    local shadows = getShadows()
    if not shadows then
        Log.Warn(MODULE, "Shadows module not available")
        return
    end

    -- Shadow system reverted to the original (no calibration nudge); both keys
    -- just force a re-apply of the FOV-based shadow distance, as before.
    shadows.Apply()
    Log.Info(MODULE, "Shadow distance re-applied")
end

local function onShadowDistanceDown()
    local shadows = getShadows()
    if not shadows then
        Log.Warn(MODULE, "Shadows module not available")
        return
    end

    -- See onShadowDistanceUp: nudge calibration no longer exists post-revert.
    shadows.Apply()
    Log.Info(MODULE, "Shadow distance re-applied")
end

local function onToggleHeadlights()
    local headlights = getHeadlights()
    if not headlights then
        Log.Warn(MODULE, "Headlights module not available")
        return
    end

    -- Garage-aware: in the garage this toggles the displayed car's lights (pops
    -- animate); on a course it is the normal manual on/off (no-op while config=auto).
    local where = headlights.OnManualToggleKey()
    Log.Info(MODULE, "Headlight manual toggled", {result = where})
end

local function onBrightnessUp()
    local headlights = getHeadlights()
    if not headlights then
        Log.Warn(MODULE, "Headlights module not available")
        return
    end
    
    local level, multiplier = headlights.CycleBrightnessUp()
    Log.Info(MODULE, "Brightness increased", {level = level, multiplier = multiplier})
end

local function onBrightnessDown()
    local headlights = getHeadlights()
    if not headlights then
        Log.Warn(MODULE, "Headlights module not available")
        return
    end

    local level, multiplier = headlights.CycleBrightnessDown()
    Log.Info(MODULE, "Brightness decreased", {level = level, multiplier = multiplier})
end

--- Photomode exposure trim (Alt+E brighter / Alt+Shift+E darker) and the
--- Alt+G dark-look toggle. Only live during a photo session; a press outside
--- one logs at Debug and does nothing (the provider returns nil).
local function onPhotoExposureUp()
    local lc = getExposure()
    if not lc or not lc.NudgePhotoExposure then return end
    if lc.NudgePhotoExposure(1) == nil then
        Log.Debug(MODULE, "Photo exposure nudge ignored (no photo session)")
    end
end

local function onPhotoExposureDown()
    local lc = getExposure()
    if not lc or not lc.NudgePhotoExposure then return end
    if lc.NudgePhotoExposure(-1) == nil then
        Log.Debug(MODULE, "Photo exposure nudge ignored (no photo session)")
    end
end

local function onPhotoDarkLook()
    local lc = getExposure()
    if not lc or not lc.TogglePhotoDarkLook then return end
    if lc.TogglePhotoDarkLook() == nil then
        Log.Debug(MODULE, "Photo dark look ignored (no photo session)")
    end
end

--- Exposure tuning feedback: flag the current picture as too dark / too bright.
--- Logs time + weather + the exposure values in effect (greppable tag "ExposureTune").
local function onExposureTooDark()
    local exposure = getExposure()
    if not exposure or not exposure.LogFeedback then
        Log.Warn(MODULE, "Exposure module not available")
        return
    end
    exposure.LogFeedback("dark")
end

local function onExposureTooBright()
    local exposure = getExposure()
    if not exposure or not exposure.LogFeedback then
        Log.Warn(MODULE, "Exposure module not available")
        return
    end
    exposure.LogFeedback("bright")
end

--- DEV: UDS exposure-bias liveness test (+2 EV on all five Exposure Bias
--- knobs, press again to restore). The handler name and ToggleHDRDebug are
--- historical; the keybind ships unbound (see Config.Keybinds).
local function onExposureDebugOverlay()
    local exposure = getExposure()
    if not exposure or not exposure.ToggleHDRDebug then
        Log.Warn(MODULE, "Exposure debug overlay not available (legacy module active?)")
        return
    end
    exposure.ToggleHDRDebug()
end

--- Manual test for the tunnel precip suppression mechanism (Alt+J): toggles
--- Weather.SetPrecipSuppressed. Use in rain: particles should vanish
--- immediately and return on the second press. The tunnel containment poll
--- (light_cycle) drives the same mechanism automatically.
local precipTestOn = false
local function onPrecipSuppressTest()
    local ok, Weather = pcall(require, "systems.weather")
    if not ok or not Weather or not Weather.SetPrecipSuppressed then
        Log.Warn(MODULE, "Weather module not available")
        return
    end
    precipTestOn = not precipTestOn
    Weather.SetPrecipSuppressed(precipTestOn)
end

--- Rain-spot datapoint (Alt+N): logs position, road-data tunnel bits, a
--- fresh roof-trace result, and the rain-kill state; the line also lands in
--- Logs/tuning_feedback.log (tag "RainSpot"). Press wherever rain presence
--- looks wrong.
local function onNoteRainSpot()
    local ok, Tunnels = pcall(require, "systems.tunnels")
    if not ok or not Tunnels or not Tunnels.NoteRainSpot then
        Log.Warn(MODULE, "Tunnels module not available")
        return
    end
    Tunnels.NoteRainSpot()
end

--- LEAK-HUNT MODE (Alt+J, 2026-08-12, the slab-calibration campaign):
--- one press = worst-case sun on demand. ON: remember the current
--- preset and pause state, hold the scheduler off (2h), Clear_Skies
--- fast-applied, TOD pinned at the config low-sun edge, clock frozen.
--- OFF: unfreeze (only if we froze it), release the scheduler, restore
--- the remembered preset. Workflow: Alt+J, drive the leaks, Alt+N at
--- both ends of every lit band, Alt+J off.
local leakTestOn = false
local leakSavedPreset = nil
local leakWasPaused = false
local function onLeakTestToggle()
    local weather = getWeather()
    local okT, TOD = pcall(require, "systems.time_of_day")
    local okS, Sched = pcall(require, "systems.scheduler")
    if not (weather and okT and TOD) then
        Log.Warn(MODULE, "Leak test: modules unavailable")
        return
    end
    if not leakTestOn then
        leakTestOn = true
        leakSavedPreset = nil
        pcall(function() leakSavedPreset = State.GetCurrentPreset() end)
        leakWasPaused = false
        pcall(function() leakWasPaused = TOD.IsPaused() end)
        if okS and Sched and Sched.HoldFor then
            pcall(function() Sched.HoldFor(7200) end)
        end
        -- Re-land the pinned calendar date before pinning the TOD: with
        -- Simulate Real Sun the sun position depends on the DATE, which
        -- drifts every in-game midnight mid-session (course entry resets
        -- it, long fast-clock sessions walk it forward again), so a
        -- calibrated leak TOD goes stale. RealSun's entry pass rewrites
        -- the config date + Hard Reset Cache (queued marshal: it lands
        -- right after the TOD write below and re-evaluates the sun).
        pcall(function()
            local okR, RS = pcall(require, "systems.real_sun")
            if okR and RS and RS.OnCourseLoad then RS.OnCourseLoad() end
        end)
        local t = (Config.LeakTest and tonumber(Config.LeakTest.Time)) or 1820
        pcall(function() weather.ApplyFast("Clear_Skies") end)
        pcall(function() TOD.SetTOD(t) end)
        if not leakWasPaused then pcall(function() TOD.Pause() end) end
        Log.Info(MODULE, "Leak test ON", {
            tod = t, saved = tostring(leakSavedPreset),
        })
    else
        leakTestOn = false
        if not leakWasPaused then pcall(function() TOD.Resume() end) end
        if okS and Sched and Sched.HoldFor then
            pcall(function() Sched.HoldFor(1) end)
        end
        if leakSavedPreset then
            pcall(function() weather.ApplyFast(leakSavedPreset) end)
        end
        Log.Info(MODULE, "Leak test OFF", {
            restored = tostring(leakSavedPreset),
        })
    end
end

--- SLAB TUNER (the Y-U-I-J cluster): live leak-fix authoring, see
--- systems/gap_walls.lua (extracted from tunnels 2026-08-12).
-- DEV-ONLY module: release builds omit systems/slab_editor.lua, so
-- this require fails, every editor handler no-ops, and none of the
-- editor keys register at all (the registrations below are gated on
-- the module loading).
local slabEditorMod = nil
local slabEditorTried = false
local function getSlabEditor()
    if not slabEditorTried then
        slabEditorTried = true
        local ok, mod = pcall(require, "systems.slab_editor")
        if ok then slabEditorMod = mod end
    end
    return slabEditorMod
end

local function onSlabTunerToggle()
    local E = getSlabEditor()
    if E and E.SlabTunerToggle then E.SlabTunerToggle() end
end

local function onSlabTunerParamNext()
    local E = getSlabEditor()
    if E and E.SlabTunerCycleParam then E.SlabTunerCycleParam(1) end
end

local function onSlabTunerParamPrev()
    local E = getSlabEditor()
    if E and E.SlabTunerCycleParam then E.SlabTunerCycleParam(-1) end
end

local function onSlabTunerInc()
    local E = getSlabEditor()
    if E and E.SlabTunerNudge then E.SlabTunerNudge(1) end
end

local function onSlabTunerDec()
    local E = getSlabEditor()
    if E and E.SlabTunerNudge then E.SlabTunerNudge(-1) end
end

local function onSlabSpawnHere()
    local E = getSlabEditor()
    if E and E.SlabSpawnHere then E.SlabSpawnHere() end
end

-- Numpad-grid handlers are TUNER-GATED (stray presses while driving
-- must never touch slabs; the grid only lives inside the editor).
local function tunerGated(fnName)
    return function()
        local E = getSlabEditor()
        if not (E and E.IsTunerOn and E.IsTunerOn()) then return end
        if E[fnName] then E[fnName]() end
    end
end

local onSlabDelete = tunerGated("SlabDeleteSelected")
local onSlabSelectNearest = tunerGated("SlabSelectNearest")
local onSlabClone = tunerGated("SlabCloneSelected")
local onSlabDeselect = tunerGated("SlabDeselect")
local onSlabSpawnJump = tunerGated("SlabSpawnJump")
local onSlabCloneTraced = tunerGated("SlabCloneTraced")

local function onSlabSpawnHereGated()
    local E = getSlabEditor()
    if not (E and E.IsTunerOn and E.IsTunerOn()) then return end
    if E.SlabSpawnHere then E.SlabSpawnHere() end
end

--- Skylight tuning session: Alt+Z/X/C nudge albedo/roughness/multiplier up,
--- Alt+Shift lowers; Alt+V logs the datapoint, Alt+Shift+V resets to the curve.
local function nudgeSkylight(which, dir)
    local exposure = getExposure()
    if not exposure or not exposure.NudgeSkylight then
        Log.Warn(MODULE, "Exposure module not available")
        return
    end
    exposure.NudgeSkylight(which, dir)
end

local function onSkylightAlbedoUp()   nudgeSkylight("leak",  1) end
local function onSkylightAlbedoDown() nudgeSkylight("leak", -1) end
local function onSkylightRoughUp()    nudgeSkylight("rough",  1) end
local function onSkylightRoughDown()  nudgeSkylight("rough", -1) end
local function onSkylightMultUp()     nudgeSkylight("sky",  1) end
local function onSkylightMultDown()   nudgeSkylight("sky", -1) end

local function onSkylightConfirm()
    local exposure = getExposure()
    if not exposure or not exposure.LogSkylightConfirm then
        Log.Warn(MODULE, "Exposure module not available")
        return
    end
    exposure.LogSkylightConfirm()
end

local function onSkylightReset()
    local exposure = getExposure()
    if not exposure or not exposure.ResetSkylightTune then
        Log.Warn(MODULE, "Exposure module not available")
        return
    end
    exposure.ResetSkylightTune()
end

--- Star visibility nudge (Alt+K family). The stars' rendered luminance
--- clamps below a lifted night sky (2026-07-18 field model), so star
--- visibility is dialed by moving the NIGHT SKY GLOW background:
--- Alt+K = glow DOWN (stars cut through more), Alt+Shift+K = glow UP.
local function nudgeStarIntensity(dir)
    local ok, Atmo = pcall(require, "systems.atmosphere")
    if not ok or not Atmo or not Atmo.NudgeNightGlow then
        Log.Warn(MODULE, "Atmosphere module not available")
        return
    end
    Atmo.NudgeNightGlow(dir)
end

local function onStarIntensityUp()   nudgeStarIntensity(-1) end  -- glow down = stars up
local function onStarIntensityDown() nudgeStarIntensity(1)  end  -- glow up = stars down

-- ============== PUBLIC API ==============

--- Initialize keybinds module
--- @param config table|nil Optional config override
--- @return boolean success
function Keybinds.Init(config)
    if isInitialized then
        Log.Warn(MODULE, "Already initialized")
        return true
    end
    
    config = config or Config.Keybinds
    
    if not config.Enabled then
        Log.Info(MODULE, "Keybinds disabled in config")
        return true
    end
    
    -- Check if UE4SS keybind API is available
    if not RegisterKeyBind then
        Log.Warn(MODULE, "RegisterKeyBind not available: keybinds disabled")
        return false
    end
    
    if not Key then
        Log.Warn(MODULE, "Key table not available: keybinds disabled")
        return false
    end
    
    Log.Info(MODULE, "Initializing keybinds")
    
    -- Register weather cycling
    if config.CycleWeatherNext then
        registerKeybind("CycleWeatherNext", config.CycleWeatherNext, onCycleWeatherNext)
    end
    
    if config.CycleWeatherPrev then
        registerKeybind("CycleWeatherPrev", config.CycleWeatherPrev, onCycleWeatherPrev)
    end
    
    -- Register weather reset
    if config.ResetWeather then
        registerKeybind("ResetWeather", config.ResetWeather, onResetWeather)
    end

    -- Register scheduler controls (Phase 11): Alt+P random preset, Alt+Shift+P force clear
    if config.RandomPreset then
        registerKeybind("RandomPreset", config.RandomPreset, onRandomPreset)
    end

    if config.ForceClear then
        registerKeybind("ForceClear", config.ForceClear, onForceClear)
    end
    
    -- Register time control
    if config.ToggleTimeSpeed then
        registerKeybind("ToggleTimeSpeed", config.ToggleTimeSpeed, onToggleTimeSpeed)
    end
    
    
    -- Register shadow distance calibration controls
    -- Alt+L raises the flat shadow distance, Alt+Shift+L lowers it (logs FOV+distance)
    if config.ShadowDistanceUp then
        registerKeybind("ShadowDistanceUp", config.ShadowDistanceUp, onShadowDistanceUp)
    end

    if config.ShadowDistanceDown then
        registerKeybind("ShadowDistanceDown", config.ShadowDistanceDown, onShadowDistanceDown)
    end
    
    -- Register headlight manual on/off toggle (auto mode is config-only)
    if config.CycleHeadlights then
        registerKeybind("CycleHeadlights", config.CycleHeadlights, onToggleHeadlights)
    end

    
    -- Register brightness controls
    Log.Debug(MODULE, "Checking brightness keybinds", {
        hasUp = config.BrightnessUp ~= nil,
        hasDown = config.BrightnessDown ~= nil
    })
    
    if config.BrightnessUp then
        local success = registerKeybind("BrightnessUp", config.BrightnessUp, onBrightnessUp)
        if not success then
            Log.Warn(MODULE, "Failed to register BrightnessUp keybind")
        end
    else
        Log.Debug(MODULE, "BrightnessUp not in config")
    end
    
    if config.BrightnessDown then
        local success = registerKeybind("BrightnessDown", config.BrightnessDown, onBrightnessDown)
        if not success then
            Log.Warn(MODULE, "Failed to register BrightnessDown keybind")
        end
    else
        Log.Debug(MODULE, "BrightnessDown not in config")
    end

    -- (The Alt+I sun-leak toggle handler is deleted 2026-08-04 along with
    -- RainCollision.ToggleShadowFix: the revert path keyed on an unstable
    -- component key and falsely exonerated the fix in an A/B.)

    -- Occlusion dig probe (Alt+O; see tunnels.OcclusionProbe)
    if config.OcclusionProbe then
        registerKeybind("OcclusionProbe", config.OcclusionProbe, function()
            local ok, Tunnels = pcall(require, "systems.tunnels")
            if not ok or not Tunnels or not Tunnels.OcclusionProbe then
                Log.Warn(MODULE, "Tunnels module not available")
                return
            end
            Tunnels.OcclusionProbe()
        end)
    end


    -- Photomode exposure trim + dark look (Alt+E / Alt+Shift+E / Alt+G)
    if config.PhotoExposureUp then
        registerKeybind("PhotoExposureUp", config.PhotoExposureUp, onPhotoExposureUp)
    end
    if config.PhotoExposureDown then
        registerKeybind("PhotoExposureDown", config.PhotoExposureDown, onPhotoExposureDown)
    end
    if config.PhotoDarkLook then
        registerKeybind("PhotoDarkLook", config.PhotoDarkLook, onPhotoDarkLook)
    end

    -- Exposure tuning feedback (Alt+D too dark, Alt+Shift+D too bright)
    if config.ExposureTooDark then
        registerKeybind("ExposureTooDark", config.ExposureTooDark, onExposureTooDark)
    end

    if config.ExposureTooBright then
        registerKeybind("ExposureTooBright", config.ExposureTooBright, onExposureTooBright)
    end

    if config.ExposureDebugOverlay then
        registerKeybind("ExposureDebugOverlay", config.ExposureDebugOverlay, onExposureDebugOverlay)
    end

    if config.PrecipSuppressTest then
        registerKeybind("PrecipSuppressTest", config.PrecipSuppressTest, onPrecipSuppressTest)
    end

    if config.NoteRainSpot then
        registerKeybind("NoteRainSpot", config.NoteRainSpot, onNoteRainSpot)
    end

    if config.LeakTestToggle then
        registerKeybind("LeakTestToggle", config.LeakTestToggle, onLeakTestToggle)
    end

    -- Slab editor (leak-fix authoring, DEV BUILDS ONLY): the whole
    -- set registers only if systems/slab_editor.lua exists, so a
    -- release build (file omitted) has no editor keys at all.
    if getSlabEditor() == nil then
        Log.Debug(MODULE, "Slab editor absent: editor keys not registered")
    else
        if config.SlabTunerToggle then
            registerKeybind("SlabTunerToggle", config.SlabTunerToggle, onSlabTunerToggle)
        end
        if config.SlabSpawnHere then
            registerKeybind("SlabSpawnHere", config.SlabSpawnHere, onSlabSpawnHere)
        end
        if config.SlabPadSpawn then
            registerKeybind("SlabPadSpawn", config.SlabPadSpawn, onSlabSpawnHereGated)
        end
        if config.SlabPadParamNext then
            registerKeybind("SlabPadParamNext", config.SlabPadParamNext, onSlabTunerParamNext)
        end
        if config.SlabPadParamPrev then
            registerKeybind("SlabPadParamPrev", config.SlabPadParamPrev, onSlabTunerParamPrev)
        end
        if config.SlabPadInc then
            registerKeybind("SlabPadInc", config.SlabPadInc, onSlabTunerInc)
        end
        if config.SlabPadDec then
            registerKeybind("SlabPadDec", config.SlabPadDec, onSlabTunerDec)
        end
        if config.SlabPadConfirm then
            registerKeybind("SlabPadConfirm", config.SlabPadConfirm, onSlabDeselect)
        end
        if config.SlabPadSelectNearest then
            registerKeybind("SlabPadSelectNearest", config.SlabPadSelectNearest, onSlabSelectNearest)
        end
        if config.SlabPadClone then
            registerKeybind("SlabPadClone", config.SlabPadClone, onSlabClone)
        end
        if config.SlabPadDelete then
            registerKeybind("SlabPadDelete", config.SlabPadDelete, onSlabDelete)
        end
        if config.SlabPadJump then
            registerKeybind("SlabPadJump", config.SlabPadJump, onSlabSpawnJump)
        end
        if config.SlabPadRayClone then
            registerKeybind("SlabPadRayClone", config.SlabPadRayClone, onSlabCloneTraced)
        end
    end

    -- Skylight tuning session (Alt+Z/X/C nudge, Alt+V confirm, Alt+Shift+V reset)
    if config.SkylightAlbedoUp then
        registerKeybind("SkylightAlbedoUp", config.SkylightAlbedoUp, onSkylightAlbedoUp)
    end
    if config.SkylightAlbedoDown then
        registerKeybind("SkylightAlbedoDown", config.SkylightAlbedoDown, onSkylightAlbedoDown)
    end
    if config.SkylightRoughUp then
        registerKeybind("SkylightRoughUp", config.SkylightRoughUp, onSkylightRoughUp)
    end
    if config.SkylightRoughDown then
        registerKeybind("SkylightRoughDown", config.SkylightRoughDown, onSkylightRoughDown)
    end
    if config.SkylightMultUp then
        registerKeybind("SkylightMultUp", config.SkylightMultUp, onSkylightMultUp)
    end
    if config.SkylightMultDown then
        registerKeybind("SkylightMultDown", config.SkylightMultDown, onSkylightMultDown)
    end
    if config.SkylightConfirm then
        registerKeybind("SkylightConfirm", config.SkylightConfirm, onSkylightConfirm)
    end
    if config.SkylightReset then
        registerKeybind("SkylightReset", config.SkylightReset, onSkylightReset)
    end
    if config.StarIntensityUp then
        registerKeybind("StarIntensityUp", config.StarIntensityUp, onStarIntensityUp)
    end
    if config.StarIntensityDown then
        registerKeybind("StarIntensityDown", config.StarIntensityDown, onStarIntensityDown)
    end

    isInitialized = true
    State.SetModuleStatus("keybinds", true)
    
    -- Count registered keys
    local count = 0
    for _, _ in pairs(registeredKeys) do
        count = count + 1
    end
    
    Log.Info(MODULE, "Keybinds initialized", {count = count})
    return true
end

--- Check if keybinds are initialized
--- @return boolean
function Keybinds.IsInitialized()
    return isInitialized
end

--- Get list of registered keybinds
--- @return table
function Keybinds.GetRegistered()
    return registeredKeys
end


return Keybinds
