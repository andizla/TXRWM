-- TXR Weather Mod v3.0
-- systems/weather.lua
-- Weather control using UDW's Change Weather API
-- THIS IS THE CRITICAL MODULE - Uses the proper UDW API instead of property manipulation

local Weather = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local Utils = require("core.utils")
local State = require("core.state")
local Config = require("config")
local Actors = require("systems.actors")
local Presets = require("systems.presets")

local MODULE = "Weather"

-- ============== STATE ==============
local assetCache = {}  -- Cache loaded weather preset assets
local lastApplyTime = 0
local applyCount = 0
local enabled = true   -- master switch (Config.Weather.Enabled); false = ToD/visuals only, no weather

-- Pending rain activation for retry after map load
local pendingRainActivation = false
local pendingRainRetryCount = 0
local MAX_RAIN_RETRIES = 50  -- ~6 seconds at 125ms tick interval

-- ============== INTERNAL FUNCTIONS ==============

--- Load a weather preset asset using StaticFindObject
--- @param presetName string Preset name
--- @return userdata|nil Asset reference or nil
local function loadPresetAsset(presetName)
    -- Check cache first
    if assetCache[presetName] then
        Log.Debug(MODULE, "Using cached preset asset", {preset = presetName})
        return assetCache[presetName]
    end
    
    -- Get asset path
    local assetPath = Presets.GetAssetPath(presetName)
    if not assetPath then
        Log.Error(MODULE, "No asset path for preset", {preset = presetName})
        return nil
    end
    
    -- Check if StaticFindObject is available
    if not StaticFindObject then
        Log.Error(MODULE, "StaticFindObject not available - not running in UE4SS?")
        return nil
    end
    
    -- Load the asset
    Log.Debug(MODULE, "Loading preset asset", {preset = presetName, path = assetPath})
    
    local success, asset = pcall(function()
        return StaticFindObject(assetPath)
    end)
    
    if not success then
        Log.Error(MODULE, "StaticFindObject failed", {preset = presetName, error = tostring(asset)})
        return nil
    end
    
    if not asset then
        Log.Error(MODULE, "Preset asset not found", {preset = presetName, path = assetPath})
        return nil
    end
    
    -- Validate the asset
    if not Utils.IsValidObject(asset) then
        Log.Error(MODULE, "Preset asset not valid", {preset = presetName})
        return nil
    end
    
    -- Cache it
    assetCache[presetName] = asset
    Log.Info(MODULE, "Loaded preset asset", {
        preset = presetName,
        address = Utils.FormatAddress(asset)
    })
    
    return asset
end

--- Call UDW's Change Weather function
--- @param presetAsset userdata The loaded preset asset
--- @param transitionTime number Transition time in seconds
--- @return boolean success
local function callChangeWeather(presetAsset, transitionTime)
    local udw = Actors.GetUDW()
    if not udw then
        Log.Error(MODULE, "No UDW actor available")
        return false
    end
    
    -- Try to get the Change Weather function
    -- In UE4SS, function names with spaces are accessed via bracket notation
    local changeWeatherFn = nil
    local fnFound = false
    
    -- Method 1: Try via Actors helper
    changeWeatherFn, fnFound = Actors.GetUDWFunction("Change Weather")
    
    if not fnFound then
        -- Method 2: Try direct access
        Log.Debug(MODULE, "Trying direct UDW function access")
        local success, result = pcall(function()
            return udw["Change Weather"]
        end)
        if success and result ~= nil then
            changeWeatherFn = result
            fnFound = true
            Log.Debug(MODULE, "Got function via direct access", {type = type(result)})
        end
    end
    
    if not fnFound or not changeWeatherFn then
        -- Debug: List what's available on UDW
        Log.Error(MODULE, "Change Weather function not found on UDW")
        Log.Debug(MODULE, "UDW type: " .. type(udw))
        
        -- Try to enumerate some known functions to verify UDW is working
        local testFns = {"Change Weather", "ChangeWeather", "Change_Weather"}
        for _, name in ipairs(testFns) do
            local ok, val = pcall(function() return udw[name] end)
            if ok then
                Log.Debug(MODULE, "UDW['" .. name .. "'] = " .. type(val) .. " (" .. tostring(val) .. ")")
            end
        end
        
        return false
    end
    
    -- Call the function with parameters:
    -- UE4SS requires self (UDW) as first param for UFunction calls
    -- Param 1: self (UDW actor)
    -- Param 2: New Weather Type (UDS_Weather_Settings object) @ offset 0x0
    -- Param 3: Time To Transition (Double, seconds) @ offset 0x8
    Log.Debug(MODULE, "Calling Change Weather", {
        asset = Utils.FormatAddress(presetAsset),
        transition = transitionTime,
        fnType = type(changeWeatherFn)
    })
    
    local success, err = pcall(function()
        -- Pass UDW as first argument (self)
        changeWeatherFn(udw, presetAsset, transitionTime)
    end)
    
    if not success then
        Log.Error(MODULE, "Change Weather call failed", {error = tostring(err)})
        return false
    end
    
    Log.Info(MODULE, "Change Weather call succeeded")
    return true
