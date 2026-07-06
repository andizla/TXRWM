-- TXR Weather Mod v3.0
-- systems/headlights.lua
-- Phase 10: Automatic headlight control based on time of day
-- Fixed: Uses UEHelpers pattern from V2 for vehicle discovery
--
-- Reverted to the original V2-style actuation (FindAllOf + SetVisibility/SetActive/
-- SetIntensity) after the BP-function rewrite regressed. Two additions kept:
--   * AUTO mode is driven by the Exposure module's brightness (lens proxy) with
--     hysteresis, not a hardcoded clock (falls back to TOD if no lens available).
--   * Mode + brightness level PERSIST to headlight_state.txt across sessions.

local Headlights = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")
local Config = require("config")
local Utils = require("core.utils")

-- Lazy-load to avoid circular dependencies
local Actors = nil
local TimeOfDay = nil
local Exposure = nil

local MODULE = "Headlights"

-- ============== CONFIGURATION ==============
-- Headlight mode: "auto" | "force_on" | "force_off"
local currentMode = "auto"

-- TOD thresholds for auto mode (fallback only, when no exposure lens is available)
local HEADLIGHT_ON_TOD = 1830   -- Turn on after 18:30 (dusk)
local HEADLIGHT_OFF_TOD = 630   -- Turn off after 06:30 (dawn)

-- Auto mode brightness thresholds (exposure lens proxy: ~0.78 day .. ~30 night).
-- On > Off = hysteresis band so the lights do not flicker at the boundary.
local ON_LENS = 6.0
local OFF_LENS = 3.5

-- Light-button gesture thresholds (seconds). Acted on RELEASE by how long held:
--   held <= GESTURE_TAP_MAX_SEC   -> headlights ON  (a short press / tap)
--   held >= GESTURE_OFF_HOLD_SEC  -> headlights OFF (a deliberate hold)
--   in between                    -> nothing (dead zone)
-- (Manual mode only; auto is untouchable.) High-beam latch is a separate key (Alt+H).
-- Note the 125 ms tick caps timing precision, so the windows are wide and a sub-125 ms
-- flick may be missed - hence "hold to OFF" (reliable) vs a strict instant tap.
local GESTURE_TAP_MAX_SEC = 1.0
local GESTURE_OFF_HOLD_SEC = 2.0

-- ============== STATE ==============
local isInitialized = false
local headlightsOn = false
local lastTOD = nil
local modeChanged = false

-- Course-entry reconcile: on a fresh course the cached on/off state is unknown and
-- the game's native auto may have enabled a cast-only light. Force ONE assert of the
-- desired state (ignoring the stale headlightsOn cache) after a short settle so the
-- exposure lens is available.
local entryAssertPending = false
local courseTicks = 0
local ENTRY_SETTLE_TICKS = 16  -- ~2s at 125ms tick (lets exposure produce a lens)

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

-- Original SOURCE intensities per light component (GetFullName -> {normal, hibeam}).
-- The game recomputes a lamp's live .Intensity from its source props
-- (Normal_intensity / hibeam_intensity) on every hi-beam or setup event, so a
-- brightness multiplier written only to .Intensity is wiped by the next flash.
-- The multiplier is baked into the source props instead, always scaled from the
-- cached ORIGINAL so re-applies never compound. Cleared per course (fresh comps).
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

local function getExposure()
    if not Exposure then
        local success, mod = pcall(require, "systems.exposure")
        if success then Exposure = mod end
    end
    return Exposure
end

--- Check if TOD is in night range (fallback when no exposure lens is available)
--- @param tod number
--- @return boolean
local function isNightTime(tod)
    -- Night wraps around midnight: on after HEADLIGHT_ON_TOD or before HEADLIGHT_OFF_TOD
    return tod >= HEADLIGHT_ON_TOD or tod < HEADLIGHT_OFF_TOD
end

