-- TXR Weather Mod v3.0
-- systems/wetness.lua
-- Wetness & Puddle simulation system
-- Phase 6 Implementation
--
-- Simulates surface wetness accumulation during rain and decay when dry.
-- Puddles form after wetness exceeds a threshold.
-- Water level rises with prolonged heavy rain.
--
-- This system runs its own simulation loop independent of UDW's built-in
-- wetness timing, giving us precise control over the visual experience.

local Wetness = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local Utils = require("core.utils")
local State = require("core.state")
local Config = require("config")
local Actors = require("systems.actors")
local Presets = require("systems.presets")

local MODULE = "Wetness"

-- ============== UDW PROPERTY NAMES ==============
local UDW_PROPS = {
    -- Wetness
    MATERIAL_WETNESS = "Material Wetness",
    MATERIAL_WETNESS_MANUAL = "Material Wetness - Manual Override",
    MAX_MATERIAL_WETNESS = "Max Material Wetness",
    WETNESS_COVERAGE_DURATION = "Wetness Coverage Duration",
    WETNESS_DRY_DURATION = "Wetness Dry Duration",
    WETNESS_DRY_SPEED_SUN = "Wetness Dry Speed In Sunlight",
    WETNESS_DRY_SPEED_CLOUD = "Wetness Dry Speed Without Sunlight",
    WETNESS_UPDATE_NEEDED = "Material Wetness Update Needed",
    
    -- Puddles
    PUDDLE_COVERAGE = "Puddle Coverage",
    PUDDLE_SHARPNESS = "Puddle Sharpness",
    PUDDLE_Z_CUTOFF = "Puddles Z Normal Cutoff",
    PUDDLE_Z_FALLOFF = "Puddles Z Normal Falloff",
    DYNAMIC_PUDDLES_ACTIVE = "Dynamic Puddles Active",
    
    -- Base wetness controls (these might control the actual visual)
    BASE_WETNESS_RAINING = "Base Wetness When Raining",
    BASE_WETNESS_CLEAR = "Base Wetness When Clear",
    
    -- Water Level
    USE_WATER_LEVEL = "Use UDS Water Level",
    WATER_LEVEL_FALLOFF = "Water Level Material Falloff",
    
    -- Water appearance
    MATERIAL_WATER_ROUGHNESS = "Material Water Roughness",
    
    -- Refresh
    REFRESH_SETTINGS = "Refresh Settings",
    
    -- Material State Manager (separate component)
    MATERIAL_STATE_MANAGER = "Material State Manager",
}

-- UDS property for water level height
local UDS_PROPS = {
    WATER_LEVEL = "Water Level",
}

-- ============== SIMULATION CONFIGURATION ==============
-- Values tuned from V1.34's WetConfig and WetPerf

local SIM_CONFIG = {
    -- Wetness accumulation/decay
    riseRate = 0.45,              -- How fast surfaces wet (0-1 per second at max rain)
    dryHalfLifeSec = 55.0,        -- Half-life for drying (exponential decay)
    
    -- Puddle formation
    puddleThreshold = 0.35,       -- Wetness level before puddles start forming
    puddleRiseRate = 0.30,        -- How fast puddles form once threshold met
    puddleHalfLifeSec = 80.0,     -- Half-life for puddle decay (slower than wetness)
    
    -- Puddle appearance
    sharpnessMin = 40.0,          -- Minimum puddle edge sharpness
    sharpnessMax = 85.0,          -- Maximum puddle edge sharpness (more defined at high coverage)
    
    -- Water level (flooding effect for extreme rain)
    waterLevelThreshold = 0.55,   -- Puddle coverage before water level starts rising
    waterLevelRiseRate = 0.08,    -- How fast water level rises
    waterLevelMax = 0.45,         -- Maximum water level (prevents full flooding)
    waterLevelFalloff = 0.40,     -- Edge softness for water level
}

local PERF_CONFIG = {
    -- Performance tuning
    tickInterval = 4,             -- Run simulation every N main loop ticks (4 * 125ms = 500ms)
    writeCooldownTicks = 8,       -- Minimum ticks between UDW writes (8 * 125ms = 1000ms)
    epsilon = 0.01,               -- Skip changes smaller than this
    quantization = 1.0/128.0,     -- Quantize values to reduce write frequency
    
    -- GPU load caps (prevent visual overload)
    maxPuddleCoverage = 0.65,     -- Maximum puddle coverage
    maxWaterLevel = 0.45,         -- Maximum water level
    
    -- Hysteresis for boolean properties
    hysteresisOn = 0.03,          -- Threshold to turn ON a feature
    hysteresisOff = 0.015,        -- Threshold to turn OFF a feature (lower = stickier)
    
    -- Delta time per tick (125ms main loop interval)
    deltaTimePerTick = 0.125,
}