end

--- Set Niagara parameter on a particle component
--- @param componentName string Name of the component property on UDW (e.g., "Rain Particles")
--- @param paramName string Name of the Niagara parameter (e.g., "User.Spawn Rate")
--- @param value number The value to set
--- @return boolean success
local function setNiagaraParameter(componentName, paramName, value)
    local udw = Actors.GetUDW()
    if not udw then
        Log.Warn(MODULE, "No UDW for Niagara parameter")
        return false
    end
    
    -- Get the component
    local component = nil
    local success, result = pcall(function()
        return udw[componentName]
    end)
    
    if not success or result == nil then
        Log.Warn(MODULE, "Component not found", {component = componentName})
        return false
    end
    component = result
    
    -- Get SetFloatParameter function
    local setFloatParam = nil
    success, result = pcall(function()
        return component["SetFloatParameter"]
    end)
    
    if not success or result == nil then
        Log.Warn(MODULE, "SetFloatParameter not found on component")
        return false
    end
    setFloatParam = result
    
    -- Call SetFloatParameter(self, ParameterName, Value)
    local callSuccess, err = pcall(function()
        setFloatParam(component, paramName, value)
    end)
    
    if callSuccess then
        Log.Debug(MODULE, "Set Niagara parameter", {
            component = componentName,
            param = paramName,
            value = value
        })
        return true
    else
        Log.Warn(MODULE, "SetFloatParameter call failed", {error = tostring(err)})
        return false
    end
end

--- Activate or deactivate a Niagara component
--- @param componentName string Name of the component property on UDW
--- @param active boolean Whether to activate
--- @return boolean success
local function setNiagaraActive(componentName, active)
    local udw = Actors.GetUDW()
    if not udw then
        return false
    end
    
    local component = nil
    local success, result = pcall(function()
        return udw[componentName]
    end)
    
    if not success or result == nil then
        return false
    end
    component = result
    
    -- Try Activate/Deactivate functions
    local fnName = active and "Activate" or "Deactivate"
    local fn = nil
    success, result = pcall(function()
        return component[fnName]
    end)
    
    if success and result ~= nil then
        fn = result
        local callSuccess, err = pcall(function()
            if active then
                fn(component, true)  -- Activate(bReset)
            else
                fn(component)  -- Deactivate()
            end
        end)
        if callSuccess then
            Log.Debug(MODULE, "Niagara component " .. fnName, {component = componentName})
            return true
        end
    end
    
    return false
end

-- ============== PUBLIC API ==============

--- Initialize weather module
function Weather.Init()
    if Config.Weather and Config.Weather.Enabled ~= nil then enabled = Config.Weather.Enabled end
    Log.Info(MODULE, "Initializing weather module", {enabled = enabled})
    assetCache = {}
    lastApplyTime = 0
    applyCount = 0
    State.SetModuleStatus("weather", true)
    return true
end

