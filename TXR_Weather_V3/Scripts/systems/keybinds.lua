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
local Wetness = nil
local Shadows = nil
local Headlights = nil
local Scheduler = nil
local Exposure = nil

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

local function getWetness()
    if not Wetness then
        local success, mod = pcall(require, "systems.wetness")
        if success then Wetness = mod end
    end
    return Wetness
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

-- Active exposure provider: the LightCycle module (sun-elevation system) when
-- it is enabled, else the legacy slot-table Exposure module. Both expose the
-- same feedback/tuning API (LogFeedback / NudgeSkylight / LogSkylightConfirm /
-- ResetSkylightTune), so the Alt+D family routes to whichever is live.
local LightCycleMod = nil
local function getExposure()
    if not LightCycleMod then
        local success, mod = pcall(require, "systems.light_cycle")
        if success then LightCycleMod = mod end
    end
    if LightCycleMod and LightCycleMod.IsActive and LightCycleMod.IsActive() then
        return LightCycleMod
    end
    if not Exposure then
        local success, mod = pcall(require, "systems.exposure")
        if success then Exposure = mod end
    end
    return Exposure
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
    
    local success, err = pcall(function()
        if #modifierTable > 0 then
            -- Register with modifier table (UE4SS v3.x style)
            RegisterKeyBind(key, modifierTable, function()
                Log.Debug(MODULE, "Key pressed", {bind = name, key = descriptor})
                local ok, callErr = pcall(callback)
                if not ok then
                    Log.Error(MODULE, "Keybind callback error", {bind = name, error = tostring(callErr)})
                end
            end)
        else
            -- Try with integer modifiers as fallback
            local modFlags = getModifierFlags(keyConfig.Modifiers)
            if modFlags > 0 then
                RegisterKeyBind(key, modFlags, function()
                    Log.Debug(MODULE, "Key pressed", {bind = name, key = descriptor})
                    local ok, callErr = pcall(callback)
                    if not ok then
                        Log.Error(MODULE, "Keybind callback error", {bind = name, error = tostring(callErr)})
                    end
                end)
            else
                -- Register without modifiers
                RegisterKeyBind(key, function()
                    Log.Debug(MODULE, "Key pressed", {bind = name, key = descriptor})
                    local ok, callErr = pcall(callback)
                    if not ok then
                        Log.Error(MODULE, "Keybind callback error", {bind = name, error = tostring(callErr)})
                    end
                end)
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

local function onCycleWeatherNext()
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
    local weather = getWeather()
    if not weather then
        Log.Warn(MODULE, "Weather module not available")
        return
    end
    
    weather.ApplyDefault()
    Log.Info(MODULE, "Weather reset to default")
end

local function onRandomPreset()
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

local function onForceWetness()
    local wetness = getWetness()
    if not wetness then
        Log.Warn(MODULE, "Wetness module not available")
        return
    end
    
    -- Force max wetness and puddles for visibility testing
    wetness.ForceWet()
    Log.Info(MODULE, "DEBUG: Forced max wetness/puddles")
end

local function onForceDry()
    local wetness = getWetness()
    if not wetness then
        Log.Warn(MODULE, "Wetness module not available")
        return
    end
    
    -- Force dry surfaces for testing
    wetness.ForceDry()
    Log.Info(MODULE, "DEBUG: Forced dry surfaces")
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

--- Toggle the engine's eye-adaptation debug overlay (live histogram + applied
--- EV + exposure compensation; shows any PP-volume bias actually in effect).
--- Silently does nothing if the shipping build stripped the visualizer.
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
--- immediately and return on the second press. The volume-containment signal
--- will drive this automatically once tunnel volumes are identified.
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

--- Skylight tuning session: Alt+Z/X/C nudge albedo/roughness/multiplier up,
--- Alt+Shift lowers; Alt+V logs the datapoint, Alt+Shift+V resets to slot curve.
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
        Log.Warn(MODULE, "RegisterKeyBind not available - keybinds disabled")
        return false
    end
    
    if not Key then
        Log.Warn(MODULE, "Key table not available - keybinds disabled")
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
    
    -- Register debug wetness (for testing puddles)
    if config.DebugForceWetness then
        registerKeybind("DebugForceWetness", config.DebugForceWetness, onForceWetness)
    end
    
    -- Register debug dry (for testing)
    if config.DebugForceDry then
        registerKeybind("DebugForceDry", config.DebugForceDry, onForceDry)
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

--- Manually trigger weather cycle (for testing)
function Keybinds.TriggerCycleNext()
    onCycleWeatherNext()
end

--- Manually trigger weather cycle back (for testing)
function Keybinds.TriggerCyclePrev()
    onCycleWeatherPrev()
end

--- Manually trigger weather reset (for testing)
function Keybinds.TriggerReset()
    onResetWeather()
end

return Keybinds