--- Decide whether headlights should be on in AUTO mode. Driven by the Exposure
--- module's interpolated brightness (lens) with hysteresis, so the lights track
--- available light instead of a fixed clock; falls back to TOD if no lens yet.
--- @param tod number current time of day (for the fallback)
--- @return boolean
local function computeAutoDesired(tod)
    local exp = getExposure()
    local lens = nil
    if exp and exp.GetBrightnessLens then
        local ok, v = pcall(exp.GetBrightnessLens)
        if ok then lens = v end
    end

    if type(lens) == "number" then
        -- Hysteresis: once on, stay on until below OFF_LENS; once off, need ON_LENS.
        if headlightsOn then
            return lens > OFF_LENS
        else
            return lens >= ON_LENS
        end
    end

    -- Fallback: TOD thresholds.
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

    -- Drive the player's lights via SetLightOn - the game's input-path TOGGLE whose
    -- argument IS the RHL-animation flag. SetLightOn(true) flips is_light_on AND plays
    -- the native pop-up raise/lower animation. This is what 3.0.17 did (pops animated);
    -- 3.0.18 replaced it with a bare `is_light_on = want` write which is deterministic
    -- but never animates - the pop-up regression. (Note: the 2-arg SetLIght setter does
    -- NOT drive the rig - confirmed; SetLightOn is the one that animates.)
    --   It is a TOGGLE, so we read the ACTUAL current state and only toggle when it
    --   differs from `want`. That keeps the result deterministic (is_light_on always
    --   ends at `want`, so the owner-gated visibility below can't invert) while still
    --   animating on a real transition. Unconditional toggling was the 3.0.18 inversion.
    local cur = nil
    pcall(function() local v = obj.is_light_on; if type(v) == "boolean" then cur = v end end)
    local toggled = false
    if cur == nil then
        pcall(function() obj.is_light_on = want end)   -- state unreadable: deterministic write (no anim)
    elseif cur ~= want then
        toggled = safeCallMethod(obj, 'SetLightOn', true)  -- toggle cur->want + animate pops
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
                    -- SetVisibility controls rendering
                    if comp.SetVisibility then
                        comp:SetVisibility(lit, true)  -- propagate to children
                    end
                    -- Also try SetActive for component activation
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
    if ok and f then
        f:write("mode=" .. tostring(currentMode) .. "\n")
        f:write("brightness=" .. tostring(currentBrightnessLevel) .. "\n")
        f:close()
        Log.Debug(MODULE, "Saved headlight state", {mode = currentMode, brightness = currentBrightnessLevel})
    end
end

--- Load persisted brightness level, and the persisted MANUAL on/off state.
--- Auto vs manual is config-authoritative (set in config only), so a persisted
--- mode is restored only when it is a manual state AND config is not "auto".
--- @param allowModeOverride boolean true when config mode is manual
local function loadState(allowModeOverride)
    local ok, f = pcall(io.open, getStateFilePath(), "r")
    if not (ok and f) then return end
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
    f:close()
    Log.Info(MODULE, "Loaded headlight state", {mode = currentMode, brightness = currentBrightnessLevel})
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
        if Config.Headlights.OnLens then
            ON_LENS = Config.Headlights.OnLens
        end
        if Config.Headlights.OffLens then
            OFF_LENS = Config.Headlights.OffLens
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
    -- is NOT auto (auto mode is configured in config only, never persisted/keybound).
    loadState(currentMode ~= "auto")

    isInitialized = true
    State.SetModuleStatus("headlights", true)

    Log.Info(MODULE, "Headlights initialized", {mode = currentMode})
    return true
end

--- Called on a fresh course load. The cached on/off state is stale and the game's
--- native auto may have left a cast-only light enabled, so schedule a one-time
--- reconcile: re-assert force modes and force the next auto tick to drive the lights
--- to the correct state (after a short settle for the exposure lens).
function Headlights.OnCourseLoad()
    headlightsOn = false        -- unknown until we assert
    lastTOD = nil
    modeChanged = true          -- re-assert force_on / force_off
    entryAssertPending = true   -- force one auto assert, ignoring the stale cache
    courseTicks = 0
    srcOrig = {}                -- fresh world = fresh light components
    brightnessReassertAt = nil
    Log.Info(MODULE, "Course load - will re-assert headlight state")
end

-- ===== Light-button hold-gesture (keyboard + controller) =====
-- The vanilla light/hi-beam button is momentary: is_hibeam_on is true only while held.
-- We read that state (it is set the same for keyboard AND controller, so this is
-- device-agnostic) and act on RELEASE by how long it was held: a short press turns
-- headlights ON, a long hold turns them OFF (manual mode only). See thresholds above.
local gHbPrev = nil           -- last is_hibeam_on
local gHbRise = nil           -- os.clock() at the button-down edge

-- Manual on/off from a gesture. ABSOLUTE (short press = ON, hold = OFF), not a toggle,
-- so it is deterministic regardless of what we think the current state is. No-op in auto.
local function gestureSetLights(want)
    if currentMode == "auto" then return end
    local target = want and "force_on" or "force_off"
    if currentMode ~= target then
        currentMode = target
        modeChanged = true   -- Tick actuates (SetLightOn -> pops animate)
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
        -- as the flash ends. Re-assert IMMEDIATELY (the pending block runs right
        -- after this handler in the same tick) and once more shortly after, in
        -- case the game's recompute lands later than the release edge.
        if headlightsOn then
            pendingBrightnessApply = true
            brightnessRetryCount = 0
        end
        brightnessReassertAt = now + 0.6
        local held = gHbRise and (now - gHbRise) or nil   -- button up
        gHbRise = nil
        if held then
            local ignored = (currentMode == "auto") and " (ignored - mode is auto)" or ""
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
    if not actors or not actors.IsOnCourse() then return end

    -- Don't run during PA
    if State.IsPAFrozen and State.IsPAFrozen() then return end

    -- Get player pawn (vehicle) - required for any light control
    local pawn = getPlayerPawn()
    if not pawn then return end  -- No vehicle, skip tick

    courseTicks = courseTicks + 1

    handleLightGesture(pawn)  -- light-button hold gestures (headlights 3s / hi-beam latch 5s)

    -- Debounced post-flash re-assert (set on the hi-beam release edge)
    if brightnessReassertAt and os.clock() >= brightnessReassertAt then
        brightnessReassertAt = nil
        if headlightsOn then
            pendingBrightnessApply = true
            brightnessRetryCount = 0
        end
    end

    -- Deferred brightness application. Processed HERE, before the force-mode
    -- returns and the auto TOD-change throttle: the old placement at the end of
    -- the auto path made it unreachable in force modes and delayed it by the
    -- throttle window in auto.
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

    -- Only update on significant TOD change or mode change (avoid spam). A pending
    -- entry assert must keep evaluating until it fires, so it bypasses this guard.
    if not modeChanged and not entryAssertPending and lastTOD and math.abs(currentTOD - lastTOD) < 5 then
        return
    end
    lastTOD = currentTOD
    modeChanged = false

    -- Course-entry reconcile: seed the hysteresis with the car's ACTUAL light
    -- state first. The game's native auto may have already made the right call
    -- (lights ON at a dusk spawn); computing from a cold headlightsOn=false
    -- seed inside the dead band (OffLens..OnLens) overrode that to OFF and kept
    -- it off until the lens crossed OnLens ("lights start on, then turn off").
    -- A real daytime cast-only desync still clears: the day lens sits below
    -- OffLens, so an adopted ON immediately computes back to OFF.
    if entryAssertPending and courseTicks >= ENTRY_SETTLE_TICKS then
        local actual = nil
        pcall(function() local v = pawn.is_light_on; if type(v) == "boolean" then actual = v end end)
        if actual ~= nil then headlightsOn = actual end
    end

    -- Driven by the exposure brightness (lens) with hysteresis; TOD is the fallback.
    local shouldBeOn = computeAutoDesired(currentTOD)

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
    saveState()

    Log.Info(MODULE, "Headlight mode cycled", {mode = currentMode})
    return currentMode
end

--- Manual on/off toggle. Flips between force_on / force_off based on the current
--- light state. Intentionally a NO-OP while config Mode = "auto": auto is full-auto
--- and untouchable at runtime (there is no on-screen mode indicator, so a hidden
--- runtime switch out of auto just looks like "auto stopped working"). Manual on/off
--- belongs to a manual config only.
--- @return string newMode
function Headlights.ToggleManual()
    if currentMode == "auto" then
        Log.Info(MODULE, "Manual toggle ignored - auto is full-auto (config-only)")
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

-- Auto mode is configured in config only (Config.Headlights.Mode = "auto"); there
-- is intentionally no runtime auto toggle (a second toggle could desync from the
-- manual on/off state).

--- Toggle the lights on the car displayed in the garage. The player pawn is nil in
--- the garage, so we get the car from the garage manager via GetDisplayVehicle (NOT
--- FindAllOf, which would hit every car). Gated on GetIsMovingRHL so we never toggle
--- while the pop-up rig is mid-move (that is the documented desync cause). SetLightOn
--- (single-arg RHL-animation toggle) flips is_light_on AND animates the pops - so
--- pop-ups work in the garage too. All on the game thread (object writes off-thread
--- during outgame can corrupt reflection). Pattern taken from the reference mod.
--- @return boolean attempted
function Headlights.ToggleGarageLights()
    if not ExecuteInGameThread then return false end
    ExecuteInGameThread(function()
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

--- Set headlight mode directly
--- @param mode string "auto" | "force_on" | "force_off"
function Headlights.SetMode(mode)
    if mode == "auto" or mode == "force_on" or mode == "force_off" then
        currentMode = mode
        modeChanged = true
        saveState()
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
        onLens = ON_LENS,
        offLens = OFF_LENS,
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

    -- Pawn-level source templates. The flash recompute pulls intensity from
    -- these (component-source scaling alone did not survive a hi-beam flash:
    -- lamps dropped to stock until the delayed re-assert), so the multiplier is
    -- baked in here too - same cached-original rule so it never compounds.
    pcall(function()
        local pawn = getPlayerPawn()
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
                        -- Cache this component's ORIGINAL source intensities once,
                        -- before we ever scale them (first-seen value = stock).
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

                        -- Bake the multiplier into the SOURCE props (from the
                        -- original base) so the game's own hi-beam/setup
                        -- recomputes land on the scaled value instead of stock.
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
