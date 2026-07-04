-- TXR Weather Mod v3.0
-- systems/atmosphere.lua
-- Phase 9: Atmospheric Enhancements (god rays, aurora, cloud shadows)

local Atmosphere = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")
local Config = require("config")

-- Lazy-load to avoid circular dependencies
local Actors = nil
local TimeOfDay = nil

local MODULE = "Atmosphere"

-- ============== CONFIGURATION ==============
-- Feature toggles (can be overridden in Config.Atmosphere)
local ENABLE_CLOUD_SHADOWS = true
local ENABLE_GOD_RAYS = true
-- Auroras are a confirmed dead end in TXR: the Aurora_Clouds texture is not in
-- the game's cook (runtime StaticLoadObject fails), so the 2D aurora shader has
-- nothing to sample - UDS computes intensity happily but nothing renders. The
-- machinery below is kept for a future content-pipeline route. Default OFF.
local ENABLE_AURORA = false
local ENABLE_SECOND_CLOUD_LAYER = true

-- Aurora timing (TOD values)
local AURORA_NIGHT_START = 1950  -- 19:30 - aurora becomes visible
local AURORA_NIGHT_END = 550     -- 05:30 - aurora fades out
local AURORA_MAX_INTENSITY = 1.5

-- City glow (Tokyo night ambiance): light pollution + night sky glow, ramped in
-- at night on the same window as the aurora. Light pollution lights the cloud
-- bases from below; night sky glow adds a minimum ambient to the night sky.
local ENABLE_CITY_GLOW = true
local LIGHT_POLLUTION_MAX = 1.0   -- peak light-pollution intensity at deep night
local NIGHT_SKY_GLOW_MAX = 0.5    -- peak ambient night-sky glow
local LIGHT_POLLUTION_COLOR = {R = 1.00, G = 0.55, B = 0.25, A = 1.0}  -- warm sodium amber
local NIGHT_SKY_GLOW_COLOR  = {R = 0.45, G = 0.50, B = 0.65, A = 1.0}  -- faint cool

-- God rays (sun light-shaft bloom): brightness multiplier on UDS's stock
-- (clear, overcast) pair + a slightly warm tint (Config.Atmosphere overrides)
local SUN_SHAFT_BRIGHTNESS_MULT = 1.3
local SUN_SHAFT_TINT = {R = 1.00, G = 0.92, B = 0.80, A = 1.0}

-- Cloud shadows intensity + softness (softness scaled from stock for soft
-- dappled light instead of hard-edged blotches)
local CLOUD_SHADOWS_SUNNY = 0.7
local CLOUD_SHADOWS_OVERCAST = 0.3
local CLOUD_SHADOW_SOFTNESS_MULT = 1.3

-- Smoothing
local SMOOTHING_SPEED = 0.1  -- How fast to interpolate (0-1 per tick)

-- ============== UDS PROPERTY NAMES ==============
-- Aurora
local PROP_USE_AURORAS = "Use Auroras"
local PROP_AURORA_INTENSITY = "Aurora Intensity"
local PROP_AURORA_SPEED = "Aurora Speed"
local PROP_USING_VOLUMETRIC_AURORA = "Using Volumetric Aurora"
local FN_STATIC_AURORA = "Static Properties - Aurora"
local AURORA_SETTLE_TICKS = 32  -- ~4s at 8 Hz past BeginPlay before constructing

-- Cloud Shadows
local PROP_USE_CLOUD_SHADOWS = "Use Cloud Shadows"
local PROP_CLOUD_SHADOWS_INTENSITY_SUNNY = "Cloud Shadows Intensity When Sunny"
local PROP_CLOUD_SHADOWS_INTENSITY_OVERCAST = "Cloud Shadows Intensity When Overcast"
local PROP_CLOUD_SHADOWS_SOFTNESS_SUNNY = "Cloud Shadows Softness When Sunny"
local PROP_CLOUD_SHADOWS_SOFTNESS_OVERCAST = "Cloud Shadows Softness When Overcast"

