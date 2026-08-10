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
local lastApplyClock = 0.0  -- os.clock() of the last Weather.Apply (stars burst pacing)

-- Pending rain activation for retry after map load
local pendingRainActivation = false
local pendingRainRetryCount = 0
-- ~30 s at the 125 ms tick, was 50 (~6 s). UDW soft-references its Niagara
-- content, so the Rain Particles component carries RainParticlesAsset=nil until
-- an ASYNC load lands: measured 2026-07-30 as nil at the first apply and
-- populated with /Game/UltraDynamicSky/Particles/Rain 47 s later. Our scan
-- identifies the component BY that asset name, so for the whole load window
-- there is nothing for it to find and a 6 s budget always ended in "retries
-- exhausted".
-- READ activatedCount CORRECTLY: it counts what OUR scan activated, NOT whether
-- rain is on screen. UDW drives its own particles perfectly well without us, and
-- rain is confirmed to appear instantly when a wet preset is restored at course
-- load while this still logs 0. So this retry is a safety net for the case where
-- our activation is actually needed, not the mechanism that makes rain work.
-- Hence 240 rather than a full minute: it covers the measured ~15 s load with
-- margin while bounding the churn, since each retry is a FindAllOf (cheap on the
-- async tick, ruinous on the game thread, per the standing rule).
-- The same async load is why audio's MAX_LOAD_FAILS must stay at 30.
local MAX_RAIN_RETRIES = 240

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

-- ============== CCC WARMUP HOOK (VERBATIM PORT, DO NOT "IMPROVE") ==============
-- Ported AS-IS from CoolConsoleCommands Scripts/main.lua:141-173, which is the
-- version known to work in the field over hundreds of boots. Same hook, same
-- call order, same FindFirstOf lookup, same absence of marshalling: a
-- RegisterHook callback on a UFunction already runs on the game thread, so
-- adding ExecuteInGameThread here would change the timing, and timing is the
-- whole point.
-- DO NOT refactor this into the mod's Actors/teardown idioms. An adapted
-- version that ran the same six calls from the course-load path did NOT fix
-- rain; the hook point is evidently part of why CCC's works.
-- Only omission: CCC's "GlobalAr = nil", which is its own console-output state
-- and nothing to do with the warmup.
local warmupHookRegistered = false
-- ONCE PER UDW INSTANCE (2026-08-07 crash, PA-exit course entry):
-- ClientRestart fires REPEATEDLY (3x within 5s of course entry, plus
-- mid-drive respawns), and every fire re-ran the full warmup + the
-- Enable*Particles=true writes. The 02:35:56 fire re-enabled particles
-- AFTER the dry course apply, and the 02:35:59 fire then ran Warm Up
-- Niagara Systems / Make * Component under those live components = the
-- recorded ClientRestart AV class (hard fault, no crash report, UE4SS.log
-- truncated mid "UDW warmed up" line). The warmup's entire purpose is
-- building a fresh UDW's components before the first apply; repeat fires
-- on the SAME instance add nothing and carry the whole risk, so each
-- instance is warmed once. Keyed by object address (tostring; the
-- meshVerdict idiom - 400+ discoveries in the logs, zero address reuse)
-- and cleared on map teardown, so the key can never outlive its world.
-- IF RAIN EVER FAILS AT COURSE ENTRY AFTER THIS: first suspect is a
-- needed repeat fire being eaten here; the fix direction stays the
-- handoff's particle-liveness-gated warmup, not unlatching.
local warmedUdwKey = nil
-- Post-warm lookup throttle clock (2026-08-10): see the hook body.
local lastWarmupLookup = 0.0

local function withUDW(func)
    local udw = FindFirstOf("BP_CourseWeather_C") or FindFirstOf("Ultra_Dynamic_Weather_C")
    if not (udw and udw:IsValid()) then return end
    pcall(func, udw)
end

