-- TXR Weather Mod v3.0
-- systems/headlights.lua
-- Phase 10: Automatic headlight control based on time of day
-- Fixed: Uses UEHelpers pattern from V2 for vehicle discovery

local Headlights = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")
local Config = require("config")
local Utils = require("core.utils")

-- Lazy-load to avoid circular dependencies
local Actors = nil
local TimeOfDay = nil

local MODULE = "Headlights"

-- ============== CONFIGURATION ==============
-- Headlight mode: "auto" | "force_on" | "force_off"
local currentMode = "auto"

-- TOD thresholds for auto mode
local HEADLIGHT_ON_TOD = 1830   -- Turn on after 18:30 (dusk)
local HEADLIGHT_OFF_TOD = 630   -- Turn off after 06:30 (dawn)

-- ============== STATE ==============
local isInitialized = false
local headlightsOn = false
local lastTOD = nil
local modeChanged = false

-- Brightness control state
local BRIGHTNESS_MULTIPLIERS = {
    0.5,   -- Level 1: Dim
    1.0,   -- Level 2: Default game
    2.0,   -- Level 3: Bright
    3.0,   -- Level 4: Very Bright (default)
    5.0,   -- Level 5: Max
}
local currentBrightnessLevel = 4  -- Default to 3.0x
local pendingBrightnessApply = false
local brightnessRetryCount = 0
local MAX_BRIGHTNESS_RETRIES = 50  -- ~6 seconds at 125ms tick

-- Forward declaration for applyBrightness (defined later)
local applyBrightness

-- ============== INTERNAL FUNCTIONS ==============

local function getActors()
    if not Actors then
        local success, mod = pcall(require, "systems.actors")
        if success then Actors = mod end
    end
    return Actors
end

local function getTimeOfDay()
    if not TimeOfDay then
        local success, mod = pcall(require, "systems.time_of_day")
        if success then TimeOfDay = mod end
    end
    return TimeOfDay
end

--- Check if TOD is in night range (headlights should be on)
--- @param tod number
--- @return boolean
local function isNightTime(tod)
    -- Night wraps around midnight: on after HEADLIGHT_ON_TOD or before HEADLIGHT_OFF_TOD
    return tod >= HEADLIGHT_ON_TOD or tod < HEADLIGHT_OFF_TOD
end

--- Check if a UObject is valid (V2 pattern)
--- @param actor any
--- @return boolean
local function isValidActor(actor)
    if not actor then return false end
    if type(actor) ~= "table" and type(actor) ~= "userdata" then return false end
    local valid = false
    pcall(function()
        if actor.IsValid then
            valid = actor:IsValid()
        end
    end)
    return valid
end

--- Safely get a property from UObject (V2 pattern)
--- @param obj any
--- @param key string
--- @return any
local function safeGet(obj, key)
    if not obj then return nil end
    local ok, val = pcall(function() return obj[key] end)
    if ok then return val end
    return nil
end

--- Safely call a method on UObject (V2 pattern - correct self binding)
--- @param obj any
--- @param methodName string
--- @param ... any
--- @return boolean success
local function safeCallMethod(obj, methodName, ...)
    if not obj then return false end
    local args = {...}
    local ok = pcall(function()
        if obj[methodName] then 
            obj[methodName](obj, table.unpack(args)) 
        end
    end)
    return ok
end

--- Get PlayerController via UEHelpers (V2 pattern)
--- @return userdata|nil
local function getPlayerController()
    local UEH = nil
    pcall(function() UEH = require("UEHelpers") end)
    if not UEH or not UEH.GetPlayerController then return nil end
    local pc = nil
    pcall(function() pc = UEH:GetPlayerController() end)
    if isValidActor(pc) then return pc end
    return nil
end

--- Get PlayerPawn (vehicle) from PlayerController (V2 pattern)
--- @return userdata|nil
local function getPlayerPawn()
    local pc = getPlayerController()
    if not pc then return nil end
    local pawn = safeGet(pc, 'Pawn')
    if isValidActor(pawn) then return pawn end
    return nil
