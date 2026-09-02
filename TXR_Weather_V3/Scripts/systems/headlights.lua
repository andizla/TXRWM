-- TXR Weather Mod v3.0
-- systems/headlights.lua
-- Automatic headlight control. V2-style actuation (UEHelpers vehicle
-- discovery, FindAllOf + SetVisibility/SetActive/SetIntensity; the BP-function
-- rewrite regressed). Auto mode keys on the sun's elevation (LightCycle) with
-- hysteresis and falls back to TOD thresholds; mode + brightness level persist
-- to headlight_state.txt across sessions.

local Headlights = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local GT = require("core.gt")
local State = require("core.state")
local Config = require("config")

-- Lazy-load to avoid circular dependencies
local Actors = nil
local TimeOfDay = nil

local MODULE = "Headlights"

-- ============== CONFIGURATION ==============
-- Headlight mode: "auto" | "force_on" | "force_off"
local currentMode = "auto"

-- Auto thresholds on sun elevation (degrees; the primary signal). On at/below
-- ON_ELEV as dusk falls, off at/above OFF_ELEV after dawn; the gap between
-- them is the hysteresis band.
local ON_ELEV = -1.0
local OFF_ELEV = 0.5

-- Forced-on contexts for auto mode (Config.Headlights.AutoOnInTunnel /
-- AutoOnInRain): real bores via the road-data cover (lone overpasses do not
-- count) and wet presets; when the context ends the elevation logic resumes.
local AUTO_ON_TUNNEL = true
local AUTO_ON_RAIN = true

-- TOD thresholds (fallback when no sun elevation is available)
local HEADLIGHT_ON_TOD = 1830   -- Turn on after 18:30 (dusk)
local HEADLIGHT_OFF_TOD = 630   -- Turn off after 06:30 (dawn)

-- Light-button gesture thresholds (seconds), acted on release by hold time:
-- up to GESTURE_TAP_MAX_SEC = headlights on (tap), GESTURE_OFF_HOLD_SEC and
-- longer = off (hold), between = dead zone. Manual mode only. The 125 ms tick
-- caps timing precision, so the windows are wide and a sub-125 ms flick may
-- be missed; that is why off is the hold rather than a strict instant tap.
local GESTURE_TAP_MAX_SEC = 1.0
local GESTURE_OFF_HOLD_SEC = 2.0

-- ============== STATE ==============
local isInitialized = false
local headlightsOn = false
local lastTOD = nil
local lastForcedOn = false   -- effective tunnel/rain forced-ON verdict
local forcedOffSince = nil   -- os.clock when the forced context first read false
local FORCED_OFF_HOLD_S = 2.0
local modeChanged = false

-- Course-entry reconcile: on a fresh course the cached on/off state is unknown
-- and the game's native auto may have enabled a cast-only light, so one assert
-- of the desired state runs after a short settle (sun elevation available).
local entryAssertPending = false
local courseTicks = 0
local ENTRY_SETTLE_TICKS = 16  -- ~2s at 125ms tick (lets the exposure provider produce a signal)

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

-- Original source intensities per light component, keyed by GetFullName. The
-- game recomputes a lamp's live .Intensity from Normal_intensity /
-- hibeam_intensity on every hi-beam or setup event (a multiplier written only
-- to .Intensity is wiped by the next flash), so the multiplier is baked into
-- those props, always from the cached original (never compounds). Cleared per course.
local srcOrig = {}

-- Debounced brightness re-assert after a hi-beam flash: the OffHiBeam recompute
-- runs as the flash ends, so re-apply shortly after release (os.clock deadline).
local brightnessReassertAt = nil

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

-- Exposure provider: LightCycle exposes GetSunElevation, the primary auto
-- signal. (Legacy slot-table exposure module removed 2026-07-12.)
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

--- Check if TOD is in night range (fallback when no sun elevation is available)
--- @param tod number
--- @return boolean
local function isNightTime(tod)
    -- Night wraps around midnight: on after HEADLIGHT_ON_TOD or before HEADLIGHT_OFF_TOD
    return tod >= HEADLIGHT_ON_TOD or tod < HEADLIGHT_OFF_TOD