local function registerWarmupHook()
    if warmupHookRegistered then return end
    if not RegisterHook then
        Log.Warn(MODULE, "RegisterHook unavailable: CCC warmup hook not installed")
        return
    end
    warmupHookRegistered = true
    -- pcall guards the REGISTRATION only (a RegisterHook throw at require
    -- time would nil the whole module through safeRequire); the hook body
    -- below stays the verbatim port.
    local ok, err = pcall(RegisterHook, "/Script/Engine.PlayerController:ClientRestart", function(self, NewPawn)
        if not self or not self:get() then return end

        -- FIRST, before the throttle can skip: this fire may mean the
        -- weather cluster was just rebuilt (mid-course UDW churn, the
        -- 2026-08-10 20:14 crash). Flush every cache that could hold the
        -- old cluster's corpses; see Weather._FlushClusterCaches.
        if Weather._FlushClusterCaches then Weather._FlushClusterCaches() end

        -- Post-warm lookup throttle (2026-08-10): withUDW's FindFirstOf
        -- pair is a full object-array walk ON THE GAME THREAD under this
        -- hook, and the once-per-instance latch sits INSIDE withUDW, so
        -- every mid-drive refire still paid the walk for nothing. Once
        -- this world's UDW is warmed, allow the lookup at most every 30s:
        -- a mid-course UDW rebuild (never observed in the logs) still
        -- gets warmed within one window, and OnMapTeardown clears the
        -- latch so a fresh world is never throttled. The hook point and
        -- warmup body below stay the verbatim CCC port.
        if warmedUdwKey ~= nil then
            local nowClock = os.clock()
            if (nowClock - lastWarmupLookup) < 30.0 then return end
            lastWarmupLookup = nowClock
        end

        withUDW(function(udw)
            -- Once per instance (see warmedUdwKey above): repeat fires on
            -- an already-warmed UDW are the crash vector, not a warmup.
            local key = tostring(udw)
            if key == warmedUdwKey then return end

            local function safeCall(name)
                if udw[name] then
                    pcall(function() udw[name](udw) end)
                end
            end

            safeCall("Construct All Weather State Objects")
            safeCall("Weather Startup Functions")
            safeCall("Warm Up Niagara Systems")
            safeCall("Make Rain Component")
            safeCall("Make Snow Component")
            safeCall("Make Dust Component")

            udw["Enable Rain Particles"] = true
            udw["Enable Snow Particles"] = true
            udw["Enable Dust Particles"] = true
            udw["Warm Up Weather Particles On Begin Play"] = true

            warmedUdwKey = key
            Log.Info(MODULE, "UDW warmed up (CCC ClientRestart hook)", {udw = key})
        end)
    end)
    if not ok then
        warmupHookRegistered = false
        Log.Warn(MODULE, "CCC warmup hook registration failed", {err = tostring(err)})
        return
    end
    Log.Info(MODULE, "CCC warmup hook registered (PlayerController:ClientRestart)")
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
    -- Install CCC's ClientRestart warmup hook (see the verbatim port above).
    -- Registered once per session, not per course: RegisterHook is global.
    registerWarmupHook()
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
    -- Timestamp for consumers that pace around weather churn (stars.lua
    -- post-apply burst: transitions re-push sky-material params
    -- unconditionally, 2026-07-23)
    lastApplyClock = os.clock()

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

            -- Per-preset sky grade (cool/grey overcast + rain; nil grade =
            -- back to the session baseline). CinematicSky owns those props.
            pcall(function()
                local CSky = require("systems.cinematic_sky")
                if CSky and CSky.ApplyWeatherGrade then
                    CSky.ApplyWeatherGrade(presetData.skyGrade)
                end
            end)
            
            -- Apply wetness settings via Wetness module (Phase 6)
            local Wetness = nil
            pcall(function()
                Wetness = require("systems.wetness")
            end)
            if Wetness and Wetness.ApplyFromPreset then
                Wetness.ApplyFromPreset(presetData)
            end

            -- God-ray plausibility gate (2026-07-28): sun shafts are forced
            -- off under solid decks/fog/rain; the module re-applies on its
            -- own GT path only when the blocked state actually changes
            pcall(function()
                local LR = require("systems.volumetric_light_rays")
                if LR and LR.OnWeatherChange then
                    LR.OnWeatherChange(presetName)
                end
            end)

            -- Rain collision v8 (2026-07-28): a flip to a wet preset
            -- requests an immediate world pass so rain never falls through
            -- art meshes while the periodic cadence winds up
            pcall(function()
                local RC = require("systems.rain_collision")
                if RC and RC.OnWeatherChange then
                    RC.OnWeatherChange(presetName)
                end
            end)
            
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
                    -- Construct All Weather State Objects FIRST (the CCC
                    -- method, 2026-07-30): UDW builds its weather state
                    -- objects lazily and the spawn-rate formula reads Local
                    -- Weather State.Rain. The decompiled body (reference\
                    -- udwdig\fns\udw\43) is six "Construct Weather State
                    -- Object IF INVALID" calls: idempotent, and not the CCC
                    -- crash vector (that AV came from ClientRestart restarting
                    -- the whole client under live particles). The order is
                    -- load-bearing: Construct, then Startup/WarmUp, then the
                    -- Make * Component calls, matching both warmup paths
                    -- (reordered here 2026-08-04, code review).
                    local constructStates = nil
                    pcall(function()
                        constructStates = udw["Construct All Weather State Objects"]
                    end)
                    if constructStates then
                        local ok, err = pcall(function() constructStates(udw) end)
                        Log.Info(MODULE, "Weather state objects constructed", {ok = ok})
                        if not ok then
                            Log.Warn(MODULE, "Construct All Weather State Objects failed",
                                {error = tostring(err)})
                        end
                    else
                        Log.Warn(MODULE, "Construct All Weather State Objects not found on UDW")
                    end

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
                
                -- (State-object construction moved ABOVE, before the
                -- Startup/Make calls: writing Local Weather State.Rain below
                -- is pointless while the object holding it is still null.)
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
                -- INFO, not Debug (2026-07-30): at Debug these never reach the
                -- log file, so an INFO-level log cannot tell a real activation
                -- from one that silently activated nothing and had its retry
                -- counter reset by the next apply. That is precisely the
                -- ambiguity blocking the "rain only starts after cycling up to
                -- Thunderstorm" diagnosis, so both lines are promoted.
                Log.Info(MODULE, "Direct Niagara activation", {activatedCount = activatedCount})

                -- If activation failed, set pending flag for retry in tick loop
                if activatedCount == 0 then
                    pendingRainActivation = true
                    pendingRainRetryCount = 0
                    Log.Info(MODULE, "Rain activation pending: will retry in tick loop")
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
                -- A wet apply that found 0 components leaves a pending
                -- retry; without this clear the tick loop would re-Activate
                -- the component under THIS dry preset once the async asset
                -- lands, undoing the deactivation below.
                pendingRainActivation = false
                pendingRainRetryCount = 0
                
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
                
                -- Read back the ACTUAL inputs to UDW's rain path (2026-07-30).
                -- Rain Spawn Rate = SelectFloat((Local Weather State.Rain / 10)
                -- ^1.7 * Rain Particle Spawn Count, 0, Enable Rain Particles),
                -- so the three actor properties this used to print say almost
                -- nothing: the formula consumes the STATE OBJECT's Rain, and
                -- nothing renders unless Rain Particles carries the Rain Niagara
                -- asset (which is also the only way our own scan recognises it).
                -- GAME THREAD: Rain Spawn Rate is a UFunction call and Local
                -- Weather State / Manual Weather State / Rain Particles are
                -- UObject touches; all of those AV uncatchably from the async
                -- loop. UDW is re-resolved inside the closure, teardown-gated
                -- first statement. DIAGNOSTIC ONLY: writes nothing, activates
                -- nothing, destroys nothing.
                local rbPreset = presetName
                local rainReadback = function()
                    if Actors.IsDiscoverySuspended and Actors.IsDiscoverySuspended() then return end
                    local u = Actors.GetUDW()
                    if not u then return end
                    local rainVal, enableRain, spawnCnt, updNeeded
                    local lwsRain, manualValid, compValid, compAsset, spawnRate
                    pcall(function() rainVal = u["Rain"] end)
                    pcall(function() enableRain = u["Enable Rain Particles"] end)
                    pcall(function() spawnCnt = u["Rain Particle Spawn Count"] end)
                    pcall(function() updNeeded = u["Rain Update Needed"] end)
                    pcall(function()
                        local lws = u["Local Weather State"]
                        if lws and lws:IsValid() then lwsRain = lws["Rain"] end
                    end)
                    pcall(function()
                        local mws = u["Manual Weather State"]
                        manualValid = (mws ~= nil and mws:IsValid()) and true or false
                    end)
                    pcall(function()
                        local comp = u["Rain Particles"]
                        if comp and comp:IsValid() then
                            compValid = true
                            local a = comp.Asset
                            if a and a:IsValid() then compAsset = a:GetFullName() end
                        else
                            compValid = false
                        end
                    end)
                    pcall(function()
                        local fn = u["Rain Spawn Rate"]
                        if fn then
                            local r = fn(u)
                            if type(r) == "table" then r = r.ReturnValue end
                            spawnRate = r
                        end
                    end)
                    Log.Info(MODULE, "Rain readback", {
                        preset = rbPreset,
                        Rain = tostring(rainVal),
                        EnableRainParticles = tostring(enableRain),
                        SpawnCount = tostring(spawnCnt),
                        RainSpawnRate = tostring(spawnRate),
                        RainUpdateNeeded = tostring(updNeeded),
                        LocalWeatherStateRain = tostring(lwsRain),
                        ManualStateValid = tostring(manualValid),
                        RainParticlesValid = tostring(compValid),
                        RainParticlesAsset = compAsset or "nil",
                    })
                end
                if ExecuteInGameThread then
                    pcall(function() ExecuteInGameThread(rainReadback) end)
                else
                    Log.Warn(MODULE, "No ExecuteInGameThread: skipping rain readback")
                end
            end
        end
        
        Log.Info(MODULE, "Weather change initiated", {
            preset = presetName,
            displayName = Presets.GetDisplayName(presetName),
            isDry = Presets.IsDry(presetName)
        })
        
        -- IMMEDIATELY save state after weather change (so PA entry has correct
        -- preset). COURSE ONLY (2026-08-08, THE PA-TIME CORRUPTION, field-
        -- traced): applyPAState applies the preset BEFORE writing the carried
        -- TOD (that order is load-bearing, 2026-07-15), so in the PA this
        -- save read the UDS while it still held the canned 1950 and stamped
        -- it into last_state.txt. The carry then fixed the UDS but never the
        -- file; no autosave runs off-course and the PA-exit save leg is dead
        -- by teardown (actors invalid = IsInPAScene false), so the next
        -- course entry restored 1950. Every "PA time doesn't match" report
        -- back to 07-16 fits this: the mid-visit re-can was a red herring,
        -- the FILE is how 1950 escaped the PA. Off-course there is nothing
        -- worth writing: the course-unload capture already saved the truth.
        pcall(function()
            local ActorsMod = require("systems.actors")
            if not (ActorsMod and ActorsMod.IsOnCourse and ActorsMod.IsOnCourse()) then
                return
            end
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

--- os.clock() of the last Weather.Apply. Consumers pace around weather
--- churn (weather transitions re-push sky-material params; stars.lua runs
--- its re-assert burst for a few seconds after every apply).
function Weather.GetLastApplyClock()
    return lastApplyClock
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

    -- Teardown gate: both branches below sweep live components (the
    -- suppression enforcement and the rain-activation retry are FindAllOf
    -- passes); running them against a dying world is the uncatchable-AV
    -- crash mechanism. Discovery suspension = the teardown window.
    if Actors.IsDiscoverySuspended and Actors.IsDiscoverySuspended() then return end

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

--- THE CCC WARMUP, replicated (2026-07-30). CoolConsoleCommands hooks
--- PlayerController:ClientRestart and runs the block below against UDW; that is
--- the ONLY reason rain ever worked reliably, and disabling CCC on 2026-07-29 is
--- what exposed the bug. Ported verbatim from its main.lua:152-172, in the same
--- order, because the order is load-bearing: the three Construct/Startup/WarmUp
--- calls prepare UDW's state and Niagara systems, and only then can the three
--- Make * Component calls actually build the components and ASSIGN their Niagara
--- assets.
--- "Make Rain Component" is the one that matters. The whole day's symptom was
--- RainParticlesValid=true with RainParticlesAsset=NIL: the component existed
--- but carried no Niagara asset, so our scan (which identifies it BY that asset
--- name) found nothing and rain never rendered until something else incidentally
--- built it, ~38-47 s in. My earlier partial port called only "Construct All
--- Weather State Objects", which is why it changed nothing: the state objects
--- were never the missing piece.
--- CRASH NOTE: the one recorded access violation came from CCC's ClientRestart
--- restarting the whole CLIENT under live rain particles, once in hundreds of
--- boots. This runs at COURSE LOAD, before any weather has been applied and so
--- before any particle exists, which avoids that window by construction rather
--- than by luck.
--- Thread: game thread (these are all UFunctions and UObject writes), teardown
--- gated, UDW re-resolved inside the closure.
function Weather.WarmUpUDW()
    local function warmGT()
        if Actors.IsDiscoverySuspended and Actors.IsDiscoverySuspended() then return end
        local udw = Actors.GetUDW()
        if not udw then
            Log.Warn(MODULE, "UDW warmup skipped: UDW not resolvable yet")
            return
        end
        local trace = {}
        local function safeCall(name)
            local fn = nil
            pcall(function() fn = udw[name] end)
            if not fn then
                trace[#trace + 1] = name .. "=missing"
                return
            end
            local ok = pcall(function() fn(udw) end)
            trace[#trace + 1] = name .. "=" .. tostring(ok)
        end

        safeCall("Construct All Weather State Objects")
        safeCall("Weather Startup Functions")
        safeCall("Warm Up Niagara Systems")
        safeCall("Make Rain Component")
        safeCall("Make Snow Component")
        safeCall("Make Dust Component")

        -- CCC sets these AFTER the calls, so the calls do not depend on them.
        -- The Enable flags are transient here: the first Weather.Apply of the
        -- course re-derives them from the preset, and dry enforcement will clear
        -- them for a dry preset. "Warm Up Weather Particles On Begin Play" is
        -- the persistent one and is the point of setting any of them.
        pcall(function() udw["Enable Rain Particles"] = true end)
        pcall(function() udw["Enable Snow Particles"] = true end)
        pcall(function() udw["Enable Dust Particles"] = true end)
        pcall(function() udw["Warm Up Weather Particles On Begin Play"] = true end)

        Log.Info(MODULE, "UDW warmup (CCC method)", {calls = table.concat(trace, " ")})
    end
    if ExecuteInGameThread then
        pcall(function() ExecuteInGameThread(warmGT) end)
    else
        pcall(warmGT)
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
-- CALLERS (corrected 2026-08-04): keybind handlers run on the GT;
-- Weather.Tick's 1 Hz suppression enforcement calls this from the ASYNC
-- tick behind the same teardown gate as the rain-activation retry, the
-- project's accepted gated-async shape. Dormant in the shipped config
-- (only the retired tunnel rain kill and Alt+J ever set suppression).

--- Find the live precip Niagara components (Rain/Snow by name or asset).
--- Components with a nil/unreadable/invalid Asset are SKIPPED even when
--- the name matches: on cooks where the rain assets never load (a beta
--- tester's non-Steam build), UDW churns short-lived assetless rain
--- components, and the one time a scan caught one alive and touched its
--- render state the game died the same second (2026-07-16 log, the only
--- components=1 restore of that session). Real precip components always
--- carry a valid Niagara asset, so healthy installs are unaffected; the
--- skipped count rides the suppress/restore log lines as the regression
--- flag.
--- @return table found, table names, number skippedAssetless
local function findPrecipComponents()
    local found, names, skipped = {}, {}, 0
    pcall(function()
        local comps = FindAllOf("NiagaraComponent")
        if not comps then return end
        for _, comp in ipairs(comps) do
            if comp and comp:IsValid() then
                local hit = false
                local n = ""
                pcall(function()
                    n = comp:GetFullName() or ""
                    if n:find("Rain") or n:find("Snow") then hit = true end
                end)
                local assetOk = false
                pcall(function()
                    local asset = comp.Asset
                    if asset and asset:IsValid() then
                        if not hit then
                            local an = asset:GetFullName() or ""
                            if an:find("Rain") or an:find("Snow") then hit = true end
                        end
                        assetOk = true
                    end
                end)
                if hit then
                    if assetOk then
                        found[#found + 1] = comp
                        names[#names + 1] = n:match("([^%.:%s]+)$") or "?"
                    else
                        skipped = skipped + 1
                    end
                end
            end
        end
    end)
    return found, names, skipped
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
--- @return number hidden, table names, number skippedAssetless
function Weather._SuppressKill()
    local comps, names, skipped = findPrecipComponents()
    suppressedComps = comps
    local n = 0
    for _, comp in ipairs(comps) do
        local ok = pcall(function() comp:SetHiddenInGame(true, true) end)
        if ok then n = n + 1 end
    end
    return n, names, skipped
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
        local n, names, skipped = Weather._SuppressKill()
        Log.Info(MODULE, "Precip suppressed (tunnel)", {
            components = n, mode = "hidden",
            names = (#names > 0) and table.concat(names, " ") or nil,
            skipped_assetless = (skipped > 0) and skipped or nil,
        })
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
        local freshList, freshNames, skipped = findPrecipComponents()
        unhideList(freshList)
        unhideList(suppressedComps)
        suppressedComps = nil
        Log.Info(MODULE, "Precip restored (tunnel exit)", {
            components = n,
            names = (#freshNames > 0) and table.concat(freshNames, " ") or nil,
            skipped_assetless = (skipped > 0) and skipped or nil,
        })
    end
end

--- @return boolean
function Weather.IsPrecipSuppressed()
    return precipSuppressed
end

--- Map teardown (main.lua LoadMapPreHook): drop the suppression STATE
--- without touching the components. They die with their world, and the new
--- world's components spawn unhidden, so a state-only clear is the correct
--- restore here; an unhide pass instead would poke freed old-world refs on
--- the next Weather.Apply (IsValid can falsely pass on freed memory; the
--- 2026-07-14 PA-crash class).
--- Weather-cluster churn flush (2026-08-10, the 20:14:28 crash): called
--- from the ClientRestart hook on EVERY fire, before the warmup throttle
--- can skip. The game rebuilds the weather cluster mid-course; the old
--- UDW's rain components die with it while suppressedComps and the State
--- actor cache still hold them, and an IsValid on those corpses is the
--- +0x0C AV (this build's IsValid dereferences before checking liveness;
--- fixed upstream in RE-UE4SS PR #1031, which our pinned build predates
--- by nine days). Pure Lua drops; everything re-derives fresh: the
--- suppression enforcement rescans within 1s and re-kills new particle
--- components, and actor discovery re-finds within ~1s. Defined down
--- here so suppressedComps is lexically in scope (the hook body reaches
--- it through the Weather table at call time, the ppWatchTick idiom).
function Weather._FlushClusterCaches()
    suppressedComps = nil
    pcall(function() Actors.OnWeatherClusterChurn() end)
end

function Weather.OnMapTeardown()
    if precipSuppressed or suppressedComps then
        Log.Info(MODULE, "Suppression state dropped (map teardown)")
    end
    precipSuppressed = false
    suppressedComps = nil
    -- The retry belongs to the world that set it; a wet flag surviving
    -- into the next world's dry restore would re-activate rain there.
    pendingRainActivation = false
    pendingRainRetryCount = 0
    -- The warmup latch belongs to its world too: cleared here so the next
    -- world's first ClientRestart fire always warms its fresh UDW (and the
    -- address key can never alias across worlds).
    warmedUdwKey = nil
    -- Asset cache entries are per-world lookups. The old ClearCache-on-
    -- EndPlay path never actually fired (fallback hooks removed
    -- 2026-08-10), so the wipe lives here with the rest of the world
    -- state.
    assetCache = {}
end

-- Initialize on load
Weather.Init()

return Weather
