-- TXR Weather Mod v3.0
-- systems/atmosphere.lua
-- Phase 9: Atmospheric Enhancements (god rays, aurora, cloud shadows)

local Atmosphere = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local GT = require("core.gt")
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
-- nothing to sample; UDS computes intensity happily but nothing renders. The
-- machinery below is kept for a future content-pipeline route. Default off.
local ENABLE_AURORA = false
local ENABLE_SECOND_CLOUD_LAYER = true

-- Aurora timing (TOD values)
local AURORA_NIGHT_START = 1950  -- 19:30, aurora becomes visible
local AURORA_NIGHT_END = 550     -- 05:30, aurora fades out
local AURORA_MAX_INTENSITY = 1.5

-- City glow (Tokyo night ambiance): light pollution lights the cloud bases
-- from below, night sky glow adds a minimum ambient. Ramped on the sun's
-- elevation (season-proof: the drifting in-game date moves the sun events, a
-- clock window aims wrong within days): rises from CityGlowStartElev to full
-- at CityGlowFullElev and holds all night (real city glow does not dim toward
-- midnight). The TOD night window is the fallback when no elevation is
-- available (LightCycle off / first seconds after load).
local ENABLE_CITY_GLOW = true
local LIGHT_POLLUTION_MAX = 1.0   -- peak light-pollution intensity at deep night
local NIGHT_SKY_GLOW_MAX = 0.5    -- peak ambient night-sky glow
local CITY_GLOW_START_ELEV = 0.0  -- glow begins as the sun crosses the horizon
local CITY_GLOW_FULL_ELEV = -8.0  -- full glow by the end of twilight
local LIGHT_POLLUTION_COLOR = {R = 1.00, G = 0.55, B = 0.25, A = 1.0}  -- warm sodium amber
local NIGHT_SKY_GLOW_COLOR  = {R = 0.45, G = 0.50, B = 0.65, A = 1.0}  -- faint cool

-- God rays (sun light-shaft bloom): brightness multiplier on UDS's stock
-- (clear, overcast) pair + a slightly warm tint (Config.Atmosphere overrides)
local SUN_SHAFT_BRIGHTNESS_MULT = 1.0
local SUN_SHAFT_THRESHOLD = {X = 6.0, Y = 2.5}  -- above the sky; stock 1.3/0.35
local SUN_SHAFT_SCALE = {X = 0.15, Y = 0.10}   -- half stock; the extent knob
local SUN_SHAFT_TINT = {R = 1.00, G = 0.92, B = 0.80, A = 1.0}

-- God ray weather gate (2026-07-31). There are no crepuscular rays under a
-- solid deck, but UDS never works that out: Update Low Priority Properties
-- feeds Apply Light Shaft Settings the sun's forward vector and nothing else,
-- and reads the three shaft properties as raw instance variables rather than
-- through Get Cached Float, so they take no part in Change Weather blending
-- either. Result: full-strength streaks under heavy overcast. The mod gates
-- them on its own cloud coverage (clouds_fog, 0-10): full shafts at or below
-- GATE_CLEAR_CLOUD, none at or above GATE_OVERCAST_CLOUD, smoothstep between.
-- A ramp rather than a threshold because UDS blends nothing here: a hard flip
-- would move the whole frame's shaft bloom in one frame while every other
-- weather property eases over 5-10 s, and the input is already smoothed over
-- Config.CloudsFog.PresetTransitionSeconds. Where the defaults land (preset
-- cloudCoverage, systems/presets.lua): Clear_Skies 0.5, Partly_Cloudy 2.0,
-- Sand_Dust_Calm 2.0 and Foggy 3.0 give 1.00; Cloudy 4.0, Sand_Dust_Storm 4.0
-- and Snow_Light 4.0 give 0.65; Rain_Light 5.0 gives 0.10; Snow 5.5, Overcast
-- 6.0, Rain 6.0, Snow_Blizzard 7.0, Overcast_Heavy 7.5 and Rain_Thunderstorm
-- 8.0 give 0.00. Foggy at full is deliberate (rays through haze are real).
-- This disagrees with volumetric_light_rays.lua's DISABLED_PRESETS on purpose:
-- that list gates the dormant Niagara cloud-ray system by preset name. Do not
-- reconcile them.
local ENABLE_GOD_RAY_WEATHER_GATE = true
local GATE_CLEAR_CLOUD = 3.0     -- at or below this: full shafts
local GATE_OVERCAST_CLOUD = 5.5  -- at or above this: no shafts at all

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