end

--- Forced-on check for auto mode: tunnel bores (road-data cover only, so
--- overpass shadows do not flash the lights) and wet weather.
--- @return boolean
local function autoForcedOn()
    if AUTO_ON_TUNNEL then
        local ok, T = pcall(require, "systems.tunnels")
        if ok and T and T.IsCovered then
            local okc, cov = pcall(T.IsCovered)
            if okc and cov then return true end
        end
    end
    if AUTO_ON_RAIN then
        local preset = nil
        pcall(function() preset = State.GetCurrentPreset() end)
        if preset then
            local ok, P = pcall(require, "systems.presets")
            if ok and P and P.IsDry then
                local okd, dry = pcall(P.IsDry, preset)
                if okd and dry == false then return true end
            end
        end
    end
    return false
end

--- Auto-mode decision. Primary signal: the sun's elevation (season-proof; the
--- game's date drifts). Tunnel cover and rain force on regardless of the sun;
--- the TOD thresholds are the fallback.
--- @param tod number current time of day (for the last-resort fallback)
--- @return boolean
local function computeAutoDesired(tod, forced)
    if forced == nil then forced = autoForcedOn() end
    if forced then return true end

    local exp = getExposure()

    -- Sun elevation (LightCycle). Hysteresis: ON at/below ON_ELEV, then stay
    -- on until the sun climbs to OFF_ELEV.
    if exp and exp.GetSunElevation then
        local ok, e = pcall(exp.GetSunElevation)
        if ok and type(e) == "number" then
            if headlightsOn then
                return e < OFF_ELEV
            else
                return e <= ON_ELEV
            end
        end
    end

    -- Fallback: TOD thresholds (first seconds of a load, or LightCycle off).
    return isNightTime(tod)
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

--- Safely call a method on UObject (V2 pattern, correct self binding)
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

-- Garage always-on re-assert throttle clock (2026-08-11, see Tick).
local garageEnsureLast = 0.0

--- Read a light component's owning vehicle `is_light_on` flag. Used to gate the
--- world-wide cast light + brightness pass so a car's headlights only render when
--- that car actually has its lights on.
--- @param comp userdata light component
--- @return boolean|nil true/false, or nil if it could not be read (caller falls back)
local function ownerLightsOn(comp)
    local result = nil
    pcall(function()
        if comp.GetOwner then
            local owner = comp:GetOwner()
            if owner then
                local v = owner.is_light_on
                if type(v) == "boolean" then result = v end
            end
        end
    end)
    return result
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

-- Per-course pawn cache: the controller lookup is an uncached FindAllOf in
-- UEHelpers, which ran eight times a second on course. The cached pawn is
-- re-validated on every use and re-resolved every 2 s (a re-possession
-- lands within that); the course edges drop it.
local cachedPawn = nil
local cachedPawnAt = 0.0
local PAWN_REFRESH_S = 2.0
local function getPlayerPawnCached()
    local now = os.clock()
    if cachedPawn and (now - cachedPawnAt) < PAWN_REFRESH_S and isValidActor(cachedPawn) then
        return cachedPawn
    end
    cachedPawn = getPlayerPawn()
    cachedPawnAt = now
    return cachedPawn
end