end

--- Set vehicle lights using V2's working method calls
--- @param obj userdata Vehicle/Pawn
--- @param on boolean
local function setVehicleLights(obj, on)
    if not isValidActor(obj) then return false end
    
    local want = on
    if Config.Headlights and Config.Headlights.Invert then
        want = not on
    end
    
    local success = false
    
    -- Method 1: V2-style method calls (SetLightOn etc.)
    success = safeCallMethod(obj, 'SetLightOn', want)
    if want then
        safeCallMethod(obj, 'SetLightSpriteScale', 0)
    end
    
    -- Tail/back lamps
    if want then
        safeCallMethod(obj, 'SetBackLampOn', true)
        safeCallMethod(obj, 'SetTailLampOn', true)
        safeCallMethod(obj, 'SetTailLightsOn', true)
        safeCallMethod(obj, 'SetRearLightsOn', true)
    else
        safeCallMethod(obj, 'SetBackLampOn', false)
        safeCallMethod(obj, 'SetBackLampOff')
        safeCallMethod(obj, 'SetTailLampOn', false)
        safeCallMethod(obj, 'SetTailLightsOn', false)
        safeCallMethod(obj, 'SetRearLightsOn', false)
    end
    
    -- Method 2: Direct BP_HeadLightComponent control (TXR-specific)
    local hlCount = 0
    pcall(function()
        local headlightComps = FindAllOf("BP_HeadLightComponent_C")
        if headlightComps then
            for _, comp in ipairs(headlightComps) do
                if comp and comp:IsValid() then
                    -- SetVisibility controls rendering
                    if comp.SetVisibility then
                        comp:SetVisibility(want, true)  -- propagate to children
                    end
                    -- Also try SetActive for component activation
                    if comp.SetActive then
                        comp:SetActive(want)
                    end
                    -- Direct intensity control as fallback
                    if want then
                        -- Use normal intensity (could expose hibeam later)
                        local intensity = safeGet(comp, 'Normal_intensity')
                        if intensity and intensity > 0 then
                            pcall(function() comp.Intensity = intensity end)
                        end
                    else
                        pcall(function() comp.Intensity = 0 end)
                    end
                    hlCount = hlCount + 1
                    success = true
                end
            end
        end
    end)
    if hlCount > 0 then
        Log.Debug(MODULE, "BP_HeadLightComponent controlled", {count = hlCount, on = want})
    end
    
    -- Method 3: Generic SpotLightComponent on vehicle
    local spotCount = 0
    pcall(function()
        local spotlights = FindAllOf("SpotLightComponent")
        if spotlights then
            for _, light in ipairs(spotlights) do
                if light and light:IsValid() then
                    local name = ""
                    pcall(function() name = light:GetFullName() or "" end)
                    -- Only affect headlight-named components
                    if name:lower():find("head") or name:lower():find("front") then
                        if light.SetVisibility then
                            light:SetVisibility(want, true)
                        end
                        spotCount = spotCount + 1
                        success = true
                    end
                end
            end
        end
    end)
    if spotCount > 0 then
        Log.Debug(MODULE, "SpotLightComponent controlled", {count = spotCount, on = want})
    end
    
    return success
end

-- ============== PUBLIC API ==============

--- Initialize headlights module
--- @return boolean success
function Headlights.Init()
    if isInitialized then
        Log.Warn(MODULE, "Already initialized")
        return true
    end
    
    Log.Info(MODULE, "Initializing headlights module")
    
    -- Read config
    if Config.Headlights then
        if Config.Headlights.Mode then
            currentMode = Config.Headlights.Mode
        end
        if Config.Headlights.OnTOD then
            HEADLIGHT_ON_TOD = Config.Headlights.OnTOD
        end
        if Config.Headlights.OffTOD then
            HEADLIGHT_OFF_TOD = Config.Headlights.OffTOD
        end
        if Config.Headlights.DefaultBrightnessLevel then
            local level = Config.Headlights.DefaultBrightnessLevel
            if level >= 1 and level <= #BRIGHTNESS_MULTIPLIERS then
                currentBrightnessLevel = level
            end
        end
        if Config.Headlights.Enabled == false then
            Log.Info(MODULE, "Headlights module disabled in config")
            isInitialized = true
            return true
        end
    end
    
    isInitialized = true
    State.SetModuleStatus("headlights", true)
    
    Log.Info(MODULE, "Headlights initialized", {mode = currentMode})
    return true
