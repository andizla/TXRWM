-- TXR Weather Mod v3.0
-- systems/weather.lua
-- Weather control using UDW's Change Weather API
-- THIS IS THE CRITICAL MODULE: Uses the proper UDW API instead of property manipulation

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
        Log.Error(MODULE, "StaticFindObject not available: not running in UE4SS?")
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

-- (Two unused Niagara helpers, setNiagaraParameter / setNiagaraActive,
-- removed 2026-07-09: relics of a pre-3.0 rain-control approach, never
-- called. The live paths use direct component calls; see _SuppressKill and
-- the dry-kill section.)

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
-- Tunnel/interior precipitation suppression state (see Weather.SetPrecipSuppressed
-- near the end of this file). Declared BEFORE Weather.Apply so both reference the
-- same locals (defining them later would silently split them into globals here).
local precipSuppressed = false
local suppressedComps = nil
local suppressEnforceClock = 0

function Weather.Apply(presetName, transitionTime)
    -- Master switch: when disabled, the mod applies no weather (ToD/visuals only).
    -- Covers default-on-load, cycling, and reset since they all route through here.
    if not enabled then
        Log.Debug(MODULE, "Weather disabled: skipping apply", {preset = presetName})
        return false
    end

    -- A weather (re)apply re-establishes particles, so any transient tunnel
    -- suppression is void. Full restore path (NOT just a state clear): it
    -- un-hides the suppressed components; a bare clear would leave them
    -- hidden forever. Table-field call resolves at run time (defined later
    -- in the file); no-op when not suppressed.
    if precipSuppressed and Weather.SetPrecipSuppressed then
        Weather.SetPrecipSuppressed(false)
    end
    precipSuppressed = false
    suppressedComps = nil

    -- Validate preset exists
    if not Presets.Exists(presetName) then
        Log.Error(MODULE, "Unknown preset", {preset = presetName})
        return false
    end
    
    -- Check if we have actors: a real course, or the PA scene (its own
    -- UDS/UDW validated; the garage never gets that far). PA continue mode
    -- re-applies the captured course preset there (Config.PA.Mode).
    if not Actors.IsOnCourse() and not (Actors.IsInPAScene and Actors.IsInPAScene()) then
        Log.Warn(MODULE, "Cannot apply weather: not on course")
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
                            -- UFunction: self is required even with no params
                            -- (the old bare call errored silently in pcall)
                            updateRainParams(udw)
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
                    Log.Debug(MODULE, "Rain activation pending: will retry in tick loop")
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
    
    -- Tunnel precip suppression ENFORCEMENT (2026-07-08): while suppressed,
    -- UDW's respawn behaviors and our own pending-rain retry below resurrect
    -- the particles ("Alt+J works, but reapplies shortly after"). Re-kill on
    -- a ~1s cadence (rescan included; respawned components are NEW
    -- instances) and short-circuit the retry entirely.
    -- Weather._SuppressKill is a table field (defined at the end of this
    -- file), resolved at CALL time; a forward local here would silently
    -- split into a nil global (the ppWatchTick lesson).
    if precipSuppressed then
        local nowS = os.clock()
        if nowS - suppressEnforceClock >= 1.0 then
            suppressEnforceClock = nowS
            if Weather._SuppressKill then Weather._SuppressKill() end
        end
    -- Retry pending rain activation (skipped while suppressed)
    elseif pendingRainActivation and pendingRainRetryCount < MAX_RAIN_RETRIES then
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
        Log.Info(MODULE, "Course loaded: applying default weather")
        -- Small delay to let UDW initialize
        -- The main loop will handle this through the Tick
        Weather.ApplyDefault()
    end
end