--- Set vehicle lights using V2's working method calls
--- @param obj userdata Vehicle/Pawn
--- @param on boolean
local function setVehicleLights(obj, on)
    if not isValidActor(obj) then return false end

    local want = on
    local success = false

    -- SetLightOn is the game's input-path toggle and its argument is the RHL
    -- animation flag: SetLightOn(true) flips is_light_on and plays the pop-up
    -- animation (a bare is_light_on write never animates, and the 2-arg
    -- SetLIght setter does not drive the rig). Read the actual state and
    -- toggle only when it differs from want: is_light_on always ends at want,
    -- so the owner-gated visibility below cannot invert, and a real move animates.
    local cur = nil
    pcall(function() local v = obj.is_light_on; if type(v) == "boolean" then cur = v end end)
    local toggled = false
    if cur == nil then
        pcall(function() obj.is_light_on = want end)   -- state unreadable: deterministic write (no anim)
    elseif cur ~= want then
        toggled = safeCallMethod(obj, 'SetLightOn', true)  -- toggle to want and animate the pops
    end
    Log.Debug(MODULE, "Player light setter", {on = want, cur = cur, toggled = toggled})
    success = true
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
                    -- Only light this car's headlight if its own lights are on
                    -- (fall back to the requested state if the owner can't be read).
                    local lit = ownerLightsOn(comp)
                    if lit == nil then lit = want end
                    if comp.SetVisibility then
                        comp:SetVisibility(lit, true)  -- propagate to children
                    end
                    if comp.SetActive then
                        comp:SetActive(lit)
                    end
                    -- Direct intensity control as fallback
                    if lit then
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
                        -- Cast light follows the owning car's light state.
                        local lit = ownerLightsOn(light)
                        if lit == nil then lit = want end
                        if light.SetVisibility then
                            light:SetVisibility(lit, true)
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

-- ============== PERSISTENCE (mode + brightness level) ==============

--- Resolve the mod root folder (same pattern as persistence.lua).
local function getModRoot()
    local info = debug.getinfo(1, "S")
    if info and info.source then
        local source = info.source:gsub("@", "")
        local root = source:match("(.+)[/\\]systems[/\\]") or ""
        if root ~= "" then
            root = root:match("(.+)[/\\]") or root
        end
        return root
    end
    return "."
end

local function getStateFilePath()
    return getModRoot() .. "\\headlight_state.txt"
end

--- Persist the current mode + brightness level so they survive a restart.
local function saveState()
    local ok, f = pcall(io.open, getStateFilePath(), "w")
    if not (ok and f) then return end
    -- pcall the writes and always close: a mid-write io error must neither
    -- leak the handle nor escape to the caller.
    local wok = pcall(function()
        f:write("mode=" .. tostring(currentMode) .. "\n")
        f:write("brightness=" .. tostring(currentBrightnessLevel) .. "\n")
    end)
    pcall(function() f:close() end)
    if wok then
        Log.Debug(MODULE, "Saved headlight state", {mode = currentMode, brightness = currentBrightnessLevel})
    end
end

--- Load the persisted brightness level and manual on/off state. Auto vs manual
--- is config-authoritative, so a persisted mode is restored only when it is a
--- manual state and config is not "auto".
--- @param allowModeOverride boolean true when config mode is manual
local function loadState(allowModeOverride)
    local ok, f = pcall(io.open, getStateFilePath(), "r")
    if not (ok and f) then return end
    -- pcall the read loop and always close: this runs inside Headlights.Init,
    -- and an unhandled read error on a corrupt/locked state file would abort
    -- the whole mod's initialize() (every module after this one included).
    local rok = pcall(function()
        for line in f:lines() do
            local k, v = line:match("^(%w+)=(.+)$")
            if k == "mode" and allowModeOverride and (v == "force_on" or v == "force_off") then
                currentMode = v
            elseif k == "brightness" then
                local n = tonumber(v)
                if n and n >= 1 and n <= #BRIGHTNESS_MULTIPLIERS then
                    currentBrightnessLevel = n
                end
            end
        end
    end)
    pcall(function() f:close() end)
    if rok then
        Log.Info(MODULE, "Loaded headlight state", {mode = currentMode, brightness = currentBrightnessLevel})
    end
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
        if Config.Headlights.OnElev ~= nil then
            ON_ELEV = Config.Headlights.OnElev
        end
        if Config.Headlights.OffElev ~= nil then
            OFF_ELEV = Config.Headlights.OffElev
        end
        if Config.Headlights.AutoOnInTunnel ~= nil then
            AUTO_ON_TUNNEL = Config.Headlights.AutoOnInTunnel
        end
        if Config.Headlights.AutoOnInRain ~= nil then
            AUTO_ON_RAIN = Config.Headlights.AutoOnInRain
        end
        if Config.Headlights.GestureTapMaxSeconds then
            GESTURE_TAP_MAX_SEC = Config.Headlights.GestureTapMaxSeconds
        end
        if Config.Headlights.GestureOffHoldSeconds then
            GESTURE_OFF_HOLD_SEC = Config.Headlights.GestureOffHoldSeconds
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

    -- Restore persisted brightness, and the manual on/off state only when config
    -- is not auto (auto mode is configured in config only, never persisted).
    loadState(currentMode ~= "auto")

    isInitialized = true
    State.SetModuleStatus("headlights", true)

    Log.Info(MODULE, "Headlights initialized", {mode = currentMode})
    return true
end

-- Gesture edge-detector state (used by the hold-gesture block below; declared
-- above OnCourseLoad so its reset there writes these locals, not globals).
local gHbPrev = nil           -- last is_hibeam_on
local gHbRise = nil           -- os.clock() at the button-down edge

--- Fresh course load: the cached on/off state is stale and the game's native
--- auto may have left a cast-only light on, so schedule the one-time reconcile
--- (re-assert force modes, force the next auto tick after a short settle).
function Headlights.OnCourseLoad()
    headlightsOn = false        -- unknown until we assert
    lastTOD = nil
    modeChanged = true          -- re-assert force_on / force_off
    entryAssertPending = true   -- force one auto assert, ignoring the stale cache
    courseTicks = 0
    srcOrig = {}                -- fresh world = fresh light components
    cachedPawn, cachedPawnAt = nil, 0.0
    lastForcedOn, forcedOffSince = false, nil
    brightnessReassertAt = nil
    -- Gesture edge state: a button held across the load screen must not read
    -- as a release whose "held" time spans the load = a phantom hold-off.
    gHbPrev, gHbRise = nil, nil
    Log.Info(MODULE, "Course load: will re-assert headlight state")
end

-- ===== Light-button hold-gesture (keyboard + controller) =====
-- The vanilla light/hi-beam button is momentary: is_hibeam_on is true only
-- while held, for keyboard and controller alike. Release after a short press
-- turns the headlights on, after a long hold off (manual mode only; see the
-- thresholds above). gHbPrev/gHbRise are declared above OnCourseLoad.

-- Manual on/off from a gesture: absolute (tap = on, hold = off), not a toggle,
-- so it is deterministic whatever the cached state says. No-op in auto.
local function gestureSetLights(want)
    if currentMode == "auto" then return end
    local target = want and "force_on" or "force_off"
    if currentMode ~= target then
        currentMode = target
        modeChanged = true   -- Tick actuates (SetLightOn animates the pops)
        saveState()
    end
end

local function handleLightGesture(pawn)
    local on = nil
    pcall(function() local v = pawn.is_hibeam_on; if type(v) == "boolean" then on = v end end)
    if on == nil then return end

    if gHbPrev == nil then gHbPrev = on; return end
    if on == gHbPrev then return end

    local now = os.clock()
    if on then
        gHbRise = now                              -- button down
    else
        -- Hi-beam released: the game's OffHiBeam recompute resets lamp intensity
        -- as the flash ends, so re-assert now (the pending block runs later this
        -- tick) and once more shortly after in case the recompute lands late.
        if headlightsOn then
            pendingBrightnessApply = true
            brightnessRetryCount = 0
        end
        brightnessReassertAt = now + 0.6
        local held = gHbRise and (now - gHbRise) or nil   -- button up
        gHbRise = nil
        if held then
            local ignored = (currentMode == "auto") and " (ignored: mode is auto)" or ""
            if held >= GESTURE_OFF_HOLD_SEC then
                gestureSetLights(false)
                Log.Info(MODULE, "Gesture: headlights OFF (hold)" .. ignored, {held = string.format("%.1f", held)})
            elseif held <= GESTURE_TAP_MAX_SEC then
                gestureSetLights(true)
                Log.Info(MODULE, "Gesture: headlights ON (tap)" .. ignored, {held = string.format("%.2f", held)})
            end
        end
    end
    gHbPrev = on
end

--- Main tick function
function Headlights.Tick()
    if not isInitialized then return end
    if Config.Headlights and Config.Headlights.Enabled == false then return end

    local actors = getActors()
    if not actors then return end

    -- Garage always-on (2026-08-11): the one headlight job in the outgame
    -- branch, ahead of the course early-out. Throttled; the ensure body is
    -- a no-op while the lights are already on (state-checked toggle).
    if Config.Headlights and Config.Headlights.GarageAlwaysOn
       and actors.IsInGarage and actors.IsInGarage() then
        local nowG = os.clock()
        if nowG - garageEnsureLast >= 2.5 then
            garageEnsureLast = nowG
            Headlights.EnsureGarageLightsOn()
        end
    end

    if not actors.IsOnCourse() then cachedPawn = nil; return end

    -- Don't run during PA
    if State.IsPAFrozen and State.IsPAFrozen() then return end

    -- Get player pawn (vehicle); required for any light control
    local pawn = getPlayerPawnCached()
    if not pawn then return end  -- No vehicle, skip tick

    courseTicks = courseTicks + 1

    handleLightGesture(pawn)  -- light-button hold gesture (tap = lights on, hold = off)

    -- Debounced post-flash re-assert (set on the hi-beam release edge)
    if brightnessReassertAt and os.clock() >= brightnessReassertAt then
        brightnessReassertAt = nil
        if headlightsOn then
            pendingBrightnessApply = true
            brightnessRetryCount = 0
        end
    end

    -- Deferred brightness application, ahead of the force-mode returns and the
    -- auto TOD throttle: placed after them it was unreachable in force modes
    -- and delayed by the throttle window in auto.
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

    -- Re-evaluate on a five-unit TOD move (3.75 s at normal speed) or a mode
    -- change. A pending entry assert bypasses the guard, and so does a forced
    -- context change (tunnel cover, wet preset): the TOD guard never elapses
    -- while the clock is paused, so a bore entry could wait for Alt+T. Entering
    -- cover flips at once; leaving holds FORCED_OFF_HOLD_S so a short gap
    -- between bores does not blink the lamps (09-02 leak hunt: 1-2 s off/on
    -- pairs at bore mouths).
    local forcedNow = autoForcedOn()
    local forcedChanged = false
    if forcedNow ~= lastForcedOn then
        if forcedNow then
            forcedChanged = true
            lastForcedOn = true
            forcedOffSince = nil
        else
            forcedOffSince = forcedOffSince or os.clock()
            if (os.clock() - forcedOffSince) >= FORCED_OFF_HOLD_S then
                forcedChanged = true
                lastForcedOn = false
                forcedOffSince = nil
            end
        end
    else
        forcedOffSince = nil
    end
    if not modeChanged and not entryAssertPending and not forcedChanged
       and lastTOD and math.abs(currentTOD - lastTOD) < 5 then
        return
    end
    lastTOD = currentTOD
    modeChanged = false

    -- Course-entry reconcile: seed the hysteresis with the car's actual light
    -- state. A cold headlightsOn=false seed inside the dead band overrode the
    -- game's correct dusk-spawn on ("lights start on, then turn off"); a real
    -- daytime cast-only desync still clears, since day sits above OFF_ELEV.
    if entryAssertPending and courseTicks >= ENTRY_SETTLE_TICKS then
        local actual = nil
        pcall(function() local v = pawn.is_light_on; if type(v) == "boolean" then actual = v end end)
        if actual ~= nil then headlightsOn = actual end
    end

    -- Driven by the sun's elevation with hysteresis; TOD is the fallback.
    local shouldBeOn = computeAutoDesired(currentTOD, lastForcedOn)

    if entryAssertPending and courseTicks >= ENTRY_SETTLE_TICKS then
        -- Course-entry reconcile: drive the lights to the desired state unconditionally,
        -- clearing any cast-only desync the game's native auto left at load.
        setVehicleLights(pawn, shouldBeOn)
        headlightsOn = shouldBeOn
        entryAssertPending = false
        pendingBrightnessApply = shouldBeOn
        brightnessRetryCount = 0
        Log.Info(MODULE, "Auto headlights asserted on entry", {on = shouldBeOn, tod = currentTOD})
    elseif shouldBeOn and not headlightsOn then
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

end

--- Manual on/off toggle between force_on / force_off. Deliberately a no-op
--- while config Mode = "auto": there is no on-screen mode indicator, so a
--- hidden runtime switch out of auto just looks like "auto stopped working".
--- @return string newMode
function Headlights.ToggleManual()
    if currentMode == "auto" then
        Log.Info(MODULE, "Manual toggle ignored: auto is full-auto (config-only)")
        return currentMode
    end
    if headlightsOn then
        currentMode = "force_off"
    else
        currentMode = "force_on"
    end
    modeChanged = true
    saveState()
    Log.Info(MODULE, "Headlight manual toggle", {mode = currentMode, wasOn = headlightsOn})
    return currentMode
end

-- Auto mode is config-only (Config.Headlights.Mode = "auto"); a runtime auto
-- toggle could desync from the manual on/off state, so there is none.

--- Toggle the lights on the car displayed in the garage. The player pawn is nil
--- there, so the car comes from the garage manager's GetDisplayVehicle (not
--- FindAllOf, which would hit every car). Gated on GetIsMovingRHL: toggling
--- while the pop-up rig is mid-move is the documented desync cause. SetLightOn
--- animates the pops. Game thread only (outgame object writes off-thread can
--- corrupt reflection).
--- @return boolean attempted
function Headlights.ToggleGarageLights()
    if not ExecuteInGameThread then return false end
    GT.Run(function()
        local gm = nil
        pcall(function() gm = FindFirstOf("BP_OutGameGarageManager_C") end)
        if not (gm and gm.IsValid and gm:IsValid()) then return end

        local out = {}
        local got = pcall(function() gm:GetDisplayVehicle(out) end)
        local veh = got and out.out_vehicle or nil
        if not (veh and veh.IsValid and veh:IsValid()) then
            Log.Debug(MODULE, "Garage toggle: no display vehicle")
            return
        end

        -- Anti-desync: skip while the retractable-headlight rig is animating.
        local moving = false
        pcall(function()
            if veh.GetIsMovingRHL then
                local m = {}
                veh:GetIsMovingRHL(m)
                moving = m.out_is_moving and true or false
            end
        end)
        if moving then
            Log.Debug(MODULE, "Garage toggle skipped (RHL moving)")
            return
        end

        pcall(function() veh:SetLightOn(true) end)        -- toggle is_light_on + animate pops
        pcall(function() veh:SetLightSpriteScale(0) end)  -- match the on-course sprite handling
        Log.Info(MODULE, "Garage lights toggled (display vehicle)")
    end)
    return true