-- God rays = the sun's screen-space light-shaft bloom: an enable bool, an
-- FVector2D max-brightness pair and a tint. The pre-3.2.x names ("Use Sun
-- Light Shafts", "Light Shaft Intensity") do not exist in v1.5, so those
-- writes were silent no-ops. UDS fades the shafts with sun occlusion itself.
local PROP_SUN_SHAFT_BLOOM  = "Enable Sun Light Shaft Bloom"
local PROP_SUN_SHAFT_MAX    = "Sun Light Shaft Max Brightness"   -- FVector2D
local PROP_SUN_SHAFT_THRESH = "Sun Light Shaft Bloom Threshold"  -- FVector2D
local PROP_SUN_SHAFT_SCALE  = "Sun Light Shaft Bloom Scale"      -- FVector2D
local PROP_SUN_SHAFT_TINT   = "Sun Light Shaft Tint Color"       -- FLinearColor

-- The pairs interpolate on sun elevation, X = high sun, Y = low sun (bytecode
-- 2026-07-30: Apply Light Shaft Settings gets only the sun's forward vector as
-- selector; cloud cover is not an input, so UDS applies full shafts under
-- heavy overcast; the old "(clear, overcast)" note was wrong). UE light shaft
-- bloom is a screen-space radial blur from the light's screen position with
-- no distance parameter: Max Brightness is the streak intensity ceiling,
-- Bloom Threshold selects the seed pixels (useless as a limiter, an overcast
-- HDR sky sits far above any sane threshold, which is why 0.35 -> 0.7 changed
-- nothing), Bloom Scale is how far the streaks extend (the "rays fire too
-- close to the car" knob). Stock CDO values kept as constants so every write
-- is absolute (Setup runs per course load; scaling off the live value only
-- stays correct while the UDS actor happens to be fresh).
local STOCK_SUN_SHAFT_MAX   = {X = 0.35, Y = 0.25}
local STOCK_SUN_SHAFT_SCALE = {X = 0.30, Y = 0.225}

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

-- Aurora construction gate: the 2D aurora only renders after UDS's aurora
-- Static Properties bake; flipping "Use Auroras" alone never constructs it.
-- Constructed once per course, deferred past BeginPlay like stars/rainbow.
local auroraStaticApplied = false
local auroraSettleTicks = 0

-- In-game verify 2026-07-01: construct + night_on succeeded, nothing rendered.
-- Suspects: the sky material bakes "Aurora Intensity" at static-apply time (the
-- night_on call fired at ~0.02), hence the re-bake as the ramp climbs; and the
-- aurora texture / sky mode, which the diagnostics readback settles from the log.
local lastStaticIntensity = 0.0
local auroraDiagTicks = 0

-- God ray gate state: lastShaftFactor gates the writes, lastShaftLogged the
-- Info line more coarsely (a 10 s ramp is ~40 writes); shaftBaseAsserted
-- covers entry paths that never run Setup; shaftDiagTicks arms the readback.
local lastShaftFactor = nil
local lastShaftLogged = nil
local shaftBaseAsserted = false
local shaftDiagTicks = 0

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

local auroraTexPreloaded = false

--- Push the aurora state and run UDS's own static init for it, on the game thread.
--- Uses the 2D aurora (sky-material shader, same rendering family as the stars,
--- so it composites in TXR) rather than the volumetric one (a whole sky mode).
--- @param reason string logged so the construct / night transitions are traceable
local function applyAuroraStatic(reason)
    lastStaticIntensity = currentAuroraIntensity
    local function doApply()
        local actors = getActors()
        if not actors then return end
        local uds = actors.GetUDS()
        if not uds then return end

        -- Preload the 2D aurora texture (the AURORA_TEXTURE_PATH asset defined
        -- below) so UDS's static apply can resolve its soft-ref
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
        pcall(function() GT.Run(doApply) end)
    else
        doApply()
    end
end

-- Default 2D aurora texture in the UDS 9.5 distribution. The 2D aurora shader
-- samples this via the "Aurora Texture" soft-ref; if TXR's cook stripped it
-- (the cook does strip some UDS assets), the aurora draws nothing.
local AURORA_TEXTURE_PATH = "/Game/UltraDynamicSky/Textures/Clouds/Aurora_Clouds.Aurora_Clouds"

--- One-shot readback of everything that could gate the aurora (2026-07-01 run:
--- writes land, UDS computes 0.89, skyMode 0, still invisible). Also force-loads
--- the texture and re-applies the static properties with it in memory: if UDS's
--- own soft-ref resolve was failing quietly, this is the fix, not just a probe.
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

        -- Texture in memory: re-run the static apply so the soft-ref resolves
        if texWasLoaded or texLoads then
            local fn = nil
            pcall(function() fn = uds[FN_STATIC_AURORA] end)
            if fn then
                pcall(function() fn(uds) end)
                Log.Info(MODULE, "Static Properties - Aurora re-applied after texture preload")
            end
        else
            Log.Warn(MODULE, "Aurora texture NOT in TXR's cook: 2D aurora cannot render", {asset = AURORA_TEXTURE_PATH})
        end
    end

    if ExecuteInGameThread then
        pcall(function() GT.Run(doDiag) end)
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
        -- Morning side: 0 to 550, continuing 0.5 to 1.0 so sin() carries the
        -- midnight peak down to zero at night's end (the old one-minus form
        -- crashed to 0 at the wrap, then rose toward dawn with a hard cut)
        nightDepth = 0.5 + ((tod / AURORA_NIGHT_END) * 0.5)  -- 0.5 to 1.0
    end

    return math.max(0.0, math.sin(nightDepth * math.pi))
end

--- Calculate aurora intensity based on TOD
--- @param tod number
--- @return number 0.0 to AURORA_MAX_INTENSITY
local function calculateAuroraIntensity(tod)
    return nightFactor01(tod) * AURORA_MAX_INTENSITY
end

-- Lazy LightCycle ref for the sun elevation (same pattern as transitions'
-- slow windows; require here would be circular at load time)
local LightCycleMod = nil
local function getLightCycle()
    if not LightCycleMod then
        local ok, mod = pcall(require, "systems.light_cycle")
        if ok then LightCycleMod = mod end
    end
    return LightCycleMod
end

--- City glow factor 0..1: sun elevation when available (0 above
--- CITY_GLOW_START_ELEV, 1 below CITY_GLOW_FULL_ELEV, linear between =
--- a plateau all night), TOD night window as the fallback.
--- @param tod number
--- @return number 0.0 to 1.0
local function cityGlowFactor01(tod)
    local lc = getLightCycle()
    if lc and lc.IsActive and lc.IsActive() then
        local elev = nil
        pcall(function() elev = lc.GetSunElevation() end)
        if type(elev) == "number" then
            if elev >= CITY_GLOW_START_ELEV then return 0.0 end
            if elev <= CITY_GLOW_FULL_ELEV then return 1.0 end
            return (CITY_GLOW_START_ELEV - elev)
                / (CITY_GLOW_START_ELEV - CITY_GLOW_FULL_ELEV)
        end
    end
    return nightFactor01(tod)
end

--- Scale a numeric UDS property from its stock value (read, multiply, write).
--- Setup runs once per course on a fresh sky actor, so this never compounds.
--- Skips silently if the property cannot be read.
local function scaleUDS(propName, mult)
    if not mult or mult == 1.0 then return end
    local old = tonumber(readUDS(propName))
    if old == nil then return end
    writeUDS(propName, old * mult)
end

-- ============== GOD RAY WEATHER GATE ==============

--- Lazy CloudsFog ref (same anti-cycle pattern as getActors).
local CloudsFogMod = nil
local function getCloudsFog()
    if not CloudsFogMod then
        local ok, mod = pcall(require, "systems.clouds_fog")
        if ok then CloudsFogMod = mod end
    end
    return CloudsFogMod
end

--- Cloud coverage the shaft gate rides, 0-10, or nil if nothing is tracked yet.
--- CloudsFog's smoothed value first (it carries the preset ramp, this gate's
--- only smoothing); the preset target second, because CloudsFog.ApplyPreset
--- sets it from inside Weather.Apply, so it exists when Setup runs in the
--- course entry burst while cloudCurrent is still nil (OnCourseUnload nils it,
--- so it cannot be last course's weather). Plain Lua table reads, no UObject.
--- @return number|nil
local function gateCloudCoverage()
    local cf = getCloudsFog()
    if cf and cf.GetSmoothedCloud then
        local v = cf.GetSmoothedCloud()
        if type(v) == "number" then return v end
    end
    if State.GetPresetCloudTarget then
        local t = State.GetPresetCloudTarget()
        if type(t) == "number" then return t end
    end
    return nil
end

--- Shaft strength for a cloud coverage: 1.0 full, 0.0 none, smoothstep between
--- the thresholds. An unknown cloud value returns 1.0 (the pre-gate behaviour),
--- so the gate can never make a boot worse than it was.
--- @param cloud number|nil 0-10
--- @return number 0..1
local function shaftWeatherFactor(cloud)
    if not ENABLE_GOD_RAY_WEATHER_GATE then return 1.0 end
    if type(cloud) ~= "number" then return 1.0 end
    if GATE_OVERCAST_CLOUD <= GATE_CLEAR_CLOUD then
        return (cloud >= GATE_OVERCAST_CLOUD) and 0.0 or 1.0
    end
    local t = (cloud - GATE_CLEAR_CLOUD) / (GATE_OVERCAST_CLOUD - GATE_CLEAR_CLOUD)
    -- Snap near the endpoints: the smoothed input approaches a preset sitting
    -- exactly on a gate edge (Snow = 5.5) asymptotically, which would park the
    -- factor at ~0.01 forever (faint streaks under a closed deck, and Tick's
    -- exact-endpoint write clause could never fire; 2026-08-04).
    if t <= 0.005 then return 1.0 end
    if t >= 0.995 then return 0.0 end
    return 1.0 - (t * t * (3.0 - 2.0 * t))
end

--- The three shaft properties outside the weather gate: enable bool, threshold
--- pair, tint. Not Setup-only: the restored-from-PA branch in main.lua sets
--- initialWeatherApplied without calling Atmosphere.Setup, so a fresh UDS actor
--- would keep the stock bool (false) and UDS would skip Apply Light Shaft
--- Settings, leaving the gate's writes inert on that path. Tick calls this on
--- the first on-course tick of such a course, inside real_sun's 32-tick settle
--- gate, so the bool is in place before the sun bake pushes it to the
--- component. Caller thread: async 8 Hz tick; property writes only, via writeUDS.
local function assertShaftBase()
    writeUDS(PROP_SUN_SHAFT_BLOOM, true)
    if SUN_SHAFT_THRESHOLD then
        writeUDS(PROP_SUN_SHAFT_THRESH, {
            X = SUN_SHAFT_THRESHOLD.X, Y = SUN_SHAFT_THRESHOLD.Y,
        })
    end
    writeUDS(PROP_SUN_SHAFT_TINT, SUN_SHAFT_TINT)
    shaftBaseAsserted = true
    shaftDiagTicks = 80   -- ~10 s at 8 Hz: lands after real_sun's 32-tick bake
end

--- Push the two gated pairs scaled by the weather factor. Absolute writes off
--- the configured base (itself absolute off the CDO stock), never off the live
--- value, so repeat calls are idempotent and a factor back at 1.0 restores full
--- strength exactly. Both knobs scale on purpose: Max Brightness dims the
--- streaks and Bloom Scale retracts them, so at factor 0 both pairs are {0,0}
--- and nothing draws whichever term the shader multiplies. The enable bool is
--- not the off switch: UDS only skips the apply when it is false and never
--- clears the component, so flipping it off would freeze the last streaks on
--- screen. Caller thread: async 8 Hz tick; property writes only, via writeUDS
--- (re-resolves the UDS ref per call). No UFunction, nothing to marshal.
--- @param cloud number|nil for the log only
--- @param factor number 0..1
--- @param reason string "setup", "pa-entry" or "tick"
local function writeSunShafts(cloud, factor, reason)
    local maxX = STOCK_SUN_SHAFT_MAX.X * SUN_SHAFT_BRIGHTNESS_MULT * factor
    local maxY = STOCK_SUN_SHAFT_MAX.Y * SUN_SHAFT_BRIGHTNESS_MULT * factor
    local base = SUN_SHAFT_SCALE or STOCK_SUN_SHAFT_SCALE
    local scaleX = base.X * factor
    local scaleY = base.Y * factor

    writeUDS(PROP_SUN_SHAFT_MAX, {X = maxX, Y = maxY})
    writeUDS(PROP_SUN_SHAFT_SCALE, {X = scaleX, Y = scaleY})
    lastShaftFactor = factor

    -- Info on every non-tick push, on each meaningful step of a ramp, and on
    -- both endpoints exactly. One boot is enough to read the gate off the log.
    local logIt = (reason ~= "tick")
        or (lastShaftLogged == nil)
        or (math.abs(factor - lastShaftLogged) >= 0.15)
        or ((factor <= 0.0 or factor >= 1.0) and factor ~= lastShaftLogged)
    if logIt then
        lastShaftLogged = factor
        Log.Info(MODULE, "God ray weather gate", {
            reason = reason,
            cloud = cloud and string.format("%.2f", cloud) or "n/a",
            factor = string.format("%.3f", factor),
            max = string.format("%.3f/%.3f", maxX, maxY),
            scale = string.format("%.3f/%.3f", scaleX, scaleY),
            window = string.format("%.1f..%.1f", GATE_CLEAR_CLOUD, GATE_OVERCAST_CLOUD),
        })
    end
end

--- One-shot proof that the shaft numbers reach the sun light, ~10 s after the
--- base assert so real_sun's sun bake has run. compEnabled=false here means
--- nothing this module writes can reach the screen (the streaks have another
--- source); pairs reading back as the gated values prove the write path.
--- Marshalled: component reads are UObject touches, which the tick thread must
--- never do; every ref is re-resolved inside the closure.
local function logShaftComponent()
    local function doRead()
        local actors = getActors()
        if not actors then return end
        local uds = actors.GetUDS()
        if not uds then return end
        local comp = nil
        pcall(function() comp = uds["Sun_LightComponent"] end)
        if not comp then
            Log.Warn(MODULE, "Sun_LightComponent not readable: shaft path unverifiable")
            return
        end
        local function rd(p)
            local v = nil
            pcall(function() v = comp[p] end)
            return tostring(v)
        end
        Log.Info(MODULE, "Sun light shaft component readback", {
            compEnabled = rd("bEnableLightShaftBloom"),
            maxBrightness = rd("BloomMaxBrightness"),
            bloomScale = rd("BloomScale"),
            bloomThreshold = rd("BloomThreshold"),
            udsEnable = tostring(readUDS(PROP_SUN_SHAFT_BLOOM)),
        })
    end
    if ExecuteInGameThread then
        pcall(function() GT.Run(doRead) end)
    else
        doRead()
    end
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
            -- Hard clamp at 1.0: star intensity carries (1 minus pollution) in
            -- the sky material (decompiled formula), so anything above 1.0
            -- renders stars as black dots.
            LIGHT_POLLUTION_MAX = math.max(0.0, math.min(1.0, Config.Atmosphere.LightPollutionMax))
        end
        if Config.Atmosphere.NightSkyGlowMax ~= nil then
            NIGHT_SKY_GLOW_MAX = Config.Atmosphere.NightSkyGlowMax
        end
        if type(Config.Atmosphere.CityGlowStartElev) == "number" then
            CITY_GLOW_START_ELEV = Config.Atmosphere.CityGlowStartElev
        end
        if type(Config.Atmosphere.CityGlowFullElev) == "number" then
            CITY_GLOW_FULL_ELEV = Config.Atmosphere.CityGlowFullElev
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
        if Config.Atmosphere.SunShaftBloomThreshold then
            SUN_SHAFT_THRESHOLD = Config.Atmosphere.SunShaftBloomThreshold
        end
        if Config.Atmosphere.SunShaftBloomScale then
            SUN_SHAFT_SCALE = Config.Atmosphere.SunShaftBloomScale
        end
        if Config.Atmosphere.SunShaftTint then
            SUN_SHAFT_TINT = Config.Atmosphere.SunShaftTint
        end
        if Config.Atmosphere.GodRayWeatherGate ~= nil then
            ENABLE_GOD_RAY_WEATHER_GATE = Config.Atmosphere.GodRayWeatherGate
        end
        if type(Config.Atmosphere.GodRayGateClearCloud) == "number" then
            GATE_CLEAR_CLOUD = Config.Atmosphere.GodRayGateClearCloud
        end
        if type(Config.Atmosphere.GodRayGateOvercastCloud) == "number" then
            GATE_OVERCAST_CLOUD = Config.Atmosphere.GodRayGateOvercastCloud
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
    -- tint it warm; UDS drives shaft visibility with sun occlusion. This covers
    -- the first apply of a course; Tick keeps the gate live afterwards and
    -- re-asserts the base on any entry path that skipped this function.
    if ENABLE_GOD_RAYS then
        assertShaftBase()
        local setupCloud = gateCloudCoverage()
        writeSunShafts(setupCloud, shaftWeatherFactor(setupCloud), "setup")
        Log.Info(MODULE, "God rays configured", {
            base_max = string.format("%.3f/%.3f",
                STOCK_SUN_SHAFT_MAX.X * SUN_SHAFT_BRIGHTNESS_MULT,
                STOCK_SUN_SHAFT_MAX.Y * SUN_SHAFT_BRIGHTNESS_MULT),
            base_scale = string.format("%.3f/%.3f",
                (SUN_SHAFT_SCALE or STOCK_SUN_SHAFT_SCALE).X,
                (SUN_SHAFT_SCALE or STOCK_SUN_SHAFT_SCALE).Y),
            thresh = SUN_SHAFT_THRESHOLD and string.format("%.3f/%.3f",
                SUN_SHAFT_THRESHOLD.X, SUN_SHAFT_THRESHOLD.Y) or "stock",
            stock_scale = string.format("%.3f/%.3f",
                STOCK_SUN_SHAFT_SCALE.X, STOCK_SUN_SHAFT_SCALE.Y),
            gate = ENABLE_GOD_RAY_WEATHER_GATE and string.format("%.1f..%.1f",
                GATE_CLEAR_CLOUD, GATE_OVERCAST_CLOUD) or "off",
        })
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
        -- Drop the shaft state too: the next course has a fresh UDS actor at
        -- stock values, and the restored-from-PA path skips Setup.
        lastShaftFactor = nil
        lastShaftLogged = nil
        shaftBaseAsserted = false
        shaftDiagTicks = 0
        return
    end

    -- Don't run during PA
    if State.IsPAFrozen and State.IsPAFrozen() then return end

    -- God ray weather gate, above the time-of-day guards on purpose: it has
    -- nothing to do with the clock, and a nil TOD must not strand the shafts at
    -- their last strength (the course and PA guards upstream keep teardown
    -- gating unchanged). Thread: async 8 Hz loop; gateCloudCoverage reads Lua
    -- state and the writes go through writeUDS (re-resolves the actor per
    -- call), like the city-glow drive below. logShaftComponent, the one call
    -- that touches component objects, marshals.
    if ENABLE_GOD_RAYS then
        if not shaftBaseAsserted then
            -- Course that never ran Setup (restored from PA): without this the
            -- enable bool is stock false and UDS skips the shaft apply outright.
            assertShaftBase()
            local cloud = gateCloudCoverage()
            writeSunShafts(cloud, shaftWeatherFactor(cloud), "pa-entry")
        elseif ENABLE_GOD_RAY_WEATHER_GATE then
            local cloud = gateCloudCoverage()
            local factor = shaftWeatherFactor(cloud)
            -- Write on a real move, and always land the endpoints exactly so a
            -- ramp cannot stop at 0.008 and leave faint streaks under a deck.
            local moved = (lastShaftFactor == nil)
                or (math.abs(factor - lastShaftFactor) > 0.01)
                or ((factor <= 0.0 or factor >= 1.0) and factor ~= lastShaftFactor)
            if moved then
                writeSunShafts(cloud, factor, "tick")
            end
        end
        if shaftDiagTicks > 0 then
            shaftDiagTicks = shaftDiagTicks - 1
            if shaftDiagTicks == 0 then logShaftComponent() end
        end
    end
    
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
            -- If the material bakes intensity at static-apply time the night_on
            -- call was at ~0.02; re-bake as the ramp climbs (a couple of calls).
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

    -- City glow: light pollution + night sky glow, ramped on sun elevation
    -- (TOD-window fallback inside cityGlowFactor01)
    if ENABLE_CITY_GLOW then
        local nightF = cityGlowFactor01(currentTOD)
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

--- Live city glow factor 0..1 (smoothed). stars.lua scales the star
--- intensity on it: the glow lifts the night-sky background and undimmed
--- stars read as dark holes against it.
--- @return number
function Atmosphere.GetCityGlowFactor()
    return currentCityGlow
end

--- Live night-sky-glow nudge (Alt+K family). Field model 2026-07-18: the star
--- layer's rendered luminance clamps below a glow-lifted sky (no star lever
--- can out-bright it; color multipliers only promote fainter map stars), so
--- star visibility is won by lowering this background. The Tick change gate
--- pushes the new level on the next pass.
--- @param dir number +1 = more glow (fewer stars), -1 = less glow (stars cut through)
function Atmosphere.NudgeNightGlow(dir)
    local new = NIGHT_SKY_GLOW_MAX + dir * 0.1
    if new < 0.0 then new = 0.0 end
    if new > 3.0 then new = 3.0 end
    if new == NIGHT_SKY_GLOW_MAX then return end
    NIGHT_SKY_GLOW_MAX = new
    Log.Info("StarTune", "NUDGE night sky glow " .. (dir > 0 and "+" or "-"), {
        max = string.format("%.2f", new),
        applied_now = string.format("%.2f", currentCityGlow * new),
    })
end

return Atmosphere
