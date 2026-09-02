-- TXR Weather Mod v3.0
-- systems/photomode.lua
-- Removes the restrictions on TXR's Advanced Photo Mode free camera (folded
-- in from the standalone PhotoModeUnlocked mod, kept on disk but disabled).
-- Pure runtime reflection, no game files touched. Unlocks, all configurable
-- in Config.PhotoMode: camera collision (fly through cars, walls, off the
-- track), the distance cap, the orbit camera's pan limits, FOV/zoom (widens
-- the in-game FOV slider so the normal zoom goes further), move speed
-- (multiplies the slow fly speed), rotation speed (scaled with FOV so
-- zoomed-in framing is not twitchy) and the vignette default (the slider
-- ships at 40, forced off).
--
-- TXR's photo mode is the AdvancedPhotoMode plugin: BPC_PhotoMode (the
-- component, holds the limits) and BP_FreeCamera (the spawned free camera),
-- both under /Game/AdvancedPhotoMode/Blueprints/. The camera copies its
-- limits from the component on spawn, so both are set (component for
-- re-spawns, live camera for now) and re-asserted while photo mode is open.
--
-- Threading: this module runs its own LoopAsync (started in Init), not the
-- shared 8 Hz tick, where module and actor-discovery churn stalled the
-- re-assert. The loop body is async; the writes touch photo-mode actors and
-- widgets, so they are marshalled through GT.Run. With photo mode closed the
-- find() calls return nil and a pass is a cheap no-op.

local PhotoMode = {}

local Log = require("core.logging")
local GT = require("core.gt")
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

--- True while a map teardown is in progress. FindAllOf sweeps and object
--- writes against a dying world are an uncatchable access violation, so every
--- pass checks this on the async side and again at game-thread run time (the
--- world can start dying between schedule and run).
local function teardownActive()
    local actors = getActors()
    if actors and actors.IsDiscoverySuspended then
        return actors.IsDiscoverySuspended()
    end
    return false
end

--- First valid instance of cls, plus the whole list so a caller that also
--- needs every instance does not sweep the object array twice. FindFirstOf
--- can hand back a pending-kill object (a just-destroyed free camera lingering
--- until GC) whose IsValid() is false, which read as "photo mode closed" and
--- dropped every unlock until the GC ran; the first live instance from
--- FindAllOf fixed that dropout, FindFirstOf is only the fallback.
local function find(cls)
    local list = nil
    pcall(function() list = FindAllOf(cls) end)
    if type(list) == "table" then
        for _, o in ipairs(list) do
            if valid(o) then return o, list end
        end
    end
    local o = nil
    pcall(function() o = FindFirstOf(cls) end)
    if valid(o) then return o, list end
    return nil, list
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
-- The menu builds its settings as WBP_PhotoMode_Bar_Slider widgets with their
-- own Min/MaxValue. MoveCapture applies the slider value without re-clamping,
-- so raising the FOV slider's Min/Max is what widens the zoom. The FOV slider
-- is matched by its internal ListKey "FOV" (the on-screen "Zoom" name is
-- localized text, unreliable to match). Re-applied each pass (the menu
-- rebuilds sliders on open), re-inited only when the range/step is not
-- already ours (no flicker).

local _loggedKeys = {}        -- discovery dedup: log each distinct slider (by key) once
local _fovWidenLogged = false -- log the "Widened" line once per session, not every tick
local _vignetteForced = false -- force the vignette slider to default once per menu presence

local fovSliderSweepAt = 0.0
local function widen_fov_sliders()
    -- One widget sweep per second, not every 200 ms pass (game-thread cost)
    local nowS = os.clock()
    if (nowS - fovSliderSweepAt) < 1.0 then return end
    fovSliderSweepAt = nowS
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

                -- Re-init when the range or the step is off (the menu rebuilds the
                -- slider on open, and the step flips across the threshold).
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
    -- Cache the vanilla MovementSensitivity once, before changing it, so the
    -- multiplier never compounds across re-applies or camera respawns.
    -- Prefer the component (stable), fall back to the cam.
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
    -- Cache the vanilla RotationSensitivity once so the scaling never compounds.
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
-- Runs on the async thread. Detects photo mode and marshals the actual
-- writes onto the game thread. No-op when photo mode isn't open; with the
-- manager hooks live, idle passes touch no objects at all.