-- ============== INTERNAL STATE ==============
local internalState = {
    initialized = false,
    
    -- Simulation values (0-1 range)
    wetness = 0.0,
    puddleCoverage = 0.0,
    waterLevel = 0.0,
    
    -- Tick counters (more reliable than os.clock in UE4SS)
    tickCounter = 0,
    lastSimTick = 0,
    lastWriteTick = 0,
    
    -- Last written values (for change detection)
    lastWrittenWetness = -1,
    lastWrittenPuddle = -1,
    lastWrittenSharpness = -1,
    lastWrittenWaterLevel = -1,
    
    -- Boolean states with hysteresis
    waterLevelEnabled = false,
    manualOverrideSet = false,
    dynamicPuddlesSet = false,
    
    -- DLWE initialization tracking
    dlweInitialized = false,
    
    -- Rain state cache
    currentRainIntensity = 0,
    isRaining = false,
}

-- ============== INTERNAL FUNCTIONS ==============

--- Quantize a value to reduce write frequency
--- @param value number Input value
--- @return number Quantized value
local function quantize(value)
    local q = PERF_CONFIG.quantization
    return math.floor(value / q + 0.5) * q
end

--- Check if a value has changed significantly
--- @param newValue number New value
--- @param oldValue number Previous value
--- @return boolean True if change is significant
local function hasSignificantChange(newValue, oldValue)
    if oldValue < 0 then return true end  -- Never written
    return math.abs(newValue - oldValue) > PERF_CONFIG.epsilon
end

--- Apply hysteresis to boolean state transition
--- @param currentState boolean Current boolean state
--- @param value number Value to check (0-1)
--- @param enableThreshold number Value to enable
--- @return boolean New state with hysteresis applied
local function applyHysteresis(currentState, value, enableThreshold)
    if currentState then
        -- Currently ON - use lower threshold to turn OFF (sticky)
        return value > PERF_CONFIG.hysteresisOff
    else
        -- Currently OFF - use higher threshold to turn ON
        return value > enableThreshold + PERF_CONFIG.hysteresisOn
    end
end

--- Get current rain intensity from weather state
--- @return number Rain intensity (0-10), boolean isRaining
local function getRainState()
    local presetName = State.GetCurrentPreset()
    if not presetName then
        return 0, false
    end
    
    local presetData = Presets.Get(presetName)
    if not presetData then
        return 0, false
    end
    
    if presetData.hasRain then
        local intensity = presetData.rainIntensity or 7.0
        return intensity, true
    end
    
    -- Snow also contributes to wetness (melting)
    if presetData.hasSnow then
        local intensity = (presetData.snowIntensity or 5.0) * 0.3  -- Snow melts slower
        return intensity, true
    end
    
    return 0, false
end

--- Ensure manual override is set on UDW
--- @return boolean success
local function ensureManualOverride()
    if internalState.manualOverrideSet and internalState.dynamicPuddlesSet then
        return true
    end
    
    local udw = Actors.GetUDW()
    if not udw then
        return false
    end
    
    -- Check if UDW is valid
    local isValid = false
    pcall(function() isValid = udw:IsValid() end)
    if not isValid then
        Log.Debug(MODULE, "UDW not valid for manual override")
        return false
    end
    
    -- Set Material Wetness manual override
    if not internalState.manualOverrideSet then
        local success = pcall(function()
            udw[UDW_PROPS.MATERIAL_WETNESS_MANUAL] = true
            udw[UDW_PROPS.MAX_MATERIAL_WETNESS] = 1.0  -- Ensure max is not limiting us
        end)
        
        if success then
            internalState.manualOverrideSet = true
            Log.Info(MODULE, "Material Wetness manual override enabled")
        else
            Log.Warn(MODULE, "Failed to set Material Wetness manual override")
            return false
        end
    end
    
    -- Enable Dynamic Puddles Active
    if not internalState.dynamicPuddlesSet then
        local success = pcall(function()
            udw[UDW_PROPS.DYNAMIC_PUDDLES_ACTIVE] = true
        end)
        
        if success then
            internalState.dynamicPuddlesSet = true
            Log.Info(MODULE, "Dynamic Puddles Active enabled")
        else
            Log.Warn(MODULE, "Failed to enable Dynamic Puddles Active")
        end
        
        -- Call Static Properties - Material Effects to initialize system
        pcall(function()
            local staticFunc = udw["Static Properties - Material Effects"]
            if staticFunc then
                staticFunc(udw)
                Log.Debug(MODULE, "Called Static Properties - Material Effects")
            end
        end)
        
        -- Call Static Properties - DLWE to initialize DLWE system
        pcall(function()
            local dlweStatic = udw["Static Properties - DLWE"]
            if dlweStatic then
                dlweStatic(udw)
                Log.Debug(MODULE, "Called Static Properties - DLWE")
            end
        end)
        
        -- Call DLWE Active Update to activate the system
        pcall(function()
            local dlweActiveUpdate = udw["DLWE Active Update"]
            if dlweActiveUpdate then
                dlweActiveUpdate(udw)
                Log.Debug(MODULE, "Called DLWE Active Update")
            end
        end)
        
        -- Call Update DLWE Interaction Mode
        pcall(function()
            local dlweInteraction = udw["Update DLWE Interaction Mode"]
            if dlweInteraction then
                dlweInteraction(udw)
                Log.Debug(MODULE, "Called Update DLWE Interaction Mode")
            end
        end)
    end
    
    return internalState.manualOverrideSet