-- God rays = the sun's screen-space light-shaft bloom. The names this module
-- used before 3.2.x ("Use Sun Light Shafts" / "Light Shaft Intensity") do NOT
-- exist in v1.5's UDS - those writes were silent no-ops. The real controls are
-- an enable bool, a (clear, overcast) FVector2D max-brightness pair, and a tint.
-- UDS fades the shafts with sun occlusion itself, so no per-tick drive is needed.
local PROP_SUN_SHAFT_BLOOM = "Enable Sun Light Shaft Bloom"
local PROP_SUN_SHAFT_MAX   = "Sun Light Shaft Max Brightness"  -- FVector2D
local PROP_SUN_SHAFT_TINT  = "Sun Light Shaft Tint Color"      -- FLinearColor

-- Second Cloud Layer ("Two Layers" is the real v1.5 property; the old
-- "Use Second Cloud Layer" name did not exist, so the enable was a silent no-op)
local PROP_TWO_LAYERS = "Two Layers"

-- City glow (light pollution + night sky glow)
local PROP_LIGHT_POLLUTION_INTENSITY = "Light Pollution Intensity"
local PROP_LIGHT_POLLUTION_COLOR     = "Light Pollution Color"
local PROP_NIGHT_SKY_GLOW            = "Night Sky Glow"
local PROP_NIGHT_SKY_GLOW_COLOR      = "Night Sky Glow Color"

-- ============== STATE ==============
local isInitialized = false
local currentAuroraIntensity = 0.0
local targetAuroraIntensity = 0.0

-- Cache what we last pushed to UDS so we can skip redundant per-tick writes
-- (and avoid reading "Use Auroras" back every tick).
local auroraOn = false
local lastAuroraWritten = nil

-- Aurora construction gate: the 2D aurora only renders after UDS's
-- "Static Properties - Aurora" has baked it into the sky material. Just flipping
-- "Use Auroras" (what this module did originally) never constructs it, which is
-- why auroras silently failed to show. Constructed once per course, deferred
-- past BeginPlay like the stars/nebula/rainbow modules.
local auroraStaticApplied = false
local auroraSettleTicks = 0

-- In-game verify 2026-07-01: construct + night_on both succeeded but nothing
-- rendered. Two suspects: (a) the sky material bakes "Aurora Intensity" at
-- static-apply time (the night_on call fired at ~0.02, i.e. invisible), so we
-- now re-bake as the ramp climbs; (b) the aurora texture / sky mode - the
-- diagnostics readback below settles that from the log.
local lastStaticIntensity = 0.0
local auroraDiagTicks = 0

-- City glow ramp state
local currentCityGlow = 0.0
local lastLightPollutionWritten = nil
local lastNightSkyGlowWritten = nil

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

--- Read UDS property
local function readUDS(propName)
    local actors = getActors()
    if not actors then return nil end
    
    local uds = actors.GetUDS()
    if not uds then return nil end
    
    local value = nil
    pcall(function()
        value = uds[propName]
    end)
    return value
end

--- Write UDS property
local function writeUDS(propName, value)
    local actors = getActors()
    if not actors then return false end
    
    local uds = actors.GetUDS()
    if not uds then return false end
    
    local ok = pcall(function()
        uds[propName] = value
    end)
    return ok
end

--- Push the aurora state and run UDS's own static init for it, on the game thread.
--- Uses the 2D aurora (sky-material shader, same rendering family as the stars,
--- so it composites in TXR) rather than the volumetric one (a whole sky mode).
--- @param reason string logged so the construct / night transitions are traceable
local auroraTexPreloaded = false

local function applyAuroraStatic(reason)
    lastStaticIntensity = currentAuroraIntensity
    local function doApply()
        local actors = getActors()
        if not actors then return end
        local uds = actors.GetUDS()
        if not uds then return end

        -- Make sure the 2D aurora texture is in memory before UDS's static
        -- apply tries to resolve its soft-ref (defined below, near the
        -- diagnostics that test whether it is cooked at all)
        if not auroraTexPreloaded then
            auroraTexPreloaded = true
            pcall(function() StaticLoadObject(nil, nil, "/Game/UltraDynamicSky/Textures/Clouds/Aurora_Clouds.Aurora_Clouds") end)
        end

        pcall(function() uds[PROP_USING_VOLUMETRIC_AURORA] = false end)
        pcall(function() uds[PROP_USE_AURORAS] = true end)
        pcall(function() uds[PROP_AURORA_SPEED] = 0.15 end)
        pcall(function() uds[PROP_AURORA_INTENSITY] = currentAuroraIntensity end)

        local fn = nil
        pcall(function() fn = uds[FN_STATIC_AURORA] end)
        if fn then
            local ok, err = pcall(function() fn(uds) end)
            if ok then
                Log.Info(MODULE, "Static Properties - Aurora called", {reason = reason})
            else
                Log.Warn(MODULE, "Static Properties - Aurora failed", {error = tostring(err)})
            end
        else
            Log.Warn(MODULE, "Static Properties - Aurora function not found")
        end
    end

    if ExecuteInGameThread then
        pcall(function() ExecuteInGameThread(doApply) end)
    else
        doApply()
    end