-- Session state, declared before every reader below (local-ordering rule:
-- onApertureSet reads _sessionOpen from the hook callback)
local _sessionOpen = false
-- Close debounce (2026-08-11, first session on the g1c1a1497 UE4SS build):
-- the member scan intermittently returns a one-pass "everything gone / all
-- false" verdict mid-session (metering flapped on/off seconds apart in the
-- 01:02 log; both BPC_PhotoMode_C and BP_FreeCamera_C vanish for one pass
-- then return, a scan-side artifact, most plausibly the GC mark phase). A
-- close verdict counts only after CLOSE_MISSES consecutive closed passes
-- (~600ms); opens stay instant, world teardown still closes at once.
local _closeMisses = 0
local CLOSE_MISSES = 3
local _openSigWarned = false
local _idleGtLast = 0.0   -- closed-session pass throttle (see reassert)
local _kickHooked = false -- ClientRestart kick registered (see Start)
-- IsOpenedPhotoMode fallback verdict, refreshed by the GT closure (it is a
-- UFUNCTION and may not be called from the async thread; 2026-07-21 rework)
local _fbWanted = false
local _fbIsOpen = false
local _fbAt = 0.0
-- Event-driven session edges (2026-07-27): a hook on the plugin's toggle
-- event feeds the open verdict (flag write only, GT hook context). While it
-- is live, idle passes are pure no-ops: no FindAllOf sweeps in idle worlds
-- and none in the post-close pending-kill purge window (the 12:52:38 AV was
-- an idle async sweep racing exactly that purge). Do not marshal the sweeps
-- to the GT instead: object-array walks there at pass cadence were heavy
-- frame hitches, reverted the same day. Make them unnecessary.
local _openHooksLive = false
local _hookIsOpen = false
local _hookRegTried = 0.0
-- Proof gate (2026-07-27): registration success is no proof a function is
-- ever called (the first deploy hooked BP_PhotoModeManager BndEvts; the
-- class is in the cook but TXR never spawns that manager, and the dead
-- verdict silenced the working fallback for a whole session). The hook
-- verdict is trusted only after a real fire; until then the fallback scan
-- runs as before.
local _hookEverFired = false
local _hookProvenLogged = false
local _hookPoke = false   -- toggle fired: next pass resolves state via one scan
-- The proven edge (2026-07-27 pak/bytecode dig, see reference\photodig):
-- "Photo Mode" on BPC_PhotoMode is the single state-transition authority.
-- Ubergraph proof: the only write of bIsUsingPhotoMode=true (offset 36429)
-- and the only jump into the =false close path (36424 to 724 to 835) both
-- live inside this event's body; the course car's SetPhotoMode(IsOpen)
-- gates on a state change then calls exactly this, and EndPhotoMode's
-- programmatic close also lands here via the widget. The hook is consumed
-- as a poke (state resolved by the next pass's scan): see the callback.
local HOOK_TOGGLE = "/Game/AdvancedPhotoMode/Blueprints/BPC_PhotoMode.BPC_PhotoMode_C:Photo Mode"

-- BP-function hooks only register once the plugin class is loaded, so
-- arming is retried ~1/s as a self-disarming GT one-shot: a single
-- object-path lookup per attempt, nothing recurring once armed.
local function tryRegisterOpenHooks()
    local now = os.clock()
    if (now - _hookRegTried) < 1.0 then return end
    _hookRegTried = now
    if type(RegisterHook) ~= "function" or type(ExecuteInGameThread) ~= "function" then return end
    GT.Run(function()
        if _openHooksLive then return end
        _openHooksLive = pcall(function()
            RegisterHook(HOOK_TOGGLE, function()
                -- Poke only, no state inference: reading bIsUsingPhotoMode
                -- here and inverting it ("pre-hook sees the old state") left
                -- the verdict stuck closed in the 20:26 field session
                -- (metering never applied). Script-hook pre/post timing on
                -- this build is not trustworthy; the fire only says the state
                -- is flipping now, and the next async pass (<=200ms) resolves
                -- it with one member scan and resyncs the verdict.
                _hookEverFired = true
                _hookPoke = true
                _idleGtLast = 0.0
            end)
        end)
        if _openHooksLive then
            Log.Info(MODULE, "Photomode toggle hook armed (BPC_PhotoMode 'Photo Mode', bytecode-proven edge)")
        end
    end)
end

-- Photo-session side effects on the open/close edges: freeze TOD
-- (time_of_day, the Animate Time of Day bool) and switch to manual metering
-- on the 3.4.0 lens curve (light_cycle; the aperture then drives exposure
-- physically). Both restore on close. A teardown counts as close: the writes
-- fail silently in a dying world and the next course load re-applies normal
-- state on its own.
local function setSessionFrozen(on)
    -- Session flag for main.lua's tick gates (2026-08-07 field: the TOD
    -- freeze never covered the scheduler, so a pick or its 15s transition
    -- mutated the sky mid-shoot). main.lua gates Scheduler.Tick on this,
    -- like PA freeze.
    pcall(function()
        local s = require("core.state")
        if s and s.SetPhotoSessionOpen then s.SetPhotoSessionOpen(on) end
    end)
    -- On close, hold auto picks briefly: a scheduler timer that expired
    -- during the shoot would pick on the close edge ("weather snapped the
    -- moment I left photo mode").
    if not on then
        pcall(function()
            local sch = require("systems.scheduler")
            if sch and sch.HoldFor then sch.HoldFor(30) end
        end)
    end
    if cfg.FreezeTime ~= false then
        pcall(function()
            local t = require("systems.time_of_day")
            if t and t.SetPhotoFreeze then t.SetPhotoFreeze(on) end
        end)
    end
    if cfg.ManualExposure ~= false then
        pcall(function()
            local lc = require("systems.light_cycle")
            if lc and lc.SetPhotoExposureFreeze then lc.SetPhotoExposureFreeze(on) end
        end)
    end
end

-- No aperture exposure emulation (removed 2026-07-15): the applied f-stop is
-- unreadable (static defaults on ~130 carriers, and the
-- CineCameraComponent:SetCurrentAperture hook never fired in the field).
-- Manual metering on the 3.4.0 curve makes the aperture work physically.

local _dbgPass = 0
local _dbgLastLog = 0.0
local function reassert()
    _dbgPass = _dbgPass + 1  -- monotonic pass counter (proves the loop is alive)
    if teardownActive() then
        -- Teardown: no sweeps, treat photo mode as closed (the next detection
        -- logs again) and reset the hook verdict, since a dying manager never
        -- fires its close and a stale open=true would open a session in the
        -- next world.
        _hookIsOpen = false
        _closeMisses = 0
        if _sessionOpen then
            _sessionOpen = false
            setSessionFrozen(false)
        end
        _loggedActive = false
        return
    end

    -- Arm the event-driven edges as soon as the plugin class exists
    if not _openHooksLive then
        tryRegisterOpenHooks()
    end

    -- Photomode exists on course and in the PA only: no sweeps in the
    -- garage, title or loading worlds (three object-array walks per second
    -- otherwise, until the edge hook had fired once)
    if not _sessionOpen then
        local actors = getActors()
        local tag = actors and actors.GetWorldTag and actors.GetWorldTag()
        if tag ~= "course" and not (actors and actors.IsInPAScene and actors.IsInPAScene()) then
            return
        end
    end

    -- Idle throttle (2026-07-21): ~1s cadence while no session is open, every
    -- 200ms pass while open. The ClientRestart kick (see Start) and the toggle
    -- hook zero _idleGtLast so a real open reacts on the next pass.
    local hooksProven = _openHooksLive and _hookEverFired
    if not _sessionOpen and not (hooksProven and _hookIsOpen) then
        local nowIdle = os.clock()
        if (nowIdle - _idleGtLast) < 1.0 then return end
        _idleGtLast = nowIdle
    end

    local isOpen = false
    local gotSignal = false
    local openSrc = nil
    local pokePass = false
    if hooksProven and not _hookPoke then
        if not _hookProvenLogged then
            _hookProvenLogged = true
            Log.Info(MODULE, "Photomode edge hook proven live (event-driven detection active)")
        end
        -- The hook verdict authorizes only the idle no-op: closed + no poke =
        -- leave without touching any object (keeps the post-close pending-kill
        -- purge window and every idle world sweep-free).
        if not (_hookIsOpen or _sessionOpen) then
            _loggedActive = false
            return
        end
        -- A believed-open session is not taken on faith (field 2026-07-27
        -- 23:48: a lost close edge held the stale open verdict, metering
        -- stuck on until teardown). The open-session passes sweep for the
        -- unlocks anyway, so the scan below re-verifies the member state
        -- every pass; close detection never depends on a hook fire.
    elseif _hookPoke then
        -- The toggle just fired: consume the poke and resolve the new state
        -- through the scan below (which then resyncs _hookIsOpen).
        _hookPoke = false
        pokePass = true
    end

    local comp, compList = find("BPC_PhotoMode_C")
    local cam  = find("BP_FreeCamera_C")
    if not comp and not cam then
        -- A poke pass that hits the one-pass scan flap must not eat the poke:
        -- with the session still closed the idle gate would block every future
        -- scan and the open edge is lost (the open-side mirror of the
        -- 2026-07-27 stuck-open bug). Re-arm and retry next pass.
        if pokePass then _hookPoke = true end
        if _sessionOpen then
            -- Debounced: a one-pass total absence mid-session is the g1c1a1497
            -- scan flap, not a close (see _closeMisses at the top).
            _closeMisses = _closeMisses + 1
            if _closeMisses >= CLOSE_MISSES then
                _closeMisses = 0
                _sessionOpen = false
                setSessionFrozen(false)
            end
        end
        _loggedActive = false
        return
    end

    if not _loggedActive then
        _loggedActive = true
        Log.Info(MODULE, "Photo mode detected: applying unlocks")
    end

    if not gotSignal then
        -- Fallback scan (hook not armed or not yet proven, or a path where
        -- the manager differs, e.g. replay spectator photomode). Session
        -- freeze keys on the real open state, not object existence:
        -- BPC_PhotoMode_C lives in every garage/course world from load with
        -- photomode closed (2026-07-14). Signals, ORed: 1. bIsUsingPhotoMode
        -- on any live BPC_PhotoMode_C instance, 2. the IsOpenedPhotoMode
        -- out-param call (a function in this cook, not a property;
        -- GT-refreshed cache, at most a pass stale). No UI-widget signal: it
        -- failed three ways across 2026-07-18/20 (template-widget false
        -- opens, a UFunction sweep crash suspect, "visible" outside
        -- photomode). Do not re-add one on this cook.
        pcall(function()
            local all = compList
            if type(all) ~= "table" then all = FindAllOf("BPC_PhotoMode_C") end
            if type(all) == "table" then
                for _, c in ipairs(all) do
                    if valid(c) then
                        local v = nil
                        pcall(function() v = c.bIsUsingPhotoMode end)
                        if type(v) == "boolean" then
                            gotSignal = true
                            if v then
                                isOpen = true
                                openSrc = "member"
                                break
                            end
                        end
                    end
                end
            end
        end)
        if not gotSignal and comp then
            _fbWanted = true
            if _fbAt > 0 and (os.clock() - _fbAt) < 3.0 then
                isOpen = _fbIsOpen
                gotSignal = true
                openSrc = "fallback"
            end
        end
        if not gotSignal and not _openSigWarned then
            _openSigWarned = true
            Log.Warn(MODULE,
                "Photo open signal unreadable (bIsUsingPhotoMode nil, no hook, IsOpenedPhotoMode failed)")
        end
    end

    -- A fallback-resolved state resyncs the hook flag (a poke pass or the
    -- pre-proof phase must not leave a stale hook verdict behind)
    if _openHooksLive and gotSignal and openSrc ~= "hook" then
        _hookIsOpen = isOpen
    end

    if isOpen then
        _closeMisses = 0
        if not _sessionOpen then
            _sessionOpen = true
            setSessionFrozen(true)
            Log.Info(MODULE, "Photo session opened", {signal = openSrc or "?"})
        end
    elseif gotSignal and _sessionOpen then
        -- Debounced close: an all-false read must repeat CLOSE_MISSES passes
        -- (the one-pass flap re-opened instantly in the 01:02 field log,
        -- which read as "aperture does nothing").
        _closeMisses = _closeMisses + 1
        if _closeMisses >= CLOSE_MISSES then
            _closeMisses = 0
            _sessionOpen = false
            setSessionFrozen(false)
        end
    end

    -- Throttled diagnostic for the long-exposure dropout, decided async (so
    -- the pass counter reflects the loop), read back on the game thread.
    local doDbg = false
    if cfg.Debug then
        local now = os.clock()
        if (now - _dbgLastLog) >= 2.0 then _dbgLastLog = now; doDbg = true end
    end

    if type(ExecuteInGameThread) ~= "function" then return end
    GT.Run(function()
        -- Re-check at run time: comp/cam were found up to a pass ago on the
        -- async thread and a teardown may have started since
        if teardownActive() then return end
        -- Refresh the IsOpenedPhotoMode fallback verdict here on the game
        -- thread (UFunction; the async side only consumes the cache)
        if _fbWanted then
            _fbWanted = false
            pcall(function()
                if not valid(comp) then return end
                local out = {}
                comp:IsOpenedPhotoMode(out)
                if type(out.IsOpenedPhoto) == "boolean" then
                    _fbIsOpen = out.IsOpenedPhoto
                    _fbAt = os.clock()
                end
            end)
        end
        if doDbg then
            -- Read the live limits before overwriting them: "re-enabled" every
            -- log while pass= keeps climbing = the game re-asserts per frame
            -- (a race), not a stalled loop.
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

-- ============== PUBLIC API ==============

-- Start the dedicated re-assert loop (own LoopAsync, see the header). The
-- body is pcall-wrapped so a transient reflection error cannot kill the loop.
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
    -- ClientRestart kick: every photomode enter possesses the free camera, a
    -- PlayerController restart (field 2026-07-27: all 12 opens that session
    -- had one at t-0..1s). Zeroing the idle throttle lets the next 200ms pass
    -- run full detection instead of waiting out the ~1s closed cadence, so
    -- short sessions get manual metering while the player is still in them.
    -- Flag write only; the sweep stays on the async loop with its gates.
    if not _kickHooked and type(RegisterHook) == "function" then
        _kickHooked = pcall(function()
            RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
                _idleGtLast = 0.0
            end)
        end)
        if not _kickHooked then
            Log.Warn(MODULE, "ClientRestart kick hook failed to register (detect stays on the 1s cadence)")
        end
    end
    Log.Info(MODULE, string.format("Photo mode unlocker active (re-assert every %dms%s)",
        interval, _kickHooked and ", ClientRestart kick armed" or ""))
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

return PhotoMode