end

--- Calculate puddle sharpness based on coverage
--- Higher coverage = sharper, more defined puddle edges
--- @param coverage number Puddle coverage (0-1)
--- @return number Sharpness value
local function calculateSharpness(coverage)
    -- Interpolate between min and max based on coverage
    local t = Utils.Clamp(coverage / PERF_CONFIG.maxPuddleCoverage, 0, 1)
    return SIM_CONFIG.sharpnessMin + (SIM_CONFIG.sharpnessMax - SIM_CONFIG.sharpnessMin) * t
end

--- Write wetness properties to UDW
--- @param wetness number Wetness value (0-1)
--- @param puddle number Puddle coverage (0-1)
--- @param sharpness number Puddle sharpness
--- @param waterLevel number Water level (0-1)
--- @return boolean success
local function writeToUDW(wetness, puddle, sharpness, waterLevel)
    local udw = Actors.GetUDW()
    local uds = Actors.GetUDS()
    if not udw then
        Log.Debug(MODULE, "writeToUDW: No UDW available")
        return false
    end
    
    local writeCount = 0
    local errorCount = 0
    
    -- Write wetness if changed
    if hasSignificantChange(wetness, internalState.lastWrittenWetness) then
        local ok, err = pcall(function()
            udw[UDW_PROPS.MATERIAL_WETNESS] = wetness
            -- Also set base wetness values which may control the actual visual
            udw[UDW_PROPS.BASE_WETNESS_RAINING] = wetness
            udw[UDW_PROPS.BASE_WETNESS_CLEAR] = wetness
        end)
        if ok then
            internalState.lastWrittenWetness = wetness
            writeCount = writeCount + 1
        else
            errorCount = errorCount + 1
            Log.Warn(MODULE, "Failed to write Material Wetness", {error = tostring(err)})
        end
    end
    
    -- Write puddle coverage if changed
    if hasSignificantChange(puddle, internalState.lastWrittenPuddle) then
        local ok, err = pcall(function()
            udw[UDW_PROPS.PUDDLE_COVERAGE] = puddle
        end)
        if ok then
            internalState.lastWrittenPuddle = puddle
            writeCount = writeCount + 1
        else
            errorCount = errorCount + 1
            Log.Warn(MODULE, "Failed to write Puddle Coverage", {error = tostring(err)})
        end
    end
    
    -- Write sharpness if changed
    if hasSignificantChange(sharpness, internalState.lastWrittenSharpness) then
        local ok, err = pcall(function()
            udw[UDW_PROPS.PUDDLE_SHARPNESS] = sharpness
        end)
        if ok then
            internalState.lastWrittenSharpness = sharpness
            writeCount = writeCount + 1
        else
            errorCount = errorCount + 1
            Log.Warn(MODULE, "Failed to write Puddle Sharpness", {error = tostring(err)})
        end
    end
    
    -- Handle water level with hysteresis for the boolean enable
    local shouldEnableWaterLevel = applyHysteresis(
        internalState.waterLevelEnabled,
        waterLevel,
        SIM_CONFIG.waterLevelThreshold
    )
    
    -- Write water level enable state if changed
    if shouldEnableWaterLevel ~= internalState.waterLevelEnabled then
        pcall(function()
            udw[UDW_PROPS.USE_WATER_LEVEL] = shouldEnableWaterLevel
        end)
        internalState.waterLevelEnabled = shouldEnableWaterLevel
        writeCount = writeCount + 1
        Log.Debug(MODULE, "Water level toggle", {enabled = shouldEnableWaterLevel})
    end
    
    -- Write water level value to UDS if enabled and changed
    if shouldEnableWaterLevel and uds then
        if hasSignificantChange(waterLevel, internalState.lastWrittenWaterLevel) then
            local ok = pcall(function()
                uds[UDS_PROPS.WATER_LEVEL] = waterLevel
            end)
            if ok then
                internalState.lastWrittenWaterLevel = waterLevel
                writeCount = writeCount + 1
            end
            
            -- Also set falloff on UDW
            pcall(function()
                udw[UDW_PROPS.WATER_LEVEL_FALLOFF] = SIM_CONFIG.waterLevelFalloff
            end)
        end
    end
    
    -- Trigger refresh if we wrote anything
    if writeCount > 0 then
        -- Write to Material State Manager (the actual controller)
        pcall(function()
            local msm = udw[UDW_PROPS.MATERIAL_STATE_MANAGER]
            if msm then
                -- Set Replicated Wetness directly
                msm["Replicated Wetness"] = wetness
                
                -- Try Apply New State function (Snow, Wetness, Dust)
                local applyState = msm["Apply New State"]
                if applyState then
                    applyState(msm, 0.0, wetness, 0.0)  -- Snow=0, Wetness=value, Dust=0
                    Log.Debug(MODULE, "Called Material State Manager Apply New State")
                end
                
                -- NOTE: Increment Material State has OUT params - removed
                
                -- Update Replicated State
                local updateReplicated = msm["Update Replicated State"]
                if updateReplicated then
                    updateReplicated(msm)
                end
                
                -- Also update change speed for faster response
                msm["Wetness Change Speed"] = 10.0  -- Fast change
                
                Log.Debug(MODULE, "Wrote to Material State Manager", {
                    replicatedWetness = wetness
                })
            else
                Log.Debug(MODULE, "Material State Manager not available")
            end
        end)
        
        pcall(function()
            udw[UDW_PROPS.WETNESS_UPDATE_NEEDED] = true
            udw[UDW_PROPS.REFRESH_SETTINGS] = true
        end)
        
        -- Call Update Material Effect Parameters to apply changes visually
        pcall(function()
            local updateFunc = udw["Update Material Effect Parameters"]
            if updateFunc then
                updateFunc(udw)
                Log.Debug(MODULE, "Called Update Material Effect Parameters")
            end
        end)
        
        -- Try UDW State Apply to force state update
        pcall(function()
            local stateApply = udw["UDW State Apply"]
            if stateApply then
                stateApply(udw)
                Log.Debug(MODULE, "Called UDW State Apply")
            end
        end)
        
        -- Call DLWE Active Update to refresh DLWE system
        pcall(function()
            local dlweUpdate = udw["DLWE Active Update"]
            if dlweUpdate then
                dlweUpdate(udw)
            end
        end)
        
        -- Also try Force Tick to ensure update
        pcall(function()
            local forceTick = udw["Force Tick"]
            if forceTick then
                forceTick(udw)
            end
        end)
        
        -- Increment Global Material Effects
        pcall(function()
            local incrementGlobal = udw["Increment Global Material Effects"]
            if incrementGlobal then
                incrementGlobal(udw)
            end
        end)
        
        -- NOTE: Apply Max to Material Effects and Dynamic Landscape Weather Effects_ 
        -- have OUT parameters that cause errors - removed to reduce log spam.
        -- The basic property writes + MSM Apply New State seem to be the correct approach.
        
        Log.Info(MODULE, "Wrote wetness properties", {
            writes = writeCount,
            errors = errorCount,
            wetness = string.format("%.3f", wetness),
            puddle = string.format("%.3f", puddle),
            sharpness = string.format("%.1f", sharpness),
            waterLevel = string.format("%.3f", waterLevel)
        })
    end
    
    return writeCount > 0