end

-- Default 2D aurora texture in the UDS 9.5 distribution. The 2D aurora shader
-- samples this via the "Aurora Texture" soft-ref; if TXR's cook stripped it
-- (the cook does strip some UDS assets), the aurora draws nothing.
local AURORA_TEXTURE_PATH = "/Game/UltraDynamicSky/Textures/Clouds/Aurora_Clouds.Aurora_Clouds"

--- One-shot readback of everything that could gate the aurora, for the log
--- (2026-07-01 run: writes land, UDS computes 0.89, skyMode 0, still invisible).
--- Now also force-loads the aurora texture: if the load succeeds, re-apply the
--- static properties with the texture guaranteed in memory - if UDS's own
--- soft-ref resolve was failing quietly, this IS the fix, not just a probe.
local function logAuroraDiagnostics()
    local function doDiag()
        local actors = getActors()
        if not actors then return end
        local uds = actors.GetUDS()
        if not uds then return end

        local useAur, usingVol, intens, curIntens
        pcall(function() useAur = uds[PROP_USE_AURORAS] end)
        pcall(function() usingVol = uds[PROP_USING_VOLUMETRIC_AURORA] end)
        pcall(function() intens = uds[PROP_AURORA_INTENSITY] end)
        pcall(function()
            local fn = uds["Current Aurora Intensity"]
            if fn then curIntens = fn(uds) end
        end)

        -- Texture cook test: find-in-memory first, then force a sync load
        local texWasLoaded, texLoads = false, false
        pcall(function()
            local t = StaticFindObject(AURORA_TEXTURE_PATH)
            texWasLoaded = (t ~= nil) and t.IsValid and t:IsValid()
        end)
        if not texWasLoaded then
            pcall(function()
                local t = StaticLoadObject(nil, nil, AURORA_TEXTURE_PATH)
                texLoads = (t ~= nil) and t.IsValid and t:IsValid()
            end)
        end

        Log.Info(MODULE, "Aurora diagnostics", {
            useAuroras = tostring(useAur),
            usingVolumetric = tostring(usingVol),
            intensityProp = tostring(intens),
            currentIntensityFn = tostring(curIntens),
            texAlreadyLoaded = tostring(texWasLoaded),
            texForcedLoadOk = tostring(texLoads),
        })

        -- Texture is (now) in memory: re-run UDS's static apply so its
        -- SoftObjectToObject resolve can pick it up this time
        if texWasLoaded or texLoads then
            local fn = nil
            pcall(function() fn = uds[FN_STATIC_AURORA] end)
            if fn then
                pcall(function() fn(uds) end)
                Log.Info(MODULE, "Static Properties - Aurora re-applied after texture preload")
            end
        else
            Log.Warn(MODULE, "Aurora texture NOT in TXR's cook - 2D aurora cannot render", {asset = AURORA_TEXTURE_PATH})
        end
    end

    if ExecuteInGameThread then
        pcall(function() ExecuteInGameThread(doDiag) end)
    else
        doDiag()
    end
end

--- Check if TOD is in night window for aurora
--- @param tod number
--- @return boolean
local function isAuroraNight(tod)
    -- Night wraps around midnight
    return tod >= AURORA_NIGHT_START or tod <= AURORA_NIGHT_END
end