end

--- Main tick function
function Headlights.Tick()
    if not isInitialized then return end
    if Config.Headlights and Config.Headlights.Enabled == false then return end
    
    local actors = getActors()
    if not actors or not actors.IsOnCourse() then return end
    
    -- Don't run during PA
    if State.IsPAFrozen and State.IsPAFrozen() then return end
    
    -- Get player pawn (vehicle) - required for any light control
    local pawn = getPlayerPawn()
    if not pawn then return end  -- No vehicle, skip tick
    
    -- Force modes don't need time check
    if currentMode == "force_on" then
        if not headlightsOn or modeChanged then
            setVehicleLights(pawn, true)
            headlightsOn = true
            modeChanged = false
            pendingBrightnessApply = true
            brightnessRetryCount = 0
            Log.Debug(MODULE, "Force headlights ON")
        end
        return
    elseif currentMode == "force_off" then
        if headlightsOn or modeChanged then
            setVehicleLights(pawn, false)
            headlightsOn = false
            modeChanged = false
            Log.Debug(MODULE, "Force headlights OFF")
        end
        return
    end
    
    -- Auto mode: check time
    local tod = getTimeOfDay()
    if not tod then return end
    
    local currentTOD = tod.GetCurrentTOD()
    if not currentTOD then return end
    
    -- Only update on significant TOD change or mode change (avoid spam)
    if not modeChanged and lastTOD and math.abs(currentTOD - lastTOD) < 5 then
        return
    end
    lastTOD = currentTOD
    modeChanged = false
    
    local shouldBeOn = isNightTime(currentTOD)
    
    if shouldBeOn and not headlightsOn then
        setVehicleLights(pawn, true)
        headlightsOn = true
        pendingBrightnessApply = true
        brightnessRetryCount = 0
        Log.Info(MODULE, "Auto headlights ON", {tod = currentTOD})
    elseif not shouldBeOn and headlightsOn then
        setVehicleLights(pawn, false)
        headlightsOn = false
        pendingBrightnessApply = false
        Log.Info(MODULE, "Auto headlights OFF", {tod = currentTOD})
    end
    
    -- Retry pending brightness application
    if pendingBrightnessApply and headlightsOn then
        brightnessRetryCount = brightnessRetryCount + 1
        local multiplier = BRIGHTNESS_MULTIPLIERS[currentBrightnessLevel]
        local count = applyBrightness(multiplier)
        if count > 0 then
            pendingBrightnessApply = false
            Log.Info(MODULE, "Deferred brightness applied", {multiplier = multiplier, retries = brightnessRetryCount})
        elseif brightnessRetryCount >= MAX_BRIGHTNESS_RETRIES then
            pendingBrightnessApply = false
            Log.Warn(MODULE, "Brightness apply retries exhausted")
        end
    end
end

--- Cycle headlight mode: auto -> force_on -> force_off -> auto
--- @return string newMode
function Headlights.CycleMode()
    if currentMode == "auto" then
        currentMode = "force_on"
    elseif currentMode == "force_on" then
        currentMode = "force_off"
    else
        currentMode = "auto"
    end
    
    -- Flag for update on next tick
    modeChanged = true
    
    Log.Info(MODULE, "Headlight mode cycled", {mode = currentMode})
    return currentMode
end

--- Set headlight mode directly
--- @param mode string "auto" | "force_on" | "force_off"
function Headlights.SetMode(mode)
    if mode == "auto" or mode == "force_on" or mode == "force_off" then
        currentMode = mode
        modeChanged = true
        Log.Info(MODULE, "Headlight mode set", {mode = currentMode})
    end
end