--- Apply a weather preset
--- @param presetName string Preset name (e.g., "Clear_Skies", "Rain")
--- @param transitionTime number|nil Transition time in seconds (default from config)
--- @return boolean success
function Weather.Apply(presetName, transitionTime)
    -- Master switch: when disabled, the mod applies no weather (ToD/visuals only).
    -- Covers default-on-load, cycling, and reset since they all route through here.
    if not enabled then
        Log.Debug(MODULE, "Weather disabled - skipping apply", {preset = presetName})
        return false
    end

    -- Validate preset exists
    if not Presets.Exists(presetName) then
        Log.Error(MODULE, "Unknown preset", {preset = presetName})
        return false
    end
    
    -- Check if we have actors
    if not Actors.IsOnCourse() then
        Log.Warn(MODULE, "Cannot apply weather - not on course")
        return false
    end
    
    -- Default transition time
    transitionTime = transitionTime or Config.Weather.DefaultTransitionTime or 5.0
    
    -- Load the preset asset
    local asset = loadPresetAsset(presetName)
    if not asset then
        return false
    end
    
    -- Log the weather change
    local currentPreset = State.GetCurrentPreset()
    Log.Info(MODULE, "Applying weather", {
        from = currentPreset or "none",
        to = presetName,
        transition = transitionTime
    })
    
    -- Call Change Weather
    local success = callChangeWeather(asset, transitionTime)
    
    if success then
        -- Update state
        State.StartWeatherTransition(presetName, transitionTime)
        lastApplyTime = os.time()
        applyCount = applyCount + 1
        
        -- Enable/disable particle systems based on preset
        local presetData = Presets.Get(presetName)
        if presetData then
            -- Apply cloud/fog values via CloudsFog module
            local CloudsFog = nil
            pcall(function()
                CloudsFog = require("systems.clouds_fog")
            end)
            if CloudsFog and CloudsFog.ApplyPreset then
                local immediate = transitionTime and transitionTime < 1.0
                CloudsFog.ApplyPreset(presetData.cloudCoverage, presetData.fog, immediate)
            end
            
            -- Apply enhanced fog settings via EnhancedFog module (Phase 7)
            local EnhancedFog = nil
            pcall(function()
                EnhancedFog = require("systems.enhanced_fog")
            end)
            if EnhancedFog and EnhancedFog.ApplyFromPreset then
                EnhancedFog.ApplyFromPreset(presetData)
            end
            
            -- Apply lightning settings via Lightning module (Phase 7)
            local Lightning = nil
            pcall(function()
                Lightning = require("systems.lightning")
            end)
            if Lightning and Lightning.EnableFromPreset then
                Lightning.EnableFromPreset(presetData)
            end
            
            -- Apply wetness settings via Wetness module (Phase 6)
            local Wetness = nil
            pcall(function()
                Wetness = require("systems.wetness")
            end)
            if Wetness and Wetness.ApplyFromPreset then
                Wetness.ApplyFromPreset(presetData)
            end
            
            -- Log particle expectations (Change Weather should handle this internally)
            Log.Debug(MODULE, "Particle expectations", {
                hasRain = presetData.hasRain,
                hasSnow = presetData.hasSnow,
                hasDust = presetData.hasDust
            })
            
            -- Force particle values as backup (UDW may need explicit values)
            if presetData.hasRain then
                -- Set Manual Override to allow our values to take effect (from v2)
                Actors.SetUDWProperty("Rain - Manual Override", true)
                Actors.SetUDWProperty("Thunder/Lightning - Manual Override", true)
                
                -- CRITICAL: Ensure particle warmup is enabled
                Actors.SetUDWProperty("Warm Up Weather Particles On Begin Play", true)
                
                local udw = Actors.GetUDW()
                if udw then
                    -- Call Weather Startup Functions first (from v2 UDW.Warmup)
                    local weatherStartup = nil
                    pcall(function()
                        weatherStartup = udw["Weather Startup Functions"]
                    end)
                    if weatherStartup then
                        pcall(function()
                            weatherStartup(udw)
                        end)
                        Log.Debug(MODULE, "Weather Startup Functions called")
                    end
                    
                    -- Call Warm Up Niagara Systems to initialize particle systems
                    local warmupNiagara = nil
                    pcall(function()
                        warmupNiagara = udw["Warm Up Niagara Systems"]
                    end)
                    if warmupNiagara then
                        pcall(function()
                            warmupNiagara(udw)
                        end)
                        Log.Debug(MODULE, "Warm Up Niagara Systems called")
                    end
                    
                    -- Call Make Rain Component to create the Niagara component (from v2)
                    local makeRainComp = nil
                    pcall(function()
                        makeRainComp = udw["Make Rain Component"]
                    end)
                    if makeRainComp then
                        local callSuccess, err = pcall(function()
                            makeRainComp(udw)
                        end)
                        if callSuccess then
                            Log.Debug(MODULE, "Make Rain Component called successfully")
                        else
                            Log.Warn(MODULE, "Make Rain Component failed", {error = tostring(err)})
                        end
                    end
                end
                
                -- Set all rain-related properties using preset values
                local rainIntensity = presetData.rainIntensity or 7.0
                local thunderIntensity = presetData.thunderIntensity or 4.0
                local spawnCount = presetData.spawnCount or 20000.0
                
                Actors.SetUDWProperty("Rain", rainIntensity)
                Actors.SetUDWProperty("Thunder/Lightning", thunderIntensity)
                Actors.SetUDWProperty("Enable Rain Particles", true)
                Actors.SetUDWProperty("Rain Particle Spawn Count", spawnCount)
                Actors.SetUDWProperty("Max Spawn Distance", 2000.0)
                
                Log.Debug(MODULE, "Rain particle settings", {
                    rainIntensity = rainIntensity,
                    thunderIntensity = thunderIntensity,
                    spawnCount = spawnCount
                })
                
                -- Call Static Properties - Rain to initialize particle system
                if udw then
                    local staticPropsRain = nil
                    pcall(function()
                        staticPropsRain = udw["Static Properties - Rain"]
                    end)
                    if staticPropsRain then
                        local callSuccess, err = pcall(function()
                            staticPropsRain(udw)
                        end)
                        if callSuccess then
                            Log.Debug(MODULE, "Static Properties - Rain called successfully")
                        else
                            Log.Warn(MODULE, "Static Properties - Rain failed", {error = tostring(err)})
                        end
                    end
                    
                    -- Call Update Active Rain Parameters to activate particles (from v2)
                    local updateRainParams = nil
                    pcall(function()
                        updateRainParams = udw["Update Active Rain Parameters"]
                    end)
                    if updateRainParams then
                        pcall(function()
                            updateRainParams()  -- Takes 0 params, reads from properties (v2 style)
                        end)
                        Log.Debug(MODULE, "Update Active Rain Parameters called (enable)")
                    end
                end
                
                -- DIRECT NIAGARA CONTROL: Ensure rain particle components are active
                local activatedCount = 0
                pcall(function()
                    local niagaraComponents = FindAllOf("NiagaraComponent")
                    if niagaraComponents then
                        for idx, comp in ipairs(niagaraComponents) do
                            if comp and comp:IsValid() then
                                local isRainComponent = false
                                local compName = ""
                                local fullName = ""
                                
                                pcall(function()
                                    local nameObj = comp:GetFName()
                                    if nameObj then compName = nameObj:ToString() end
                                end)
                                pcall(function()
                                    fullName = comp:GetFullName()
                                end)
                                
                                if (compName and compName:find("Rain")) or (fullName and fullName:find("Rain")) then
                                    isRainComponent = true
                                end
                                
                                if not isRainComponent then
                                    pcall(function()
                                        local asset = comp.Asset
                                        if asset and asset:IsValid() then
                                            local assetFullName = asset:GetFullName()
                                            if assetFullName and assetFullName:find("Rain") then
                                                isRainComponent = true
                                            end
                                        end
                                    end)
                                end
                                
                                if isRainComponent then
                                    -- Ensure not paused
                                    pcall(function()
                                        comp:SetPaused(false)
                                    end)
                                    -- Try to activate with reset
                                    pcall(function()
                                        comp:Activate(true)  -- bReset = true
                                        activatedCount = activatedCount + 1
                                    end)
                                end
                            end
                        end
                    end
                end)
                Log.Debug(MODULE, "Direct Niagara activation", {activatedCount = activatedCount})
                
                -- If activation failed, set pending flag for retry in tick loop
                if activatedCount == 0 then
                    pendingRainActivation = true
                    pendingRainRetryCount = 0
                    Log.Debug(MODULE, "Rain activation pending - will retry in tick loop")
                else
                    pendingRainActivation = false
                end
                
                -- Set Refresh Settings to trigger update
                Actors.SetUDWProperty("Refresh Settings", true)
                
                Log.Debug(MODULE, "Forced Rain particles on")
            else
                -- DISABLE RAIN: Set properties for UDW state consistency
                Actors.SetUDWProperty("Rain - Manual Override", true)
                Actors.SetUDWProperty("Thunder/Lightning - Manual Override", true)
                Actors.SetUDWProperty("Rain", 0.0)
                Actors.SetUDWProperty("Thunder/Lightning", 0.0)
                Actors.SetUDWProperty("Enable Rain Particles", false)
                Actors.SetUDWProperty("Rain Particle Spawn Count", 0.0)
                
                -- DIRECT NIAGARA CONTROL: Find and deactivate rain particle components
                -- This bypasses UDW's property system which isn't stopping particles
                local deactivatedCount = 0
                pcall(function()
                    local niagaraComponents = FindAllOf("NiagaraComponent")
                    if niagaraComponents then
                        Log.Debug(MODULE, "Found Niagara components", {count = #niagaraComponents})
                        for idx, comp in ipairs(niagaraComponents) do
                            if comp and comp:IsValid() then
                                -- Check if this is a rain-related component
                                local isRainComponent = false
                                local compName = ""
                                local fullName = ""
                                
                                -- Get FName (short name)
                                pcall(function()
                                    local nameObj = comp:GetFName()
                                    if nameObj then
                                        compName = nameObj:ToString()
                                    end
                                end)
                                
                                -- Get full name (includes path/asset info)
                                pcall(function()
                                    fullName = comp:GetFullName()
                                end)
                                
                                -- Check if either name contains "Rain"
                                if (compName and compName:find("Rain")) or (fullName and fullName:find("Rain")) then
                                    isRainComponent = true
                                    Log.Debug(MODULE, "Found Rain Niagara component", {
                                        fname = compName,
                                        fullName = fullName:sub(1, 150),
                                        index = idx
                                    })
                                end
                                
                                -- Also check the Asset property
                                if not isRainComponent then
                                    pcall(function()
                                        local asset = comp.Asset
                                        if asset and asset:IsValid() then
                                            local assetFullName = asset:GetFullName()
                                            if assetFullName and assetFullName:find("Rain") then
                                                isRainComponent = true
                                                Log.Debug(MODULE, "Found Rain component by asset", {
                                                    asset = assetFullName:sub(1, 150),
                                                    index = idx
                                                })
                                            end
                                        end
                                    end)
                                end
                                
                                if isRainComponent then
                                    -- Try DeactivateImmediate first (stops spawning immediately)
                                    local deactivated = false
                                    pcall(function()
                                        comp:DeactivateImmediate()
                                        deactivated = true
                                        Log.Debug(MODULE, "DeactivateImmediate succeeded", {index = idx})
                                    end)
                                    
                                    if not deactivated then
                                        -- Try Deactivate (lets existing particles finish)
                                        pcall(function()
                                            comp:Deactivate()
                                            deactivated = true
                                            Log.Debug(MODULE, "Deactivate succeeded", {index = idx})
                                        end)
                                    end
                                    
                                    if not deactivated then
                                        -- Try SetPaused as fallback
                                        pcall(function()
                                            comp:SetPaused(true)
                                            deactivated = true
                                            Log.Debug(MODULE, "SetPaused succeeded", {index = idx})
                                        end)
                                    end
                                    
                                    if deactivated then
                                        deactivatedCount = deactivatedCount + 1
                                    end
                                end
                            end
                        end
                    else
                        Log.Debug(MODULE, "No NiagaraComponent instances found")
                    end
                end)
                Log.Debug(MODULE, "Direct Niagara deactivation complete", {deactivatedCount = deactivatedCount})
            end
            
            if presetData.hasSnow then
                Actors.SetUDWProperty("Snow - Manual Override", true)
                
                -- Call Make Snow Component
                local udw = Actors.GetUDW()
                if udw then
                    local makeSnowComp = nil
                    pcall(function()
                        makeSnowComp = udw["Make Snow Component"]
                    end)
                    if makeSnowComp then
                        pcall(function()
                            makeSnowComp(udw)
                        end)
                        Log.Debug(MODULE, "Make Snow Component called")
                    end
                end
                
                -- Use preset values
                local snowIntensity = presetData.snowIntensity or 7.0
                local spawnCount = presetData.spawnCount or 20000.0
                
                Actors.SetUDWProperty("Snow", snowIntensity)
                Actors.SetUDWProperty("Enable Snow Particles", true)
                Actors.SetUDWProperty("Snow Particle Spawn Count", spawnCount)
                
                -- Call Static Properties - Snow
                if udw then
                    local staticPropsSnow = nil
                    pcall(function()
                        staticPropsSnow = udw["Static Properties - Snow"]
                    end)
                    if staticPropsSnow then
                        pcall(function()
                            staticPropsSnow(udw)
                        end)
                        Log.Debug(MODULE, "Static Properties - Snow called")
                    end
                end
                
                Actors.SetUDWProperty("Refresh Settings", true)
                Log.Debug(MODULE, "Forced Snow particles on", {snowIntensity = snowIntensity})
            else
                -- DISABLE SNOW: Set properties for UDW state consistency
                Actors.SetUDWProperty("Snow - Manual Override", true)
                Actors.SetUDWProperty("Snow", 0.0)
                Actors.SetUDWProperty("Enable Snow Particles", false)
                Actors.SetUDWProperty("Snow Particle Spawn Count", 0.0)
                
                -- DIRECT NIAGARA CONTROL: Find and deactivate snow particle components
                local deactivatedCount = 0
                pcall(function()
                    local niagaraComponents = FindAllOf("NiagaraComponent")
                    if niagaraComponents then
                        for idx, comp in ipairs(niagaraComponents) do
                            if comp and comp:IsValid() then
                                local isSnowComponent = false
                                local fullName = ""
                                pcall(function() fullName = comp:GetFullName() end)
                                
                                if fullName and fullName:find("Snow") then
                                    isSnowComponent = true
                                end
                                
                                if not isSnowComponent then
                                    pcall(function()
                                        local asset = comp.Asset
                                        if asset and asset:IsValid() then
                                            local assetFullName = asset:GetFullName()
                                            if assetFullName and assetFullName:find("Snow") then
                                                isSnowComponent = true
                                            end
                                        end
                                    end)
                                end
                                
                                if isSnowComponent then
                                    pcall(function() comp:DeactivateImmediate() end)
                                    deactivatedCount = deactivatedCount + 1
                                end
                            end
                        end
                    end
                end)
                Log.Debug(MODULE, "Direct Snow Niagara deactivation", {deactivatedCount = deactivatedCount})
            end
            
            if presetData.hasDust then
                Actors.SetUDWProperty("Dust - Manual Override", true)
                
                -- Call Make Dust Component
                local udw = Actors.GetUDW()
                if udw then
                    local makeDustComp = nil
                    pcall(function()
                        makeDustComp = udw["Make Dust Component"]
                    end)
                    if makeDustComp then
                        pcall(function()
                            makeDustComp(udw)
                        end)
                        Log.Debug(MODULE, "Make Dust Component called")
                    end
                end
                
                -- Use preset values
                local dustIntensity = presetData.dustIntensity or 7.0
                local spawnCount = presetData.spawnCount or 20000.0
                
                Actors.SetUDWProperty("Dust", dustIntensity)
                Actors.SetUDWProperty("Enable Dust Particles", true)
                Actors.SetUDWProperty("Dust Particle Spawn Count", spawnCount)
                
                -- Call Static Properties - Dust
                if udw then
                    local staticPropsDust = nil
                    pcall(function()
                        staticPropsDust = udw["Static Properties - Dust"]
                    end)
                    if staticPropsDust then
                        pcall(function()
                            staticPropsDust(udw)
                        end)
                        Log.Debug(MODULE, "Static Properties - Dust called")
                    end
                end
                
                Actors.SetUDWProperty("Refresh Settings", true)
                Log.Debug(MODULE, "Forced Dust particles on", {dustIntensity = dustIntensity})
            else
                -- DISABLE DUST: Set properties for UDW state consistency
                Actors.SetUDWProperty("Dust - Manual Override", true)
                Actors.SetUDWProperty("Dust", 0.0)
                Actors.SetUDWProperty("Enable Dust Particles", false)
                Actors.SetUDWProperty("Dust Particle Spawn Count", 0.0)
                
                -- DIRECT NIAGARA CONTROL: Find and deactivate dust particle components
                local deactivatedCount = 0
                pcall(function()
                    local niagaraComponents = FindAllOf("NiagaraComponent")
                    if niagaraComponents then
                        for idx, comp in ipairs(niagaraComponents) do
                            if comp and comp:IsValid() then
                                local isDustComponent = false
                                local fullName = ""
                                pcall(function() fullName = comp:GetFullName() end)
                                
                                if fullName and fullName:find("Dust") then
                                    isDustComponent = true
                                end
                                
                                if not isDustComponent then
                                    pcall(function()
                                        local asset = comp.Asset
                                        if asset and asset:IsValid() then
                                            local assetFullName = asset:GetFullName()
                                            if assetFullName and assetFullName:find("Dust") then
                                                isDustComponent = true
                                            end
                                        end
                                    end)
                                end
                                
                                if isDustComponent then
                                    pcall(function() comp:DeactivateImmediate() end)
                                    deactivatedCount = deactivatedCount + 1
                                end
                            end
                        end
                    end
                end)
                Log.Debug(MODULE, "Direct Dust Niagara deactivation", {deactivatedCount = deactivatedCount})
            end
            
            -- Force UDW to process updates via Force Tick (stronger than Runtime Tick)
            local udw = Actors.GetUDW()
            if udw then
                -- Try Force Tick first
                local forceTick = nil
                pcall(function()
                    forceTick = udw["Force Tick"]
                end)
                if forceTick then
                    pcall(function()
                        forceTick(udw)
                    end)
                    Log.Debug(MODULE, "UDW Force Tick called successfully")
                else
                    -- Fallback to Runtime Tick
                    local runtimeTick = nil
                    local success, result = pcall(function()
                        return udw["UDW Runtime Tick"]
                    end)
                    if success and result then
                        runtimeTick = result
                        pcall(function()
                            runtimeTick(udw, 1.0)
                        end)
                        Log.Debug(MODULE, "UDW Runtime Tick called successfully")
                    end
                end
                
                -- Try to call Set Shared Weather Particle Parameters on rain component
                local rainParticles = nil
                pcall(function()
                    rainParticles = udw["Rain Particles"]
                end)
                if rainParticles then
                    local setSharedParams = nil
                    pcall(function()
                        setSharedParams = udw["Set Shared Weather Particle Parameters"]
                    end)
                    if setSharedParams then
                        pcall(function()
                            setSharedParams(udw, rainParticles)
                        end)
                        Log.Debug(MODULE, "Set Shared Weather Particle Parameters called")
                    end
                end
                
                -- Read back values to verify they were set
                local rainVal, enableRain, spawnCount
                pcall(function()
                    rainVal = udw["Rain"]
                    enableRain = udw["Enable Rain Particles"]
                    spawnCount = udw["Rain Particle Spawn Count"]
                end)
                Log.Debug(MODULE, "Readback particle values", {
                    Rain = tostring(rainVal),
                    EnableRainParticles = tostring(enableRain),
                    SpawnCount = tostring(spawnCount)
                })
            end
        end
        
        Log.Info(MODULE, "Weather change initiated", {
            preset = presetName,
            displayName = Presets.GetDisplayName(presetName),
            isDry = Presets.IsDry(presetName)
        })
        
        -- IMMEDIATELY save state after weather change (so PA entry has correct preset)
        pcall(function()
            local Persistence = require("systems.persistence")
            if Persistence and Persistence.Save then
                Persistence.Save("weather_change")
            end
        end)
        
        return true
    end
    
    return false
end

--- Apply weather with fast transition (for keybind cycling)
--- @param presetName string
--- @return boolean success
function Weather.ApplyFast(presetName)
    local fastTime = Config.Weather.FastTransitionTime or 2.0
    return Weather.Apply(presetName, fastTime)
end

--- Apply the default weather preset
--- @return boolean success
function Weather.ApplyDefault()
    local defaultPreset = Presets.GetDefault()
    Log.Info(MODULE, "Applying default weather", {preset = defaultPreset})
    return Weather.Apply(defaultPreset)
end

--- Cycle to next weather preset
--- @return string|nil New preset name or nil on failure
function Weather.CycleNext()
    local current = State.GetCurrentPreset()
    local next = Presets.GetNextInCycle(current)
    
    Log.Info(MODULE, "Cycling to next preset", {from = current, to = next})
    
    if Weather.ApplyFast(next) then
        return next
    end
    return nil
end

--- Cycle to previous weather preset
--- @return string|nil New preset name or nil on failure
function Weather.CyclePrev()
    local current = State.GetCurrentPreset()
    local prev = Presets.GetPrevInCycle(current)
    
    Log.Info(MODULE, "Cycling to previous preset", {from = current, to = prev})
    
    if Weather.ApplyFast(prev) then
        return prev
    end
    return nil
end

--- Get current weather preset name
--- @return string|nil
function Weather.GetCurrent()
    return State.GetCurrentPreset()
end

--- Check if weather is currently transitioning
--- @return boolean
function Weather.IsTransitioning()
    return State.IsWeatherTransitioning()
end

--- Force clear weather immediately (emergency/debug)
--- @return boolean success
function Weather.ForceClear()
    Log.Info(MODULE, "Forcing clear weather")
    return Weather.Apply("Clear_Skies", 0.5)
end

--- Get weather status for debugging
--- @return table
function Weather.GetStatus()
    return {
        currentPreset = State.GetCurrentPreset(),
        targetPreset = State.GetTargetPreset(),
        isTransitioning = State.IsWeatherTransitioning(),
        lastApplyTime = lastApplyTime,
        applyCount = applyCount,
        cachedAssets = Utils.Keys(assetCache),
    }
end

--- Clear the asset cache (call on map unload)
function Weather.ClearCache()
    Log.Debug(MODULE, "Clearing asset cache", {count = #Utils.Keys(assetCache)})
    assetCache = {}
end

--- Tick function (check for transition completion, etc.)
function Weather.Tick()
    if not enabled then return end  -- master switch: no precip/weather processing

    -- Check if transition should be complete
    if State.IsWeatherTransitioning() then
        -- State.IsWeatherTransitioning() auto-completes based on time
        -- Just calling it will update the state if needed
    end
    
    -- Retry pending rain activation
    if pendingRainActivation and pendingRainRetryCount < MAX_RAIN_RETRIES then
        pendingRainRetryCount = pendingRainRetryCount + 1
        
        local activatedCount = 0
        pcall(function()
            local niagaraComponents = FindAllOf("NiagaraComponent")
            if niagaraComponents then
                for idx, comp in ipairs(niagaraComponents) do
                    if comp and comp:IsValid() then
                        local isRainComponent = false
                        local fullName = nil
                        
                        pcall(function()
                            fullName = comp:GetFullName()
                        end)
                        
                        if fullName and fullName:find("Rain") then
                            isRainComponent = true
                        end
                        
                        if not isRainComponent then
                            pcall(function()
                                local asset = comp.Asset
                                if asset and asset:IsValid() then
                                    local assetFullName = asset:GetFullName()
                                    if assetFullName and assetFullName:find("Rain") then
                                        isRainComponent = true
                                    end
                                end
                            end)
                        end
                        
                        if isRainComponent then
                            pcall(function()
                                comp:SetPaused(false)
                            end)
                            pcall(function()
                                comp:Activate(true)
                                activatedCount = activatedCount + 1
                            end)
                        end
                    end
                end
            end
        end)
        
        if activatedCount > 0 then
            pendingRainActivation = false
            Log.Info(MODULE, "Rain activation retry succeeded", {
                activatedCount = activatedCount,
                retryNumber = pendingRainRetryCount
            })
        else
            Log.Debug(MODULE, "Rain activation retry", {
                retryNumber = pendingRainRetryCount,
                activatedCount = 0
            })
        end
        
        if pendingRainRetryCount >= MAX_RAIN_RETRIES then
            Log.Warn(MODULE, "Rain activation retries exhausted")
            pendingRainActivation = false
        end
    end
end

--- Apply weather on course load if enabled
function Weather.OnCourseLoad()
    if Config.Weather.ApplyDefaultOnLoad then
        Log.Info(MODULE, "Course loaded - applying default weather")
        -- Small delay to let UDW initialize
        -- The main loop will handle this through the Tick
        Weather.ApplyDefault()
    end
end

-- Initialize on load
Weather.Init()

return Weather