--- Night intensity factor 0..1 (0 in daytime, smooth sine peaking at midnight).
--- Shared by aurora and city glow so they ramp on the same night window.
--- @param tod number
--- @return number 0.0 to 1.0
local function nightFactor01(tod)
    if not isAuroraNight(tod) then
        return 0.0
    end

    local nightDepth
    if tod >= AURORA_NIGHT_START then
        -- Evening side: 1950 to 2400
        nightDepth = ((tod - AURORA_NIGHT_START) / (2400 - AURORA_NIGHT_START)) * 0.5  -- 0 to 0.5
    else
        -- Morning side: 0 to 550
        nightDepth = 1.0 - ((tod / AURORA_NIGHT_END) * 0.5)  -- 1.0 down to 0.5
    end

    return math.max(0.0, math.sin(nightDepth * math.pi))
end

--- Calculate aurora intensity based on TOD
--- @param tod number
--- @return number 0.0 to AURORA_MAX_INTENSITY
local function calculateAuroraIntensity(tod)
    return nightFactor01(tod) * AURORA_MAX_INTENSITY
end

--- Scale a numeric UDS property from its stock value (read -> multiply -> write).
--- Setup runs once per course on a freshly spawned sky actor, so this never
--- compounds. Skips silently if the property can't be read.
local function scaleUDS(propName, mult)
    if not mult or mult == 1.0 then return end
    local old = tonumber(readUDS(propName))
    if old == nil then return end
    writeUDS(propName, old * mult)
end

--- Lerp toward target value
local function smoothStep(current, target, speed)
    local diff = target - current
    if math.abs(diff) < 0.01 then
        return target
    end
    return current + diff * speed
end

-- ============== PUBLIC API ==============

--- Initialize atmosphere module
--- @return boolean success
function Atmosphere.Init()
    if isInitialized then
        Log.Warn(MODULE, "Already initialized")
        return true
    end
    
    Log.Info(MODULE, "Initializing atmosphere module")
    
    -- Read config overrides
    if Config.Atmosphere then
        if Config.Atmosphere.EnableCloudShadows ~= nil then
            ENABLE_CLOUD_SHADOWS = Config.Atmosphere.EnableCloudShadows
        end
        if Config.Atmosphere.EnableGodRays ~= nil then
            ENABLE_GOD_RAYS = Config.Atmosphere.EnableGodRays
        end
        if Config.Atmosphere.EnableAurora ~= nil then
            ENABLE_AURORA = Config.Atmosphere.EnableAurora
        end
        if Config.Atmosphere.EnableSecondCloudLayer ~= nil then
            ENABLE_SECOND_CLOUD_LAYER = Config.Atmosphere.EnableSecondCloudLayer
        end
        if Config.Atmosphere.EnableCityGlow ~= nil then
            ENABLE_CITY_GLOW = Config.Atmosphere.EnableCityGlow
        end
        if Config.Atmosphere.LightPollutionMax ~= nil then
            LIGHT_POLLUTION_MAX = Config.Atmosphere.LightPollutionMax
        end
        if Config.Atmosphere.NightSkyGlowMax ~= nil then
            NIGHT_SKY_GLOW_MAX = Config.Atmosphere.NightSkyGlowMax
        end
        if Config.Atmosphere.LightPollutionColor then
            LIGHT_POLLUTION_COLOR = Config.Atmosphere.LightPollutionColor
        end
        if Config.Atmosphere.NightSkyGlowColor then
            NIGHT_SKY_GLOW_COLOR = Config.Atmosphere.NightSkyGlowColor
        end
        if Config.Atmosphere.SunShaftBrightnessMult ~= nil then
            SUN_SHAFT_BRIGHTNESS_MULT = Config.Atmosphere.SunShaftBrightnessMult
        end
        if Config.Atmosphere.SunShaftTint then
            SUN_SHAFT_TINT = Config.Atmosphere.SunShaftTint
        end
        if Config.Atmosphere.CloudShadowSoftnessMult ~= nil then
            CLOUD_SHADOW_SOFTNESS_MULT = Config.Atmosphere.CloudShadowSoftnessMult
        end
        if Config.Atmosphere.Enabled == false then
            Log.Info(MODULE, "Atmosphere disabled in config")
            isInitialized = true
            return true
        end
    end
    
    isInitialized = true
    State.SetModuleStatus("atmosphere", true)
    
    return true
end