end

--- Config.Headlights.GarageAlwaysOn (2026-08-11): keep the displayed car's
--- lights on for the whole garage visit (pairs with the dark-garage exposure
--- seed). Same GT body as the toggle but state-checked: SetLightOn fires only
--- when the lights are off, so the periodic re-assert is a no-op while on (the
--- RHL rig can never flip-flop) and a freshly displayed car is caught within
--- one throttle window. Alt+Q still toggles; auto-on re-arms within seconds.
--- @return boolean attempted
function Headlights.EnsureGarageLightsOn()
    if not ExecuteInGameThread then return false end
    GT.Run(function()
        local gm = nil
        pcall(function() gm = FindFirstOf("BP_OutGameGarageManager_C") end)
        if not (gm and gm.IsValid and gm:IsValid()) then return end

        local out = {}
        local got = pcall(function() gm:GetDisplayVehicle(out) end)
        local veh = got and out.out_vehicle or nil
        if not (veh and veh.IsValid and veh:IsValid()) then return end

        local cur = nil
        pcall(function()
            local v = veh.is_light_on
            if type(v) == "boolean" then cur = v end
        end)
        if cur == true then return end   -- already on: no-op re-assert

        -- Anti-desync: never act while the retractable-headlight rig moves.
        local moving = false
        pcall(function()
            if veh.GetIsMovingRHL then
                local m = {}
                veh:GetIsMovingRHL(m)
                moving = m.out_is_moving and true or false
            end
        end)
        if moving then return end

        pcall(function() veh:SetLightOn(true) end)
        pcall(function() veh:SetLightSpriteScale(0) end)
        Log.Info(MODULE, "Garage lights auto-on (display vehicle)")
    end)
    return true