--- Get current mode
--- @return string
function Headlights.GetMode()
    return currentMode
end

--- Check if headlights are currently on
--- @return boolean
function Headlights.AreHeadlightsOn()
    return headlightsOn
end

--- Get status for debugging
--- @return table
function Headlights.GetStatus()
    return {
        initialized = isInitialized,
        mode = currentMode,
        headlightsOn = headlightsOn,
        lastTOD = lastTOD,
        onThreshold = HEADLIGHT_ON_TOD,
        offThreshold = HEADLIGHT_OFF_TOD,
        brightnessLevel = currentBrightnessLevel,
        brightnessMultiplier = BRIGHTNESS_MULTIPLIERS[currentBrightnessLevel],
    }
end

-- ============== BRIGHTNESS CONTROL ==============
-- Uses BP_CarLightSpriteComponent_C:SetIntensity for visual brightness

--- Apply brightness multiplier to all car light sprite components
--- @param multiplier number
--- @return number count of modified lights
applyBrightness = function(multiplier)
    local count = 0
    
    -- Try BP_CarLightSpriteComponent_C first (controls visual glow/bloom)
    pcall(function()
        local sprites = FindAllOf("BP_CarLightSpriteComponent_C")
        if sprites then
            for _, sprite in ipairs(sprites) do
                if sprite and sprite:IsValid() and sprite.SetIntensity then
                    local success = pcall(function()
                        sprite:SetIntensity(multiplier)
                    end)
                    if success then
                        count = count + 1
                    end
                end
            end
        end
    end)
    
    -- Also try BP_HeadLightComponent_C 
    pcall(function()
        local components = FindAllOf("BP_HeadLightComponent_C")
        if components then
            for _, light in ipairs(components) do
                if light and light:IsValid() then
                    pcall(function()
                        local baseNormal = light["Normal_intensity"] or 1000
                        local newIntensity = baseNormal * multiplier
                        light.Intensity = newIntensity
                        if light.SetIntensity then
                            light:SetIntensity(newIntensity)
                        end
                    end)
                end
            end
        end
    end)
    
    -- Toggle headlights off then on to force refresh
    if count > 0 then
        -- Quick toggle via BP_HeadLightComponent visibility
        pcall(function()
            local headlightComps = FindAllOf("BP_HeadLightComponent_C")
            if headlightComps then
                for _, comp in ipairs(headlightComps) do
                    if comp and comp:IsValid() and comp.SetVisibility then
                        comp:SetVisibility(false, true)
                    end
                end
                for _, comp in ipairs(headlightComps) do
                    if comp and comp:IsValid() and comp.SetVisibility then
                        comp:SetVisibility(true, true)
                    end
                end
            end
        end)
    end
    
    return count
end

--- Cycle brightness level up
--- @return number newLevel, number multiplier
function Headlights.CycleBrightnessUp()
    currentBrightnessLevel = currentBrightnessLevel + 1
    if currentBrightnessLevel > #BRIGHTNESS_MULTIPLIERS then
        currentBrightnessLevel = 1
    end
    
    local multiplier = BRIGHTNESS_MULTIPLIERS[currentBrightnessLevel]
    applyBrightness(multiplier)
    
    Log.Info(MODULE, "Brightness level up", {
        level = currentBrightnessLevel,
        multiplier = multiplier
    })
    
    return currentBrightnessLevel, multiplier
end

--- Cycle brightness level down
--- @return number newLevel, number multiplier
function Headlights.CycleBrightnessDown()
    currentBrightnessLevel = currentBrightnessLevel - 1
    if currentBrightnessLevel < 1 then
        currentBrightnessLevel = #BRIGHTNESS_MULTIPLIERS
    end
    
    local multiplier = BRIGHTNESS_MULTIPLIERS[currentBrightnessLevel]
    applyBrightness(multiplier)
    
    Log.Info(MODULE, "Brightness level down", {
        level = currentBrightnessLevel,
        multiplier = multiplier
    })
    
    return currentBrightnessLevel, multiplier
end

return Headlights