--- Apply initial atmosphere settings (call once when actors ready)
function Atmosphere.Setup()
    local actors = getActors()
    if not actors or not actors.IsOnCourse() then return end
    
    -- Enable cloud shadows (intensity absolute, softness scaled from stock)
    if ENABLE_CLOUD_SHADOWS then
        writeUDS(PROP_USE_CLOUD_SHADOWS, true)
        writeUDS(PROP_CLOUD_SHADOWS_INTENSITY_SUNNY, CLOUD_SHADOWS_SUNNY)
        writeUDS(PROP_CLOUD_SHADOWS_INTENSITY_OVERCAST, CLOUD_SHADOWS_OVERCAST)
        scaleUDS(PROP_CLOUD_SHADOWS_SOFTNESS_SUNNY, CLOUD_SHADOW_SOFTNESS_MULT)
        scaleUDS(PROP_CLOUD_SHADOWS_SOFTNESS_OVERCAST, CLOUD_SHADOW_SOFTNESS_MULT)
        Log.Debug(MODULE, "Cloud shadows enabled")
    end

    -- Enable second cloud layer (high cirrus; real property is "Two Layers")
    if ENABLE_SECOND_CLOUD_LAYER then
        writeUDS(PROP_TWO_LAYERS, true)
        Log.Debug(MODULE, "Second cloud layer (Two Layers) enabled")
    end

    -- God rays: enable the sun's light-shaft bloom, brighten it from stock and
    -- tint it warm. One-shot - UDS drives shaft visibility with sun occlusion.
    if ENABLE_GOD_RAYS then
        writeUDS(PROP_SUN_SHAFT_BLOOM, true)
        local maxB = readUDS(PROP_SUN_SHAFT_MAX)
        if maxB and SUN_SHAFT_BRIGHTNESS_MULT ~= 1.0 then
            local x, y = nil, nil
            pcall(function() x, y = maxB.X, maxB.Y end)
            if x and y then
                writeUDS(PROP_SUN_SHAFT_MAX, {X = x * SUN_SHAFT_BRIGHTNESS_MULT,
                                              Y = y * SUN_SHAFT_BRIGHTNESS_MULT})
            end
        end
        writeUDS(PROP_SUN_SHAFT_TINT, SUN_SHAFT_TINT)
        Log.Debug(MODULE, "God rays (sun light-shaft bloom) enabled")
    end
    
    -- Aurora is constructed after the settle gate in Tick (see applyAuroraStatic);
    -- re-arm the gate here so a fresh course gets a fresh construct.
    if ENABLE_AURORA then
        auroraStaticApplied = false
        auroraSettleTicks = 0
        auroraOn = false
        Log.Debug(MODULE, "Aurora system ready (constructs after settle)")
    end

    -- City glow: set colors once; intensities ramp with night in Tick
    if ENABLE_CITY_GLOW then
        writeUDS(PROP_LIGHT_POLLUTION_COLOR, LIGHT_POLLUTION_COLOR)
        writeUDS(PROP_NIGHT_SKY_GLOW_COLOR, NIGHT_SKY_GLOW_COLOR)
        Log.Debug(MODULE, "City glow colors set")
    end

    -- Force the next tick to push fresh values
    lastAuroraWritten = nil
    lastLightPollutionWritten = nil
    lastNightSkyGlowWritten = nil
    
    Log.Info(MODULE, "Atmosphere setup complete")
end