end

--- Run one simulation step
--- @param deltaTime number Time since last tick in seconds
local function simulationStep(deltaTime)
    -- Get current rain state
    local rainIntensity, isRaining = getRainState()
    internalState.currentRainIntensity = rainIntensity
    internalState.isRaining = isRaining
    
    -- Normalize rain intensity to 0-1 range (input is 0-10)
    local normalizedRain = rainIntensity / 10.0
    
    -- ========== WETNESS SIMULATION ==========
    if isRaining then
        -- Accumulate wetness based on rain intensity
        local riseAmount = SIM_CONFIG.riseRate * normalizedRain * deltaTime
        internalState.wetness = math.min(1.0, internalState.wetness + riseAmount)
    else
        -- Exponential decay when dry
        -- Formula: value = value * 0.5^(dt / halfLife)
        local decayFactor = (0.5) ^ (deltaTime / SIM_CONFIG.dryHalfLifeSec)
        internalState.wetness = internalState.wetness * decayFactor
        
        -- Clamp to zero when very small
        if internalState.wetness < 0.001 then
            internalState.wetness = 0
        end
    end
    
    -- ========== PUDDLE SIMULATION ==========
    if internalState.wetness > SIM_CONFIG.puddleThreshold then
        -- Puddles form when wet enough
        -- Rate scales with how much over threshold we are
        local excessWetness = internalState.wetness - SIM_CONFIG.puddleThreshold
        local puddleRiseAmount = SIM_CONFIG.puddleRiseRate * excessWetness * deltaTime
        internalState.puddleCoverage = math.min(
            PERF_CONFIG.maxPuddleCoverage,
            internalState.puddleCoverage + puddleRiseAmount
        )
    else
        -- Puddles decay (slower than wetness)
        local decayFactor = (0.5) ^ (deltaTime / SIM_CONFIG.puddleHalfLifeSec)
        internalState.puddleCoverage = internalState.puddleCoverage * decayFactor
        
        if internalState.puddleCoverage < 0.001 then
            internalState.puddleCoverage = 0
        end
    end
    
    -- ========== WATER LEVEL SIMULATION ==========
    if internalState.puddleCoverage > SIM_CONFIG.waterLevelThreshold and isRaining then
        -- Water level rises during heavy, prolonged rain
        local excessPuddle = internalState.puddleCoverage - SIM_CONFIG.waterLevelThreshold
        local waterRiseAmount = SIM_CONFIG.waterLevelRiseRate * excessPuddle * normalizedRain * deltaTime
        internalState.waterLevel = math.min(
            PERF_CONFIG.maxWaterLevel,
            internalState.waterLevel + waterRiseAmount
        )
    else
        -- Water level decays faster than puddles when rain stops
        local decayFactor = (0.5) ^ (deltaTime / (SIM_CONFIG.puddleHalfLifeSec * 0.5))
        internalState.waterLevel = internalState.waterLevel * decayFactor
        
        if internalState.waterLevel < 0.001 then
            internalState.waterLevel = 0
        end
    end