-- ============== TUNNEL PRECIP SUPPRESSION (2026-07-08) ==============
-- Pause the precipitation Niagara components while the car is inside a tunnel
-- (or any covered volume), restore them on exit. Deliberately does NOT touch
-- the weather STATE: UDW keeps raining (it IS raining outside the tunnel).
-- Pure component-level Activate/Deactivate, the same calls the stable dry-kill
-- path uses. Components are cached on first suppress and revalidated per use;
-- any weather (re)apply clears the suppression (Weather.Apply resets it).
-- CALLER MUST BE ON THE GAME THREAD (keybind handlers and light_cycle's
-- containment poll both are).

--- Find the live precip Niagara components (Rain/Snow by name or asset).
local function findPrecipComponents()
    local found = {}
    pcall(function()
        local comps = FindAllOf("NiagaraComponent")
        if not comps then return end
        for _, comp in ipairs(comps) do
            if comp and comp:IsValid() then
                local hit = false
                pcall(function()
                    local n = comp:GetFullName() or ""
                    if n:find("Rain") or n:find("Snow") then hit = true end
                end)
                if not hit then
                    pcall(function()
                        local asset = comp.Asset
                        if asset and asset:IsValid() then
                            local an = asset:GetFullName() or ""
                            if an:find("Rain") or an:find("Snow") then hit = true end
                        end
                    end)
                end
                if hit then found[#found + 1] = comp end
            end
        end
    end)
    return found
end

--- Hide all live precip components (rescans; respawned components are new
--- instances). Used by SetPrecipSuppressed and re-run ~1s from Weather.Tick
--- while suppression holds (table field so Tick, defined earlier in the file,
--- can resolve it at call time).
---
--- HIDE-ONLY v2 (2026-07-12): suppression no longer deactivates anything or
--- touches the UDW master switches. The components keep SIMULATING and
--- SPAWNING invisibly (one hidden Niagara system, negligible cost), so the
--- restore is a pure unhide and the sky is mid-rain the same frame, the
--- kill/restore asymmetry that three revive-side fixes (master restore,
--- Static Properties push, AdvanceSimulationByTime warmup) never closed,
--- because a re-activated system always restarts from an empty sky. UDW's
--- periodic particle update may freely re-Activate the components (they are
--- already active); the ~1s enforcement rescan re-hides anything it
--- respawns fresh (e.g. a weather change mid-tunnel).
--- @return number hidden
function Weather._SuppressKill()
    suppressedComps = findPrecipComponents()
    local n = 0
    for _, comp in ipairs(suppressedComps) do
        local ok = pcall(function() comp:SetHiddenInGame(true, true) end)
        if ok then n = n + 1 end
    end
    return n
end

--- Suppress (true) or restore (false) precipitation VISIBILITY. Idempotent.
--- Weather state, wetness, sound and the UDW particle switches all stay
--- untouched: it IS still raining, just not visibly under cover.
--- @param on boolean
function Weather.SetPrecipSuppressed(on)
    on = on and true or false
    if on == precipSuppressed then return end
    precipSuppressed = on

    if on then
        suppressEnforceClock = os.clock()
        local n = Weather._SuppressKill()
        Log.Info(MODULE, "Precip suppressed (tunnel)", {components = n, mode = "hidden"})
    else
        -- Unhide a FRESH scan (the suppress-time cache can be stale) plus
        -- the cached list. Nothing was ever stopped, so this is the whole
        -- restore.
        local n = 0
        local seen = {}
        local function unhideList(list)
            if not list then return end
            for _, comp in ipairs(list) do
                pcall(function()
                    if not seen[comp] and comp:IsValid() then
                        seen[comp] = true
                        comp:SetHiddenInGame(false, true)
                        n = n + 1
                    end
                end)
            end
        end
        unhideList(findPrecipComponents())
        unhideList(suppressedComps)
        suppressedComps = nil
        Log.Info(MODULE, "Precip restored (tunnel exit)", {components = n})
    end
end

--- @return boolean
function Weather.IsPrecipSuppressed()
    return precipSuppressed
end

-- Initialize on load
Weather.Init()

return Weather