--- Main tick function
function Atmosphere.Tick()
    if not isInitialized then return end
    if Config.Atmosphere and Config.Atmosphere.Enabled == false then return end
    
    local actors = getActors()
    if not actors or not actors.IsOnCourse() then
        -- Course unloaded: re-arm the aurora construct for the next course
        -- (the PA-exit path skips Setup, so the reset has to live here too)
        auroraStaticApplied = false
        auroraSettleTicks = 0
        auroraOn = false
        lastAuroraWritten = nil
        return
    end

    -- Don't run during PA
    if State.IsPAFrozen and State.IsPAFrozen() then return end
    
    local tod = getTimeOfDay()
    if not tod then return end
    
    local currentTOD = tod.GetCurrentTOD()
    if not currentTOD then return end
    
    -- Update Aurora
    if ENABLE_AURORA then
        targetAuroraIntensity = calculateAuroraIntensity(currentTOD)
        currentAuroraIntensity = smoothStep(currentAuroraIntensity, targetAuroraIntensity, SMOOTHING_SPEED)

        if not auroraStaticApplied then
            -- One-shot construct per course, deferred past the BeginPlay window
            auroraSettleTicks = auroraSettleTicks + 1
            if auroraSettleTicks >= AURORA_SETTLE_TICKS then
                auroraStaticApplied = true
                applyAuroraStatic("construct")
            end
        elseif currentAuroraIntensity > 0.01 then
            -- Use our cached on/off state instead of reading the property back each tick
            if not auroraOn then
                auroraOn = true
                auroraDiagTicks = 64  -- readback diagnostics ~8s after the transition
                applyAuroraStatic("night_on")
                Log.Info(MODULE, "Aurora enabled", {tod = currentTOD})
            end
            -- Only write intensity when it actually moved
            if not lastAuroraWritten or math.abs(currentAuroraIntensity - lastAuroraWritten) > 0.005 then
                writeUDS(PROP_AURORA_INTENSITY, currentAuroraIntensity)
                lastAuroraWritten = currentAuroraIntensity
            end
            -- If the material bakes intensity at static-apply time, the night_on
            -- call happened at ~0.02 (invisible). Re-bake as the ramp climbs
            -- (a couple of extra calls per transition at most).
            if math.abs(currentAuroraIntensity - lastStaticIntensity) > 0.5 then
                applyAuroraStatic("ramp")
            end
            if auroraDiagTicks > 0 then
                auroraDiagTicks = auroraDiagTicks - 1
                if auroraDiagTicks == 0 then
                    logAuroraDiagnostics()
                end
            end
        else
            if auroraOn then
                auroraOn = false
                lastAuroraWritten = nil
                writeUDS(PROP_AURORA_INTENSITY, 0.0)
                applyAuroraStatic("night_off")
                Log.Info(MODULE, "Aurora disabled", {tod = currentTOD})
            end
        end
    end

    -- (God rays are one-shot in Setup now: UDS fades the shaft bloom with sun
    -- occlusion itself, so the old per-tick intensity drive - which wrote a
    -- nonexistent property anyway - is gone.)

    -- City glow: light pollution + night sky glow, ramped in at night
    if ENABLE_CITY_GLOW then
        local nightF = nightFactor01(currentTOD)
        currentCityGlow = smoothStep(currentCityGlow, nightF, SMOOTHING_SPEED)

        local lightPollution = currentCityGlow * LIGHT_POLLUTION_MAX
        local nightGlow = currentCityGlow * NIGHT_SKY_GLOW_MAX

        if not lastLightPollutionWritten or math.abs(lightPollution - lastLightPollutionWritten) > 0.005 then
            writeUDS(PROP_LIGHT_POLLUTION_INTENSITY, lightPollution)
            lastLightPollutionWritten = lightPollution
        end
        if not lastNightSkyGlowWritten or math.abs(nightGlow - lastNightSkyGlowWritten) > 0.005 then
            writeUDS(PROP_NIGHT_SKY_GLOW, nightGlow)
            lastNightSkyGlowWritten = nightGlow
        end
    end
end

--- Get current aurora intensity
--- @return number
function Atmosphere.GetAuroraIntensity()
    return currentAuroraIntensity
end

--- Check if aurora is currently active
--- @return boolean
function Atmosphere.IsAuroraActive()
    return currentAuroraIntensity > 0.01
end

--- Get status for debugging
--- @return table
function Atmosphere.GetStatus()
    return {
        initialized = isInitialized,
        auroraIntensity = currentAuroraIntensity,
        auroraTarget = targetAuroraIntensity,
        auroraConstructed = auroraStaticApplied,
        cloudShadowsEnabled = ENABLE_CLOUD_SHADOWS,
        godRaysEnabled = ENABLE_GOD_RAYS,
        auroraEnabled = ENABLE_AURORA,
        secondCloudLayerEnabled = ENABLE_SECOND_CLOUD_LAYER,
        cityGlowEnabled = ENABLE_CITY_GLOW,
        cityGlow = currentCityGlow,
    }
end

--- Check if module is initialized
--- @return boolean
function Atmosphere.IsInitialized()
    return isInitialized
end

return Atmosphere
