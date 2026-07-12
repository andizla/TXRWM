-- TXR Weather Mod v3.0
-- systems/photomode.lua
-- Removes the restrictions on TXR's Advanced Photo Mode free camera. Folded in from
-- the standalone "PhotoModeUnlocked" mod (kept on disk but disabled) so the whole
-- experience ships in one mod. Pure runtime reflection; adds/modifies no game files.
--
-- What it unlocks (all configurable in Config.PhotoMode):
--  , camera collision  (fly through cars/walls and outside the track)
--  , distance limit     (no cap on how far the camera can move from the car)
--  , orbit pan limits   (the non-free "orbit" camera can pan much further)
--  : FOV / zoom         (widens the in-game FOV slider's range so the normal zoom goes further)
--  , move speed         (multiplies the free camera's painfully slow fly speed)
--  , rotation speed     (scaled with FOV so zoomed-in framing isn't twitchy)
--  , vignette default   (forces the photo-mode vignette slider off, it ships at 40)
--
-- TXR's photo mode is the "AdvancedPhotoMode" plugin:
--   /Game/AdvancedPhotoMode/Blueprints/BPC_PhotoMode   (the component, holds the limits)
--   /Game/AdvancedPhotoMode/Blueprints/BP_FreeCamera    (the spawned free camera)
-- The free camera copies its limits from the component when it spawns, so we set both
-- (the component so re-spawns stay unlocked, the live camera so it takes effect now)
-- and re-assert periodically while photo mode is open.
--
-- Threading: this module runs its OWN dedicated LoopAsync (started in Init), NOT the
-- shared 8 Hz main tick. The standalone worked that way and folding it onto the shared
-- tick let other modules / actor-discovery churn occasionally stall the re-assert. The
-- loop body runs on the async thread; the actual writes are object/widget/function calls
-- on photo-mode actors, so they're marshalled onto the game thread via ExecuteInGameThread
-- (the same proven pattern the standalone used). When photo mode isn't open the find()
-- calls return nil and a pass is a cheap no-op.

local PhotoMode = {}

local Log = require("core.logging")
local Config = require("config")

local MODULE = "PhotoMode"

local initialized = false
local enabled = false
local loopStarted = false
local cfg = nil

local _loggedActive = false

-- ============== helpers ==============

local function valid(o) return o and o.IsValid and o:IsValid() end

-- Lazy-loaded to avoid circular requires
local Actors = nil
local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

--- True while a map teardown is in progress. This module's dedicated loop and
--- its game-thread closures both do FindAllOf sweeps + object writes; running
--- those against a dying world is the round-3/4 crash mechanism (uncatchable
--- access violation), so every pass checks this on the async side AND again at
--- game-thread RUN time (the world can start dying between schedule and run).
local function teardownActive()
    local actors = getActors()
    if actors and actors.IsDiscoverySuspended then
        return actors.IsDiscoverySuspended()
    end
    return false
end

-- Resolve the first VALID instance of a class. FindFirstOf can hand back a STALE /
-- pending-kill object (e.g. a just-destroyed free camera lingering until GC) whose
-- IsValid() is false, which would make us think photo mode closed and drop every
-- unlock until the GC runs. Scanning FindAllOf for the first live instance kills that
-- intermittent dropout; FindFirstOf is only a fallback.
local function find(cls)
    local list = nil
    pcall(function() list = FindAllOf(cls) end)
    if type(list) == "table" then
        for _, o in ipairs(list) do
            if valid(o) then return o end
        end
    end
    local o = nil
    pcall(function() o = FindFirstOf(cls) end)
    if valid(o) then return o end
    return nil
end

local function setf(obj, field, value)
    pcall(function() obj[field] = value end)
end

local function num(obj, field)
    local v = nil
    pcall(function() v = obj[field] end)
    if type(v) == "number" then return v end
    return nil
end

-- Read an FName/FText field as a real string. tostring() on these returns the userdata
-- address ("FNameUserdata: 0x..."); the actual text comes from :ToString().
local function name_str(obj, field)
    local s = ""
    pcall(function()
        local v = obj[field]
        if v == nil then return end
        local ok, r = pcall(function() return v:ToString() end)
        if ok and type(r) == "string" then s = r else s = tostring(v) end
    end)
    return s or ""
end

-- ============== unlock the photo-mode component (holds the limits) ==============

local function unlock_component(comp)
    if cfg.RemoveDistanceLimit then
        setf(comp, "bUseMaximumDistanceLimit", false)
    end
    setf(comp, "FreeCameraMaximumDistance",              cfg.MaxDistance)
    setf(comp, "FreeCameraMaximumDistanceHeight",        cfg.MaxDistanceHeight)
    setf(comp, "FreeCameraMaximumDistanceForGarage",     cfg.MaxDistance)
    setf(comp, "FreeCameraMaximumDistanceForPA",         cfg.MaxDistance)
    setf(comp, "FreeCameraMaximumDistanceHeightForPA",   cfg.MaxDistanceHeight)

    if cfg.RaiseOrbitLimits then
        setf(comp, "MaxLeftRightCameraDistance", cfg.OrbitMaxLeftRight)
        setf(comp, "MaxUpDownCameraDistance",    cfg.OrbitMaxUpDown)
    end

    if cfg.DisableCameraCollision then
        local sa = nil
        pcall(function() sa = comp.SpringArmRef end)
        if valid(sa) then setf(sa, "bDoCollisionTest", false) end
    end
end

-- ============== unlock the live free-camera actor ==============

local function unlock_freecam(cam)
    if cfg.RemoveDistanceLimit then
        setf(cam, "bUseMaximumDistance", false)
    end
    setf(cam, "MaximumDistance",       cfg.MaxDistance)
    setf(cam, "MaximumDistanceHeight", cfg.MaxDistanceHeight)

    if cfg.DisableCameraCollision then
        -- The plugin's own toggle (cleanest path).
        pcall(function() cam:SetCameraCollision(false) end)
        -- Belt-and-braces: kill the sphere + spring-arm collision directly too.
        local sphere = nil
        pcall(function() sphere = cam.Sphere end)
        if valid(sphere) then
            pcall(function() sphere:SetCollisionEnabled(0) end)         -- ECollisionEnabled::NoCollision
            pcall(function() sphere:SetGenerateOverlapEvents(false) end)
        end
        local sa = nil
        pcall(function() sa = cam.SpringArm end)
        if valid(sa) then setf(sa, "bDoCollisionTest", false) end
    end
end

-- ============== widen the in-game FOV slider + default the vignette slider ==============
-- The photo-mode menu builds its settings as WBP_PhotoMode_Bar_Slider widgets, each with
-- its own Min/MaxValue. MoveCapture applies the slider's value WITHOUT re-clamping, so
-- raising the FOV slider's Min/Max is what actually widens the zoom range. The menu has
-- several sliders; we match the FOV one by its internal ListKey ("FOV"); the on-screen
-- "Zoom" name is localized display text and is unreliable to match on. Re-applied each
-- tick (the menu rebuilds sliders on open) but only re-inits when the range/step isn't
-- already ours (no flicker).

local _loggedKeys = {}        -- discovery dedup: log each distinct slider (by key) once
local _fovWidenLogged = false -- log the "Widened" line once per session, not every tick
local _vignetteForced = false -- force the vignette slider to default once per menu presence

local function widen_fov_sliders()
    local sliders = nil
    pcall(function() sliders = FindAllOf("WBP_PhotoMode_Bar_Slider_C") end)
    if type(sliders) ~= "table" then
        _vignetteForced = false  -- sliders gone; re-default vignette when the menu reopens
        return
    end

    local match = (cfg.FovSliderMatch or ""):lower()
    local vmatch = (cfg.VignetteMatch or "vignette"):lower()
    local sawVignette = false

    for _, s in ipairs(sliders) do
        if valid(s) then
            local key   = name_str(s, "ListKey")
            local label = name_str(s, "In Text Name")
            local mn, mx = num(s, "MinValue"), num(s, "MaxValue")

            -- Discovery: log each distinct slider once (keyed by its name) so cycling
            -- through the menu reveals every slider's key + range.
            if cfg.DebugSliders then
                local dedup = (key ~= "" and key) or label
                if dedup ~= "" and not _loggedKeys[dedup] then
                    _loggedKeys[dedup] = true
                    Log.Info(MODULE, string.format("slider key='%s' label='%s' min=%s max=%s step=%s now=%s",
                        key, label, tostring(mn), tostring(mx),
                        tostring(num(s, "StepValue")), tostring(num(s, "NowValue"))))
                end
            end

            if cfg.WidenFovSlider and match ~= ""
               and (key .. " " .. label):lower():find(match, 1, true) then
                local now = num(s, "NowValue") or 90.0
                -- Finer step when zoomed in (low FOV grows exponentially, so a coarse
                -- step there is a huge jump); normal step above the threshold.
                local desiredStep = (now < (cfg.FovFineBelow or 10.0))
                    and (cfg.FovStepFine or 0.25) or (cfg.FovStep or 1.0)

                -- Re-init when the range OR the step isn't what we want. (The menu rebuilds
                -- the slider on open, and the step has to flip as you cross the threshold.)
                local curStep = num(s, "StepValue")
                local rangeOff = (mx == nil) or (math.abs(mx - cfg.FovSliderMax) > 0.5)
                    or (mn ~= nil and math.abs(mn - cfg.FovSliderMin) > 0.5)
                local stepOff = (curStep == nil) or (math.abs(curStep - desiredStep) > 1e-4)

                if rangeOff or stepOff then
                    setf(s, "MinValue", cfg.FovSliderMin)
                    setf(s, "MaxValue", cfg.FovSliderMax)
                    setf(s, "StepValue", desiredStep)
                    pcall(function()
                        s:Set_Slider_Init(desiredStep, cfg.FovSliderMin, cfg.FovSliderMax, now)
                    end)
                    if rangeOff and not _fovWidenLogged then
                        _fovWidenLogged = true
                        Log.Info(MODULE, string.format("Widened FOV slider [%s] -> %.3f..%.0f (step %.2f, fine %.2f < %.0f)",
                            (key ~= "" and key) or label, cfg.FovSliderMin, cfg.FovSliderMax,
                            cfg.FovStep or 1.0, cfg.FovStepFine or 0.25, cfg.FovFineBelow or 10.0))
                    end
                end
            end

            -- Force the vignette slider to a sane default (it ships at 40). Once per menu
            -- presence, so you can still raise it again afterward.
            if cfg.ResetVignette and vmatch ~= ""
               and (key .. " " .. label):lower():find(vmatch, 1, true) then
                sawVignette = true
                if not _vignetteForced then
                    _vignetteForced = true
                    local old = num(s, "NowValue")
                    local v = cfg.VignetteValue or 0.0
                    -- Match the slider's displayed value...
                    setf(s, "NowValue", v)
                    pcall(function() s["Set Slider Value"](s, v) end)
                    -- ...but the slider value alone doesn't apply the effect. The photo-mode
                    -- Top widget owns the apply via BPI_SetVignette(Value, IsReset); call it.
                    local applied = false
                    local top = find("WBP_PhotoMode_Top_C")
                    if top then applied = pcall(function() top:BPI_SetVignette(v, false) end) end
                    Log.Info(MODULE, string.format("Reset vignette slider [%s] %s -> %.2f (applied=%s)",
                        (key ~= "" and key) or label, tostring(old), v, tostring(applied)))
                end
            end
        end
    end
    if not sawVignette then _vignetteForced = false end
end

-- ============== free-camera movement speed (vanilla is painfully slow) ==============

local _origMoveSens = nil
local function apply_movement_speed(comp, cam)
    if not cfg.SetMovementSpeed then return end
    -- Cache the vanilla MovementSensitivity ONCE, before we ever change it, so the
    -- multiplier is always computed from the original and can't compound across
    -- re-applies / camera respawns. Prefer the component (stable); fall back to the cam.
    if _origMoveSens == nil then
        local src = (valid(comp) and comp) or (valid(cam) and cam) or nil
        if src then
            local v = num(src, "MovementSensitivity")
            if v and v > 0 then
                _origMoveSens = v
                Log.Info(MODULE, string.format("vanilla free-cam movement speed = %.3f", v))
            end
        end
    end
    if _origMoveSens == nil then return end
    local target = _origMoveSens * (cfg.MovementSpeedMult or 1.0)
    if valid(comp) then setf(comp, "MovementSensitivity", target) end
    if valid(cam)  then setf(cam,  "MovementSensitivity", target) end
end

-- ============== rotation sensitivity scaled by FOV (zoomed in = slower) ==============

local _origRotSens = nil
local function apply_rotation_scale(comp, cam)
    if not cfg.ScaleRotationWithFov then return end
    -- Cache the vanilla RotationSensitivity once (before we change it) so the scaling
    -- is always computed from the original and never compounds.
    if _origRotSens == nil then
        local src = (valid(comp) and comp) or (valid(cam) and cam) or nil
        if src then
            local v = num(src, "RotationSensitivity")
            if v and v > 0 then
                _origRotSens = v
                Log.Info(MODULE, string.format("vanilla rotation sensitivity = %.3f", v))
            end
        end
    end
    if _origRotSens == nil then return end

    -- Read the live FOV from whichever camera component is active.
    local fov = nil
    if valid(cam) then
        local c = nil; pcall(function() c = cam.Camera end)
        if valid(c) then fov = num(c, "FieldOfView") end
    end
    if fov == nil and valid(comp) then
        local c = nil; pcall(function() c = comp.CameraRef end)
        if valid(c) then fov = num(c, "FieldOfView") end
    end
    if fov == nil then return end

    local ref = cfg.RotationRefFov or 60.0
    local scale = (ref > 0) and (fov / ref) or 1.0
    if scale > 1.0 then scale = 1.0 end
    local floor = cfg.RotationMinScale or 0.02
    if scale < floor then scale = floor end

    local target = _origRotSens * scale
    if valid(comp) then setf(comp, "RotationSensitivity", target) end
    if valid(cam)  then setf(cam,  "RotationSensitivity", target) end
end

-- ============== one re-assert pass ==============
-- Runs on the async thread. Detects photo mode (via the stale-safe find) and marshals
-- the actual writes onto the game thread. No-op when photo mode isn't open.
local _dbgPass = 0
local _dbgLastLog = 0.0
local function reassert()
    _dbgPass = _dbgPass + 1  -- monotonic pass counter (proves the loop is alive)
    if teardownActive() then
        -- World is being torn down: no FindAllOf sweeps, and treat photo mode
        -- as closed so the next real detection logs again
        _loggedActive = false
        return
    end
    local comp = find("BPC_PhotoMode_C")
    local cam  = find("BP_FreeCamera_C")
    if not comp and not cam then
        _loggedActive = false
        return
    end

    if not _loggedActive then
        _loggedActive = true
        Log.Info(MODULE, "Photo mode detected: applying unlocks")
    end

    -- Throttled diagnostic for the long-exposure dropout. Decided on the async side so
    -- the pass counter reflects the loop, then the read-back happens on the game thread.
    local doDbg = false
    if cfg.Debug then
        local now = os.clock()
        if (now - _dbgLastLog) >= 2.0 then _dbgLastLog = now; doDbg = true end
    end

    if type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(function()
            -- Re-check at RUN time: comp/cam were found up to a pass ago on the
            -- async thread and a teardown may have started since
            if teardownActive() then return end
            if doDbg then
                -- Read the live limits BEFORE we overwrite them: if these come back
                -- "re-enabled" every log while pass= keeps climbing, the game is
                -- re-asserting per frame (a race), not the loop stalling.
                local camMaxOn, saTest, compMaxOn, fov
                pcall(function() camMaxOn = cam and cam.bUseMaximumDistance end)
                pcall(function() saTest = cam and cam.SpringArm and cam.SpringArm.bDoCollisionTest end)
                pcall(function() compMaxOn = comp and comp.bUseMaximumDistanceLimit end)
                pcall(function() fov = cam and cam.Camera and cam.Camera.FieldOfView end)
                Log.Info(MODULE, string.format(
                    "DBG pass=%d compV=%s camV=%s camMaxLimit=%s springArmCollTest=%s compMaxLimit=%s fov=%s",
                    _dbgPass, tostring(valid(comp)), tostring(valid(cam)),
                    tostring(camMaxOn), tostring(saTest), tostring(compMaxOn), tostring(fov)))
            end
            if valid(comp) then unlock_component(comp) end
            if valid(cam)  then unlock_freecam(cam) end
            if cfg.WidenFovSlider or cfg.DebugSliders then widen_fov_sliders() end
            apply_movement_speed(comp, cam)
            apply_rotation_scale(comp, cam)
        end)
    end
end

-- ============== PUBLIC API ==============

-- Start the dedicated re-assert loop. Photo mode unlocks run on their OWN LoopAsync
-- (exactly like the standalone did) rather than riding TXRWM's shared 8 Hz tick, so a
-- busy main loop, an actor-discovery storm, or another module hiccupping can never
-- stall or skip the re-assert. The body is pcall-wrapped so a transient reflection
-- error can't kill the loop.
function PhotoMode.Start()
    if loopStarted then return end
    if type(LoopAsync) ~= "function" then
        Log.Warn(MODULE, "LoopAsync unavailable: photo mode unlocker cannot run")
        return
    end
    loopStarted = true
    local interval = cfg.ReassertMs or 200
    LoopAsync(interval, function()
        pcall(reassert)
        return false  -- keep looping
    end)
    Log.Info(MODULE, string.format("Photo mode unlocker active (re-assert every %dms)", interval))
end

function PhotoMode.Init()
    if initialized then return true end
    cfg = Config.PhotoMode or {}
    enabled = (cfg.Enabled ~= false)
    -- Respect the module toggle here too: our dedicated loop bypasses main.lua's
    -- handle-niling (that only stops Tick-driven modules), so check it at the source.
    local toggles = Config.ModuleToggles or {}
    if toggles.PhotoMode == false then enabled = false end
    initialized = true
    Log.Info(MODULE, "Initializing photo mode unlocker", {
        enabled = enabled,
        collision = not cfg.DisableCameraCollision,
        distanceLimit = not cfg.RemoveDistanceLimit,
    })
    if enabled then PhotoMode.Start() end
    return true
end

function PhotoMode.GetStatus()
    return {
        initialized = initialized,
        enabled = enabled,
        loopStarted = loopStarted,
        active = _loggedActive,
    }
end

return PhotoMode