end

--- Entry point for the manual on/off keybind. In the garage it toggles the displayed
--- car's lights (pops animate); on a course it routes to the normal manual toggle.
--- @return string where "garage" | the manual mode string
function Headlights.OnManualToggleKey()
    local actors = getActors()
    if actors and actors.IsInGarage and actors.IsInGarage() then
        Headlights.ToggleGarageLights()
        return "garage"
    end
    return Headlights.ToggleManual()
end

-- ============== BRIGHTNESS CONTROL ==============
-- Uses BP_CarLightSpriteComponent_C:SetIntensity for visual brightness

--- Apply brightness multiplier to all car light sprite components
--- @param multiplier number
--- @return number count of modified lights
applyBrightness = function(multiplier)
    local count = 0

    -- Pawn-level source templates: the flash recompute pulls intensity from
    -- these (component-source scaling alone did not survive a hi-beam flash),
    -- so the multiplier is baked in here too, from the cached original.
    pcall(function()
        local pawn = getPlayerPawnCached()
        if not pawn then return end
        local key = nil
        pcall(function() key = "pawn:" .. pawn:GetFullName() end)
        local orig = key and srcOrig[key] or nil
        if not orig then
            orig = {
                normal = safeGet(pawn, "headlight_normal_intensity"),
                hibeam = safeGet(pawn, "headlight_hibeam_intensity"),
            }
            if key then srcOrig[key] = orig end
        end
        if type(orig.normal) == "number" and orig.normal > 0 then
            pcall(function() pawn.headlight_normal_intensity = orig.normal * multiplier end)
        end
        if type(orig.hibeam) == "number" and orig.hibeam > 0 then
            pcall(function() pawn.headlight_hibeam_intensity = orig.hibeam * multiplier end)
        end
    end)

    -- Try BP_CarLightSpriteComponent_C first (controls visual glow/bloom)
    pcall(function()
        local sprites = FindAllOf("BP_CarLightSpriteComponent_C")
        if sprites then
            for _, sprite in ipairs(sprites) do
                if sprite and sprite:IsValid() and sprite.SetIntensity then
                    -- Don't brighten a car's sprite glow if its lights are off.
                    local lit = ownerLightsOn(sprite)
                    local value = (lit == false) and 0 or multiplier
                    local success = pcall(function()
                        sprite:SetIntensity(value)
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
                        -- Cache the original source intensities once, before any
                        -- scaling (first-seen value = stock).
                        local key = nil
                        pcall(function() key = light:GetFullName() end)
                        local orig = key and srcOrig[key] or nil
                        if not orig then
                            orig = {
                                normal = safeGet(light, "Normal_intensity"),
                                hibeam = safeGet(light, "hibeam_intensity"),
                            }
                            if key then srcOrig[key] = orig end
                        end

                        -- Bake the multiplier into the source props so the game's
                        -- hi-beam/setup recomputes land on the scaled value.
                        if type(orig.normal) == "number" and orig.normal > 0 then
                            pcall(function() light.Normal_intensity = orig.normal * multiplier end)
                        end
                        if type(orig.hibeam) == "number" and orig.hibeam > 0 then
                            pcall(function() light.hibeam_intensity = orig.hibeam * multiplier end)
                        end

                        -- Off cars get zero intensity; on (or unknown) cars get brightened.
                        local lit = ownerLightsOn(light)
                        local baseNormal = (type(orig.normal) == "number" and orig.normal > 0)
                            and orig.normal or 1000
                        local newIntensity = (lit == false) and 0 or (baseNormal * multiplier)
                        light.Intensity = newIntensity
                        if light.SetIntensity then
                            light:SetIntensity(newIntensity)
                        end
                    end)
                end
            end
        end
    end)

    -- Toggle BP_HeadLightComponent visibility off then on to force a refresh
    if count > 0 then
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
                        -- Only re-show cars whose lights are actually on.
                        comp:SetVisibility(ownerLightsOn(comp) ~= false, true)
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
    saveState()

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
    saveState()

    Log.Info(MODULE, "Brightness level down", {
        level = currentBrightnessLevel,
        multiplier = multiplier
    })

    return currentBrightnessLevel, multiplier
end

return Headlights