end

-- ============== PUBLIC API ==============

--- Initialize the wetness module
function Wetness.Init()
    Log.Info(MODULE, "Initializing wetness module")
    
    internalState.initialized = true
    internalState.wetness = 0
    internalState.puddleCoverage = 0
    internalState.waterLevel = 0
    internalState.tickCounter = 0
    internalState.lastSimTick = 0
    internalState.lastWriteTick = 0
    internalState.manualOverrideSet = false
    internalState.dynamicPuddlesSet = false
    internalState.waterLevelEnabled = false
    
    -- Reset written value trackers
    internalState.lastWrittenWetness = -1
    internalState.lastWrittenPuddle = -1
    internalState.lastWrittenSharpness = -1
    internalState.lastWrittenWaterLevel = -1
    
    State.SetModuleStatus("wetness", true)
    return true
end

--- Tick function - runs the simulation
--- Called from main loop
function Wetness.Tick()
    if not internalState.initialized then return end
    if not Actors.IsOnCourse() then return end
    if State.IsPAFrozen() then return end
    
    -- CRITICAL: Ensure DLWE is initialized (fallback if OnActorsReady wasn't called by main)
    if not internalState.dlweInitialized then
        Log.Info(MODULE, "Tick: DLWE not initialized yet - calling OnActorsReady")
        if Wetness.OnActorsReady() then
            internalState.dlweInitialized = true
        end
    end
    
    -- Increment tick counter
    internalState.tickCounter = internalState.tickCounter + 1
    
    -- Only run simulation at configured interval
    local ticksSinceLastSim = internalState.tickCounter - internalState.lastSimTick
    if ticksSinceLastSim < PERF_CONFIG.tickInterval then
        return
    end
    
    internalState.lastSimTick = internalState.tickCounter
    
    -- Calculate delta time based on ticks elapsed
    local deltaTime = ticksSinceLastSim * PERF_CONFIG.deltaTimePerTick
    
    -- Ensure manual override is set
    if not ensureManualOverride() then
        Log.Debug(MODULE, "Failed to set manual override - UDW not available")
        return
    end
    
    -- Run simulation step
    simulationStep(deltaTime)
    
    -- Check write cooldown
    local ticksSinceWrite = internalState.tickCounter - internalState.lastWriteTick
    if ticksSinceWrite < PERF_CONFIG.writeCooldownTicks then
        return
    end
    
    -- Quantize values for output
    local wetness = quantize(internalState.wetness)
    local puddle = quantize(internalState.puddleCoverage)
    local sharpness = calculateSharpness(puddle)
    local waterLevel = quantize(internalState.waterLevel)
    
    -- Write to UDW if needed
    if writeToUDW(wetness, puddle, sharpness, waterLevel) then
        internalState.lastWriteTick = internalState.tickCounter
    end
end

--- Set wetness level directly (for presets or instant changes)
--- @param wetness number Wetness value (0-1)
--- @param puddle number|nil Optional puddle coverage (0-1)
--- @param waterLevel number|nil Optional water level (0-1)
function Wetness.SetLevels(wetness, puddle, waterLevel)
    internalState.wetness = Utils.Clamp(wetness or 0, 0, 1)
    internalState.puddleCoverage = Utils.Clamp(puddle or 0, 0, PERF_CONFIG.maxPuddleCoverage)
    internalState.waterLevel = Utils.Clamp(waterLevel or 0, 0, PERF_CONFIG.maxWaterLevel)
    
    -- Force immediate write by resetting trackers
    internalState.lastWriteTick = 0
    internalState.lastWrittenWetness = -1
    internalState.lastWrittenPuddle = -1
    internalState.lastWrittenSharpness = -1
    internalState.lastWrittenWaterLevel = -1
    
    Log.Info(MODULE, "Set wetness levels", {
        wetness = wetness,
        puddle = puddle,
        waterLevel = waterLevel
    })
end

--- Apply wetness settings based on weather preset
--- Called when weather changes
--- @param presetData table Preset data from Presets module
function Wetness.ApplyFromPreset(presetData)
    if not presetData then
        return
    end
    
    -- For rain presets, give an initial wetness boost
    if presetData.hasRain then
        local intensity = (presetData.rainIntensity or 7.0) / 10.0
        local initialWetness = intensity * 0.3  -- Start 30% wet based on intensity
        
        -- Only boost if current wetness is lower
        if internalState.wetness < initialWetness then
            internalState.wetness = initialWetness
            Log.Debug(MODULE, "Boosted initial wetness for rain preset", {
                preset = presetData.assetName,
                wetness = initialWetness
            })
        end
    end
    
    -- For snow, apply a smaller boost (snow takes time to melt)
    if presetData.hasSnow then
        local intensity = (presetData.snowIntensity or 5.0) / 10.0
        local initialWetness = intensity * 0.1
        
        if internalState.wetness < initialWetness then
            internalState.wetness = initialWetness
        end
    end
end

--- Force surfaces dry (instant reset)
function Wetness.ForceDry()
    Wetness.SetLevels(0, 0, 0)
    Log.Info(MODULE, "Forced surfaces dry")
end

--- Force maximum wetness (for testing)
--- Debug: Force maximum wetness and puddles
function Wetness.ForceWet()
    -- Ensure DLWE is initialized first!
    if not internalState.dlweInitialized then
        Log.Info(MODULE, "ForceWet: Initializing DLWE first")
        if Wetness.OnActorsReady() then
            internalState.dlweInitialized = true
        end
    end
    
    -- Set internal state to max
    internalState.wetness = 1.0
    internalState.puddleCoverage = PERF_CONFIG.maxPuddleCoverage
    internalState.waterLevel = 0.2  -- Some water level but not flooding
    
    -- Force trackers to trigger immediate write
    internalState.lastWriteTick = 0
    internalState.lastWrittenWetness = -1
    internalState.lastWrittenPuddle = -1
    internalState.lastWrittenSharpness = -1
    internalState.lastWrittenWaterLevel = -1
    
    -- Ensure manual override is set
    ensureManualOverride()
    
    -- Calculate values
    local wetness = internalState.wetness
    local puddle = internalState.puddleCoverage
    local sharpness = calculateSharpness(puddle)
    local waterLevel = internalState.waterLevel
    
    -- Force immediate write
    local wrote = writeToUDW(wetness, puddle, sharpness, waterLevel)
    
    -- Readback to verify
    local readback = Wetness.ReadFromUDW()
    
    Log.Info(MODULE, "DEBUG: Forced maximum wetness", {
        wetness = string.format("%.2f", wetness),
        puddle = string.format("%.2f", puddle),
        sharpness = string.format("%.1f", sharpness),
        waterLevel = string.format("%.2f", waterLevel),
        writeSuccess = wrote,
        readbackWetness = readback and string.format("%.2f", readback.materialWetness or -1) or "nil",
        readbackPuddle = readback and string.format("%.2f", readback.puddleCoverage or -1) or "nil",
        hasMSM = readback and readback.hasMSM or false,
        msmWetness = readback and readback.msmReplicatedWetness and string.format("%.2f", readback.msmReplicatedWetness) or "nil"
    })
end

--- Get current wetness state
--- @return table State info
function Wetness.GetState()
    return {
        wetness = internalState.wetness,
        puddleCoverage = internalState.puddleCoverage,
        waterLevel = internalState.waterLevel,
        isRaining = internalState.isRaining,
        rainIntensity = internalState.currentRainIntensity,
    }
end

--- Get status for debugging
--- @return table Debug info
function Wetness.GetStatus()
    return {
        initialized = internalState.initialized,
        wetness = string.format("%.3f", internalState.wetness),
        puddleCoverage = string.format("%.3f", internalState.puddleCoverage),
        waterLevel = string.format("%.3f", internalState.waterLevel),
        waterLevelEnabled = internalState.waterLevelEnabled,
        isRaining = internalState.isRaining,
        rainIntensity = internalState.currentRainIntensity,
        manualOverrideSet = internalState.manualOverrideSet,
        tickCounter = internalState.tickCounter,
        lastWriteTick = internalState.lastWriteTick,
    }
end

--- Read current values from UDW (for debugging/sync)
--- @return table Current UDW values
function Wetness.ReadFromUDW()
    local result = {}
    local udw = Actors.GetUDW()
    local uds = Actors.GetUDS()
    
    if udw then
        pcall(function() result.materialWetness = udw[UDW_PROPS.MATERIAL_WETNESS] end)
        pcall(function() result.puddleCoverage = udw[UDW_PROPS.PUDDLE_COVERAGE] end)
        pcall(function() result.puddleSharpness = udw[UDW_PROPS.PUDDLE_SHARPNESS] end)
        pcall(function() result.useWaterLevel = udw[UDW_PROPS.USE_WATER_LEVEL] end)
        pcall(function() result.maxWetness = udw[UDW_PROPS.MAX_MATERIAL_WETNESS] end)
        pcall(function() result.dynamicPuddlesActive = udw[UDW_PROPS.DYNAMIC_PUDDLES_ACTIVE] end)
        
        -- Read from Material State Manager
        pcall(function()
            local msm = udw[UDW_PROPS.MATERIAL_STATE_MANAGER]
            if msm then
                result.hasMSM = true
                result.msmReplicatedWetness = msm["Replicated Wetness"]
                result.msmWetnessChangeSpeed = msm["Wetness Change Speed"]
            else
                result.hasMSM = false
            end
        end)
    end
    
    if uds then
        pcall(function() result.waterLevel = uds[UDS_PROPS.WATER_LEVEL] end)
    end
    
    return result
end

--- Reset module state
function Wetness.Reset()
    Wetness.ForceDry()
    internalState.manualOverrideSet = false
    internalState.waterLevelEnabled = false
    Log.Info(MODULE, "Reset")
end

--- Called when course loads
function Wetness.OnCourseLoad()
    -- Reset tracking but preserve simulation state for seamless experience
    internalState.lastSimTick = internalState.tickCounter
    internalState.lastWriteTick = 0  -- Force write on course load
    internalState.manualOverrideSet = false
    internalState.dynamicPuddlesSet = false
    internalState.waterLevelEnabled = false
    
    -- Reset written value trackers to force initial write
    internalState.lastWrittenWetness = -1
    internalState.lastWrittenPuddle = -1
    internalState.lastWrittenSharpness = -1
    internalState.lastWrittenWaterLevel = -1
    
    Log.Info(MODULE, "Course load - wetness state preserved", {
        wetness = string.format("%.3f", internalState.wetness),
        puddleCoverage = string.format("%.3f", internalState.puddleCoverage)
    })
end

--- Called when actors are first discovered - initialize DLWE early
function Wetness.OnActorsReady()
    local udw = Actors.GetUDW()
    if not udw then
        Log.Debug(MODULE, "OnActorsReady: UDW not available")
        return false
    end
    
    -- Check if UDW is valid
    local isValid = false
    pcall(function() isValid = udw:IsValid() end)
    if not isValid then
        Log.Debug(MODULE, "OnActorsReady: UDW not valid")
        return false
    end
    
    Log.Info(MODULE, "OnActorsReady: Initializing DLWE and Material State systems")
    
    -- Step 1: Start Up Render Targets FIRST
    pcall(function()
        local startupRT = udw["Start Up Render Targets"]
        if startupRT then
            startupRT(udw)
            Log.Debug(MODULE, "OnActorsReady: Called Start Up Render Targets")
        end
    end)
    
    -- Step 2: Allow Render Target Drawing
    pcall(function()
        local allowRT = udw["Allow Render Target Drawing"]
        if allowRT then
            local result = allowRT(udw)
            Log.Debug(MODULE, "OnActorsReady: Called Allow Render Target Drawing", {result = tostring(result)})
        end
    end)
    
    -- Step 3: Get Material State Manager and START THE SIMULATION
    local msm = nil
    local msmSuccess, msmErr = pcall(function()
        msm = udw[UDW_PROPS.MATERIAL_STATE_MANAGER]
    end)
    
    if msm then
        Log.Debug(MODULE, "OnActorsReady: Got Material State Manager")
        
        -- NOTE: Start Material State Sim needs UDW, Weather State, Temp Manager object refs
        -- We don't have easy access to Weather State and Temp Manager, so skipping for now
        -- The simulation should already be running from UDW's internal initialization
        
        -- Queue Speed Update
        pcall(function()
            local queueSpeed = msm["Queue Speed Update"]
            if queueSpeed then
                queueSpeed(msm)
                Log.Debug(MODULE, "OnActorsReady: Called Queue Speed Update")
            end
        end)
        
        -- Update Change Speeds
        local updateSpeedsOk, updateSpeedsErr = pcall(function()
            local updateSpeeds = msm["Update Change Speeds"]
            if updateSpeeds then
                updateSpeeds(msm)
                Log.Debug(MODULE, "OnActorsReady: Called Update Change Speeds")
            else
                Log.Debug(MODULE, "OnActorsReady: Update Change Speeds not found")
            end
        end)
        if not updateSpeedsOk then
            Log.Debug(MODULE, "OnActorsReady: Update Change Speeds error", {err = tostring(updateSpeedsErr)})
        end
        
        -- NOTE: Increment Material State has OUT params that cause UE4SS errors - removed
    else
        Log.Debug(MODULE, "OnActorsReady: Material State Manager not available", {err = tostring(msmErr)})
    end
    
    -- Step 4: Call Static Properties - DLWE to initialize DLWE system
    pcall(function()
        local dlweStatic = udw["Static Properties - DLWE"]
        if dlweStatic then
            dlweStatic(udw)
            Log.Debug(MODULE, "OnActorsReady: Called Static Properties - DLWE")
        end
    end)
    
    -- Step 5: Recenter DLWE Render Target
    pcall(function()
        local recenterDLWE = udw["Recenter DLWE Render Target"]
        if recenterDLWE then
            recenterDLWE(udw)
            Log.Debug(MODULE, "OnActorsReady: Called Recenter DLWE Render Target")
        end
    end)
    
    -- Step 6: Call DLWE Active Update to activate the system
    pcall(function()
        local dlweActiveUpdate = udw["DLWE Active Update"]
        if dlweActiveUpdate then
            dlweActiveUpdate(udw)
            Log.Debug(MODULE, "OnActorsReady: Called DLWE Active Update")
        end
    end)
    
    -- Step 7: Call Update DLWE Interaction Mode
    pcall(function()
        local dlweInteraction = udw["Update DLWE Interaction Mode"]
        if dlweInteraction then
            dlweInteraction(udw)
            Log.Debug(MODULE, "OnActorsReady: Called Update DLWE Interaction Mode")
        end
    end)
    
    -- Step 8: Enable Dynamic Puddles Active
    pcall(function()
        udw[UDW_PROPS.DYNAMIC_PUDDLES_ACTIVE] = true
        Log.Debug(MODULE, "OnActorsReady: Dynamic Puddles Active enabled")
    end)
    
    -- Step 9: Call Static Properties - Material Effects
    pcall(function()
        local staticFunc = udw["Static Properties - Material Effects"]
        if staticFunc then
            staticFunc(udw)
            Log.Debug(MODULE, "OnActorsReady: Called Static Properties - Material Effects")
        end
    end)
    
    -- Step 10: Increment Global Material Effects to kick things off
    pcall(function()
        local incrementGlobal = udw["Increment Global Material Effects"]
        if incrementGlobal then
            incrementGlobal(udw)
            Log.Debug(MODULE, "OnActorsReady: Called Increment Global Material Effects")
        end
    end)
    
    -- Step 11: Update Material Effect Parameters
    pcall(function()
        local updateMatParams = udw["Update Material Effect Parameters"]
        if updateMatParams then
            updateMatParams(udw)
            Log.Debug(MODULE, "OnActorsReady: Called Update Material Effect Parameters")
        end
    end)
    
    -- NOTE: Dynamic Landscape Weather Effects_ and Apply Max to Material Effects
    -- have OUT parameters that cause errors in UE4SS - removed.
    -- The property writes + MSM functions should handle wetness state.
    
    -- Note: Check Point for Puddles Snow Or Dust requires Location/GroundNormal structs - skipped
    
    Log.Info(MODULE, "OnActorsReady: DLWE initialization complete")
    internalState.dlweInitialized = true
    return true
end

--- Called when course unloads
function Wetness.OnCourseUnload()
    internalState.manualOverrideSet = false
    internalState.waterLevelEnabled = false
    internalState.dlweInitialized = false
end

-- Initialize on load
Wetness.Init()

return Wetness
