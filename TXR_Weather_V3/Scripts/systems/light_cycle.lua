-- TXR Weather Mod v3.0
-- systems/light_cycle.lua
-- Exposure + look on top of stock auto-exposure: an EV bias on UDS's
-- "Exposure Bias Day/Night" from the sun's real elevation (BiasCurve,
-- season-proof unlike a clock table); per-course one-shots on the course
-- sky's main PP component (adaptation speeds, the skylight-translucency kill,
-- the Config.LightCycle.PostProcess look overrides), all readback-verified
-- (held=false means a per-tick writer owns that field: measure, do not
-- silently re-assert); one-shot UDS night floors with a Hard Reset Cache
-- bake; neutral cvar parking plus the garage neutral push (no valid UDS
-- there), the Alt+Z/X/C skylight tuning and the Alt+D feedback keys.
-- Tunnel/rain detection lives in systems/tunnels.lua. Per-volume exposure
-- writes are a closed dead end (non-blendable fields snap at the blend edge).

local LightCycle = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local GT = require("core.gt")
local State = require("core.state")
local Config = require("config")
local Utils = require("core.utils")

-- Lazy-loaded to avoid circular dependencies
local Actors = nil
local TimeOfDay = nil
local Tunnels = nil

local MODULE = "LightCycle"

-- ============== CONFIG-DERIVED (filled in Init, with safe fallbacks) ==============
local enabled = true
local UPDATE_INTERVAL = 1.0
local CVAR_SKY  = "r.SkylightIntensityMultiplier"
local CVAR_LEAK = "r.Lumen.SkylightLeaking.ReflectionAverageAlbedo"
local CVAR_LENS = "r.EyeAdaptation.LensAttenuation"
local CVAR_ROUGH = "r.Lumen.SkylightLeaking.Roughness"
local TUNE_STEP = 0.05
local ROUGH_BASELINE = 1.0
local LEAK_ALBEDO = 0.07

-- PA continue/freeze (Config.PA.Mode ~= "stock"): the PA scene follows the
-- normal elevation path instead of the garage handling (set in Init).
local PA_FOLLOW = false

-- Night scene floors (one-shot per course; see applyAbsentBrightness)
local ABSENT_MULT = 1.0
local PROP_ABSENT_BRIGHTNESS = "Directional Lights Absent Brightness"
local NIGHT_CLOUDY = nil
local PROP_NIGHT_CLOUDY = "Extra Night Brightness When Cloudy"
local OVERCAST_NIGHT = nil
local PROP_OVERCAST_NIGHT = "Overcast Brightness Night"

-- Sun vector property (FVector, updated by UDS every frame)
local PROP_SUN_VECTOR = "Cached Sun Vector"

-- Auto-exposure adaptation speeds (f-stops/sec), written once per course
-- onto BP_CourseSky's composited PostProcess component. UE defaults (3 up /
-- 1 down) are the felt "exposure reacts slowly" under bridges and at portals.
-- nil = leave stock. Readback-verified.
local ADAPT_UP, ADAPT_DOWN = nil, nil

-- Skylight off translucents (Config.LightCycle.KillSkylightTranslucentLighting):
-- bAffectTranslucentLighting=false on the course skylights, once per course.
local KILL_SKY_TRANSLUCENT = false

-- Post-process look overrides (Config.LightCycle.PostProcess): field name to
-- value, written with bOverride flags onto the course sky's main PP component
-- in the same per-course one-shot and readback-verified. Vector/color fields
-- arrive as {X=,Y=,Z=,W=} tables.
local PP_OVERRIDES = nil

-- Bias output: drives UDS's Exposure Bias knobs (confirmed live) on top
-- of stock auto-exposure.
local BIAS_CURVE = {}

-- Engine-neutral cvar values (sky mult 1.0, lens 0.78 = UE physical default):
-- pushed once per course so nothing from the old cvar era masks the
-- UDS-driven picture.
local NEUTRAL_SKY, NEUTRAL_LENS = 1.0, 0.78

-- Pseudo-elevation fallback (also calibrates the vector sign): effective sun
-- events measured on the stock install (DST-shifted).
local SUNRISE_TOD, SUNSET_TOD = 600.0, 1930.0

-- ============== STATE ==============
local isInitialized = false
local lastCheckClock = 0.0
local lastElevation = nil            -- last computed sun elevation (degrees)
local lastBias = nil
local scenarioZeroed = false
local absentApplied = false          -- one-shot flag for the night floors
local armed = false                  -- course gate (fresh UDS reads garbage
                                     -- before the restore has run)

-- One-shot PP pipeline writes + their delayed readback (per course)
local ppShotsApplied = false
local ppShotsProbeWait = 0   -- Updates spent waiting for the profile probe
local ppShotsWroteClock = nil
local ppShotsCheckDone = false

-- Photomode session state (SetPhotoExposureFreeze) and the 3.4.0 manual
-- exposure lens curve it applies (Config.PhotoMode.ManualCurve, normalized
-- in Init to an elev/bias table for curveLookup). Declared here because
-- applyValues sits above the photomode section (local-ordering rule).
local photoExpFrozen = false
local PHOTO_LENS_CURVE = {}
local PHOTO_GARAGE_LENS = 30.0   -- the 3.4.0 garage value (no sun there)
-- Covered sessions (road-data roof at open): a lit tunnel interior is
-- roughly TOD-independent like the garage, so the sun curve is the wrong
-- level there (day anchor lens 1.0 = near-black bore shots). A fixed
-- indoor value applies instead; nil = feature off.
local PHOTO_COVERED_LENS = nil
local photoCoveredLatch = false  -- latched at session open (car is parked)
-- Per-session exposure trim (Alt+E family, 2026-07-27): each step multiplies
-- the branch's lens by NudgeStep^steps; reset at session open. Every press
-- logs the level: field telemetry for retuning the curve/garage/covered
-- constants ("often not bright enough or too bright").
local PHOTO_NUDGE_STEP = 1.25
local photoNudgeSteps = 0
-- Alt+G dark look (2026-07-27): forces this lens regardless of branch, the
-- crushed low-key look a tester's SDR render of garage lens 30 showed on
-- 07-22, kept as a feature. Session scoped; the nudge applies on top.
local PHOTO_DARK_LENS = 30.0
local photoDarkOn = false

-- UDS's cached sun vector is the light direction, so raw Z = -sin(elevation)
-- and the sign is a constant -1 (Nov midday raw=-39 with real +39). The old
-- auto-calibration raced the course-load restore and once latched +1 for a
-- whole inverted December day, so it is gone: Config.LightCycle.SunVectorSign
-- overrides if a UDS update flips the convention, and a trusted-window sanity
-- check warns on persistent disagreement but never auto-flips.
local SUN_VECTOR_SIGN = -1
local signViolations = 0
local signWarned = false
local usedPseudoLogged = false
local lastApplied = { sky = nil, leak = nil, lens = nil }

-- Skylight tuning overrides (Alt+Z/X/C)
local tune = { sky = nil, leak = nil, rough = nil }
local TUNE_LIMITS = {
    sky   = { min = 0.0, max = 4.0, fallback = 1.0 },
    leak  = { min = 0.0, max = 1.0, fallback = 0.07 },
    rough = { min = 0.0, max = 1.0 },
}

-- ============== INTERNAL: shared helpers ==============

local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

local function getTimeOfDay()
    if not TimeOfDay then
        local ok, mod = pcall(require, "systems.time_of_day")
        if ok then TimeOfDay = mod end
    end
    return TimeOfDay
end

local function getTunnels()
    if not Tunnels then
        local ok, mod = pcall(require, "systems.tunnels")
        if ok then Tunnels = mod end
    end
    return Tunnels
end

local function clamp(x, a, b)
    if x < a then return a end
    if x > b then return b end
    return x
end

local function lerp(a, b, t) return a + (b - a) * t end

--- Piecewise-linear lookup on an elev-sorted anchor curve ({elev, bias}).
--- Shared by the bias curve, the SDR profile swap, and the photomode lens
--- curve (which normalizes its {elev, lens} anchors to this shape in Init).
--- @return number bias
local function curveLookup(curve, elev)
    local n = #curve
    if n == 0 then return 0.0 end
    if elev >= curve[1].elev then return curve[1].bias end
    if elev <= curve[n].elev then return curve[n].bias end
    for i = 1, n - 1 do
        local a, b = curve[i], curve[i + 1]
        if elev <= a.elev and elev >= b.elev then
            local t = (a.elev - elev) / (a.elev - b.elev)
            return lerp(a.bias, b.bias, t)
        end
    end
    return curve[n].bias
end

-- ============== INTERNAL: cvar push machinery ==============

-- Cvar pushes ride the shared game-thread path in core/utils.lua.
local function scheduleExec(cmds) return Utils.ExecConsoleCommands(cmds) end

-- Garage exposure trim + dark look (Alt+E/Alt+G outside photo sessions;
-- 2026-07-28 decision: the garage look is dialable while browsing cars).
-- Same levers on the garage-neutral lens, reset on leaving the garage.
local garageNudgeSteps = 0
local garageDarkOn = false

local lastDriveState = nil
local function noteDriveState(state)
    if state == lastDriveState then return end
    if lastDriveState == "garage" and (garageNudgeSteps ~= 0 or garageDarkOn) then
        garageNudgeSteps = 0
        garageDarkOn = false
    end
    -- Config-seeded garage look (2026-08-11): entering the garage starts from
    -- the shipped dark-look baseline (field tuning: dark lens 30 * 1.25^-33
    -- ~= lens 0.019); Alt+G / Alt+E adjust on top, the exit reset above plus
    -- this seed make every visit start identical.
    if state == "garage" and Config.LightCycle then
        local gd = Config.LightCycle.GarageDark
        if type(gd) == "table" and gd.Enabled then
            garageDarkOn = true
            garageNudgeSteps = tonumber(gd.NudgeSteps) or 0
            lastApplied.lens = nil
            lastCheckClock = 0.0
        end
    end
    lastDriveState = state
    local tag = "?"
    local actors = getActors()
    if actors and actors.GetWorldTag then
        pcall(function() tag = actors.GetWorldTag() or "?" end)
    end
    Log.Info(MODULE, "Drive state: " .. state, {world = tag})
end

--- Photo-session lens: the 3.4.0 curve keyed on sun elevation, the fixed
--- garage value with no sun, the indoor value under a roof, the Alt+G dark
--- look winning the branch, then the Alt+E trim on top.
local function photoLens(elev)
    local lens
    if photoDarkOn then
        lens = PHOTO_DARK_LENS
    elseif photoCoveredLatch and PHOTO_COVERED_LENS then
        lens = PHOTO_COVERED_LENS
    elseif elev == nil then
        lens = PHOTO_GARAGE_LENS
    else
        lens = curveLookup(PHOTO_LENS_CURVE, elev)
    end
    if photoNudgeSteps ~= 0 then
        lens = lens * (PHOTO_NUDGE_STEP ^ photoNudgeSteps)
    end
    return lens
end

--- Push the cvar trio; skips values unchanged since the last push.
local function applyValues(sky, leak, lens, elev, reason)
    local eps = 1e-4
    if tune.sky  then sky  = tune.sky  end
    if tune.leak then leak = tune.leak end
    -- Photo session: manual metering is live and the 3.4.0 lens curve sets
    -- the level from sun elevation (garage/PA menu: the fixed garage value,
    -- no sun there; covered sessions: the fixed indoor level, a lit bore does
    -- not follow the sun). Lens carries the exposure alone: photomode never
    -- scales the skylight (the config ManualCurve sky column is 3.4.0 reference).
    if photoExpFrozen and #PHOTO_LENS_CURVE > 0 then
        lens = photoLens(elev)
    end
    local cmds = {}
    if not lastApplied.sky  or math.abs(sky  - lastApplied.sky)  >= eps then
        cmds[#cmds + 1] = string.format("%s %.6f", CVAR_SKY,  sky)
    end
    if not lastApplied.leak or math.abs(leak - lastApplied.leak) >= eps then
        cmds[#cmds + 1] = string.format("%s %.6f", CVAR_LEAK, leak)
    end
    if not lastApplied.lens or math.abs(lens - lastApplied.lens) >= eps then
        cmds[#cmds + 1] = string.format("%s %.6f", CVAR_LENS, lens)
    end
    if #cmds == 0 then return true end

    local scheduled = scheduleExec(cmds)
    lastApplied.sky, lastApplied.leak, lastApplied.lens = sky, leak, lens

    Log.Info(MODULE, "Applied light", {
        sun_elev = elev and string.format("%.1f", elev) or "nil",
        reason = reason or "",
        sky = sky, leak = leak, lens = lens,
        scheduled = scheduled,
    })
    return scheduled
end

-- ============== INTERNAL: per-course PP pipeline one-shots ==============

--- One-shot (game thread): adaptation speeds, PP look overrides and the
--- skylight-translucency kill, once per course when the module arms;
--- ppShotsReadbackGT re-verifies ~8s later. World state re-checked at run time.
local function applyPPShotsGT()
    local actors = getActors()
    if actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
        ppShotsApplied = false   -- retry on the next update; world is mid-swap
        return
    end

    -- Adaptation speeds onto BP_CourseSky's composited PP component
    local pp = nil
    pcall(function()
        local a = FindFirstOf("BP_CourseSky_C")
        if a and a.IsValid and a:IsValid() then pp = a.PostProcess end
    end)
    if not (pp and pp.IsValid and pp:IsValid()) then
        Log.Debug(MODULE, "PP one-shots: no BP_CourseSky in this world (menu/PA)")
        pp = nil
    end

    if pp and (ADAPT_UP or ADAPT_DOWN) then
        local info = {}
        local ok = pcall(function()
            local s = pp.Settings
            info.stock_up = tostring(s.AutoExposureSpeedUp)
            info.stock_down = tostring(s.AutoExposureSpeedDown)
            if ADAPT_UP then
                s.bOverride_AutoExposureSpeedUp = true
                s.AutoExposureSpeedUp = ADAPT_UP
                info.up = ADAPT_UP
            end
            if ADAPT_DOWN then
                s.bOverride_AutoExposureSpeedDown = true
                s.AutoExposureSpeedDown = ADAPT_DOWN
                info.down = ADAPT_DOWN
            end
        end)
        if ok then
            Log.Info(MODULE, "Adapt speeds applied", info)
        else
            Log.Warn(MODULE, "Adapt speeds: write failed")
        end
    end

    -- Look overrides (Config.LightCycle.PostProcess): numbers/bools write
    -- directly, struct fields (color/vector) component-wise into the live struct.
    if pp and PP_OVERRIDES then
        local nOk, failed = 0, {}
        for name, val in pairs(PP_OVERRIDES) do
            local ok = pcall(function()
                local s = pp.Settings
                if type(val) == "table" then
                    local sv = s[name]
                    for k, comp in pairs(val) do sv[k] = comp end
                else
                    s[name] = val
                end
                s["bOverride_" .. name] = true
            end)
            if ok then nOk = nOk + 1 else failed[#failed + 1] = name end
        end
        Log.Info(MODULE, "PP overrides applied", {
            count = nOk,
            failed = (#failed > 0) and table.concat(failed, " ") or nil,
        })
    end

    -- Skylight off translucents: that feed paints leaked sky onto glass and
    -- taillight lenses under ceilings (the translucency probe grid is too
    -- coarse to occlude it). Free to kill: glass is reflection dominated and
    -- opaque surfaces keep their occluded skylight via Lumen GI.
    if KILL_SKY_TRANSLUCENT then
        local written, found = 0, 0
        pcall(function()
            local all = FindAllOf("SkyLightComponent")
            if not all then return end
            for _, c in ipairs(all) do
                if c and c.IsValid and c:IsValid() then
                    local full = ""
                    pcall(function() full = c:GetFullName() end)
                    if full:find("BP_CourseSky") then
                        found = found + 1
                        if pcall(function() c.bAffectTranslucentLighting = false end) then
                            written = written + 1
                        end
                    end
                end
            end
        end)
        Log.Info(MODULE, "Skylight translucent lighting killed", {
            written = written, courseSkylights = found,
        })
    end

    ppShotsWroteClock = os.clock()
end

--- Delayed readback ~8s after the writes: held=false means a per-tick writer
--- re-asserts that field and the kill/speeds need a carrier (measure first,
--- do not silently re-assert).
local function ppShotsReadbackGT()
    -- Teardown re-check as in applyPPShotsGT: ~8s after arm a quick course
    -- exit can put this mid-teardown, where FindFirstOf reads dying objects
    -- (2026-08-04).
    local actors = getActors()
    if actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
        return
    end
    pcall(function()
        local info = {}
        local a = FindFirstOf("BP_CourseSky_C")
        if a and a.IsValid and a:IsValid() then
            local pp = a.PostProcess
            if pp and pp.IsValid and pp:IsValid() then
                local s = pp.Settings
                if ADAPT_UP or ADAPT_DOWN then
                    local up, down = tonumber(s.AutoExposureSpeedUp), tonumber(s.AutoExposureSpeedDown)
                    local held = true
                    if ADAPT_UP and (up == nil or math.abs(up - ADAPT_UP) > 0.01) then held = false end
                    if ADAPT_DOWN and (down == nil or math.abs(down - ADAPT_DOWN) > 0.01) then held = false end
                    info.adapt_up = tostring(up)
                    info.adapt_down = tostring(down)
                    info.adapt_held = tostring(held)
                end
                if PP_OVERRIDES then
                    local mism = {}
                    for name, val in pairs(PP_OVERRIDES) do
                        pcall(function()
                            local cur = s[name]
                            if type(val) == "number" then
                                if math.abs((tonumber(cur) or math.huge) - val) > 0.01 then
                                    mism[#mism + 1] = name .. "=" .. tostring(cur)
                                end
                            elseif type(val) == "table" then
                                if val.X and math.abs(cur.X - val.X) > 0.01 then
                                    mism[#mism + 1] = name .. ".X=" .. tostring(cur.X)
                                end
                            elseif cur ~= val then
                                mism[#mism + 1] = name .. "=" .. tostring(cur)
                            end
                        end)
                    end
                    info.overrides_held = (#mism == 0) and "true" or table.concat(mism, " ")
                end
            end
        end
        Log.Info(MODULE, "PP one-shots readback", info)
    end)
end

-- ============== INTERNAL: sun elevation ==============

--- Approximate elevation from the game clock (fallback + sign calibration).
--- Sinusoidal arc between the measured effective sun events; peaks ~+75 deg
--- (Tokyo mid-August), bottoms ~-55 deg.
local function pseudoElevation(tod)
    if tod == nil then return nil end
    tod = tod % 2400
    if tod >= SUNRISE_TOD and tod <= SUNSET_TOD then
        local p = (tod - SUNRISE_TOD) / (SUNSET_TOD - SUNRISE_TOD)
        return 75.0 * math.sin(math.pi * p)
    end
    local nightLen = 2400 - (SUNSET_TOD - SUNRISE_TOD)
    local since = (tod - SUNSET_TOD) % 2400
    local p = since / nightLen
    return -55.0 * math.sin(math.pi * p)
end

--- Real elevation from UDS's cached sun vector (light-direction convention,
--- see SUN_VECTOR_SIGN). Returns nil when the vector is unavailable.
local function readSunElevation(uds, tod)
    local x, y, z = nil, nil, nil
    pcall(function()
        local v = uds[PROP_SUN_VECTOR]
        if v then x, y, z = v.X, v.Y, v.Z end
    end)
    if type(z) ~= "number" then return nil end
    local mag = math.sqrt((x or 0) ^ 2 + (y or 0) ^ 2 + z ^ 2)
    if mag < 0.5 then return nil end
    local raw = math.deg(math.asin(clamp(z / mag, -1.0, 1.0)))
    local elev = raw * SUN_VECTOR_SIGN

    -- Sanity check in windows that are day/night in every season at Tokyo's
    -- latitude (10:00-14:00 sun up, 22:00-03:00 sun down). Three consecutive
    -- strong disagreements = the convention likely changed in a UDS update:
    -- warn once, never auto-flip (one bad latch already cost a session).
    if type(tod) == "number" and not signWarned then
        local t = tod % 2400
        local expect = nil
        if t >= 1000 and t <= 1400 then expect = 1
        elseif t >= 2200 or t <= 300 then expect = -1 end
        if expect and math.abs(elev) >= 10.0 then
            if (elev >= 0 and expect < 0) or (elev < 0 and expect > 0) then
                signViolations = signViolations + 1
                if signViolations >= 3 then
                    signWarned = true
                    Log.Warn(MODULE, "Sun vector sign LOOKS WRONG (persistent day/night mismatch)"
                        .. ": check Config.LightCycle.SunVectorSign", {
                        elev = string.format("%.1f", elev), tod = string.format("%.0f", t),
                    })
                end
            else
                signViolations = 0
            end
        end
    end

    return elev
end

local function biasLookup(elev)
    return curveLookup(BIAS_CURVE, elev)
end


--- Write the bias to UDS's knobs: Day and Night get the same value (the
--- elevation curve owns the number, UDS's day/night blend becomes a no-op);
--- scenario knobs zeroed once per course so UDS cannot double-blend.
--- Primitive writes, change-gated.
local function writeBiasKnobs(uds, value)
    if not scenarioZeroed then
        scenarioZeroed = true
        pcall(function()
            uds["Exposure Bias Cloudy"] = 0.0
            uds["Exposure Bias Foggy"] = 0.0
            uds["Exposure Bias Dusty"] = 0.0
        end)
    end
    if lastBias ~= nil and math.abs(value - lastBias) < 0.02 then return end
    local ok = pcall(function()
        uds["Exposure Bias Day"] = value
        uds["Exposure Bias Night"] = value
    end)
    if ok then
        lastBias = value
        Log.Info(MODULE, "Applied bias", {
            ev = string.format("%.2f", value),
            sun_elev = lastElevation and string.format("%.1f", lastElevation) or "nil",
        })
    end
end

--- One-shot night scene floors (per course): scale "Directional Lights
--- Absent Brightness" from the fresh actor's stock value (never compounds),
--- set the absolute cloudy/overcast floors if configured, then bake with
--- Hard Reset Cache (UDS samples some properties at setup, not per tick).
local function applyAbsentBrightness(uds)
    if absentApplied then return end
    absentApplied = true
    local wrote = false

    if ABSENT_MULT and math.abs(ABSENT_MULT - 1.0) >= 1e-3 then
        local stock = nil
        pcall(function() stock = uds[PROP_ABSENT_BRIGHTNESS] end)
        stock = tonumber(stock)
        if stock == nil then
            Log.Warn(MODULE, "Night floor: stock read failed (skipping)", {prop = PROP_ABSENT_BRIGHTNESS})
        else
            local new = stock * ABSENT_MULT
            local ok = pcall(function() uds[PROP_ABSENT_BRIGHTNESS] = new end)
            if ok then
                wrote = true
                Log.Info(MODULE, "Night scene floor applied", {
                    stock = string.format("%.4f", stock),
                    new = string.format("%.4f", new),
                    mult = ABSENT_MULT,
                })
            else
                Log.Warn(MODULE, "Night floor: write failed", {prop = PROP_ABSENT_BRIGHTNESS})
            end
        end
    end

    if NIGHT_CLOUDY ~= nil then
        local stockC = nil
        pcall(function() stockC = uds[PROP_NIGHT_CLOUDY] end)
        local okC = pcall(function() uds[PROP_NIGHT_CLOUDY] = NIGHT_CLOUDY end)
        if okC then
            wrote = true
            Log.Info(MODULE, "Cloudy-night floor applied", {
                stock = tostring(stockC),
                new = NIGHT_CLOUDY,
            })
        else
            Log.Warn(MODULE, "Cloudy-night floor: write failed", {prop = PROP_NIGHT_CLOUDY})
        end
    end

    if OVERCAST_NIGHT ~= nil then
        local stockO = nil
        pcall(function() stockO = uds[PROP_OVERCAST_NIGHT] end)
        local okO = pcall(function() uds[PROP_OVERCAST_NIGHT] = OVERCAST_NIGHT end)
        if okO then
            wrote = true
            Log.Info(MODULE, "Overcast night keep-fraction applied", {
                stock = tostring(stockO),
                new = OVERCAST_NIGHT,
            })
        else
            Log.Warn(MODULE, "Overcast night: write failed", {prop = PROP_OVERCAST_NIGHT})
        end
    end

    -- Bake only when a floor actually changed: shipped config writes none
    -- of them, and an unconditional Hard Reset Cache on PA entry landed a
    -- no-blend cache refill mid-carry (visible sky snap).
    if not wrote then return end

    -- Hard Reset Cache is a UFunction and this path runs on the 8 Hz async
    -- tick; a UFunction off the game thread can access-violate natively and
    -- pcall does not catch that. Marshal it, and re-resolve UDS inside the
    -- closure: a ref carried across the thread hop can pass IsValid on freed
    -- memory, the pattern behind the 2026-07-14 PA crash.
    local function bakeGT()
        local a = getActors()
        local u = a and a.GetUDS and a.GetUDS() or nil
        if not u then return end
        local fn = u["Hard Reset Cache"]
        if not fn then return end
        local ok = pcall(function() fn(u) end)
        Log.Info(MODULE, "Night floor bake (Hard Reset Cache)", {ok = ok})
    end
    if ExecuteInGameThread then
        pcall(function() GT.Run(bakeGT) end)
    else
        pcall(bakeGT)
    end
end

-- ============== PHOTOMODE MANUAL METERING (legacy lens curve) ==============
-- photomode.lua drives this on session open/close. Manual metering
-- (MethodOverride 3) is the only mode where the photomode aperture drives
-- exposure (field-verified; the applied f-stop is unreachable from Lua). The
-- level rides the lens-attenuation cvar keyed on sun elevation (the 3.4.0
-- curve, applied in applyValues). Histogram AE + neutral lens return on close.

function LightCycle.SetPhotoExposureFreeze(on)
    if on == photoExpFrozen then return end
    photoExpFrozen = on
    -- Fresh session = default look: drop the previous session's Alt+E trim
    -- and Alt+G dark look (predictable open state)
    if on then
        photoNudgeSteps = 0
        photoDarkOn = false
    end
    -- Covered check, latched once at open (the car is parked during a
    -- session): road-data roof = lit-interior session = fixed indoor lens
    photoCoveredLatch = false
    if on and PHOTO_COVERED_LENS then
        pcall(function()
            local T = getTunnels()
            photoCoveredLatch = (T and T.IsCovered and T.IsCovered()) or false
        end)
    end
    if on then
        -- The session lens rides the same batch as the metering switch: on its
        -- own the switch landed one pump before the lens push, a dark blink of
        -- 2.7 to 5 stops at every open
        local cmds = { "r.EyeAdaptation.MethodOverride 3" }
        if #PHOTO_LENS_CURVE > 0 then
            local lens = photoLens((lastDriveState == "garage") and nil or lastElevation)
            cmds[#cmds + 1] = string.format("%s %.6f", CVAR_LENS, lens)
            lastApplied.lens = lens
        end
        scheduleExec(cmds)
    else
        -- Neutral lens in the same batch as the metering switch (field bug
        -- 2026-07-27): a close at world teardown (quitting the course from
        -- inside photomode) has no armed Update to ride, so the session lens
        -- stayed in the process-global cvar into the menus ("exposure never
        -- came back"). This batch is world-independent.
        scheduleExec({
            "r.EyeAdaptation.MethodOverride -1",
            string.format("%s %.6f", CVAR_LENS, NEUTRAL_LENS),
        })
        lastApplied.lens = NEUTRAL_LENS
    end
    -- Re-push the cvar trio on the next main tick (125ms): the lens value
    -- must land with the metering switch
    lastCheckClock = 0.0
    Log.Info(MODULE, on and "Photo session: manual metering ON (legacy lens curve)"
        or "Photo session: manual metering OFF",
        on and {covered = photoCoveredLatch and "YES (indoor lens)" or nil} or nil)
end

--- Alt+E family: exposure trim. dir > 0 = brighter step, dir < 0 = darker.
--- Live during a photo session and in the plain garage (the garage look is
--- cvar-driven, so the same lens lever works there without photomode).
--- Returns the new step count and effective multiplier for the keybind log,
--- nil when neither context is active.
function LightCycle.NudgePhotoExposure(dir)
    if photoExpFrozen then
        photoNudgeSteps = photoNudgeSteps + ((dir or 1) > 0 and 1 or -1)
        lastApplied.lens = nil  -- force the cvar push even on a same-value round trip
        lastCheckClock = 0.0    -- apply on the next main tick (125ms)
        local mult = PHOTO_NUDGE_STEP ^ photoNudgeSteps
        Log.Info(MODULE, "Photo exposure nudge", {
            steps = photoNudgeSteps,
            mult = string.format("%.3f", mult),
            dark = photoDarkOn or nil,
            covered = photoCoveredLatch or nil,
        })
        return photoNudgeSteps, mult
    end
    if lastDriveState == "garage" then
        garageNudgeSteps = garageNudgeSteps + ((dir or 1) > 0 and 1 or -1)
        lastApplied.lens = nil
        lastCheckClock = 0.0
        local mult = PHOTO_NUDGE_STEP ^ garageNudgeSteps
        Log.Info(MODULE, "Garage exposure nudge", {
            steps = garageNudgeSteps,
            mult = string.format("%.3f", mult),
            dark = garageDarkOn or nil,
        })
        return garageNudgeSteps, mult
    end
    return nil
end

--- Alt+G: toggle the dark look inside a photo session, or the garage's own
--- dark look outside one. Returns the new state, nil when neither context
--- is active.
function LightCycle.TogglePhotoDarkLook()
    if photoExpFrozen then
        photoDarkOn = not photoDarkOn
        lastApplied.lens = nil
        lastCheckClock = 0.0
        Log.Info(MODULE, "Photo dark look " .. (photoDarkOn and "ON" or "OFF"),
            {lens = photoDarkOn and PHOTO_DARK_LENS or nil})
        return photoDarkOn
    end
    if lastDriveState == "garage" then
        garageDarkOn = not garageDarkOn
        lastApplied.lens = nil
        lastCheckClock = 0.0
        Log.Info(MODULE, "Garage dark look " .. (garageDarkOn and "ON" or "OFF"),
            {lens = garageDarkOn and PHOTO_DARK_LENS or nil})
        return garageDarkOn
    end
    return nil
end

-- ============== DISPLAY PROFILE (HDR vs SDR) ==============
-- The game lifts shadows 1.5x + global 1.2x on HDR displays only (BP_HDR
-- grades when GameUserSettings.IsHdrEnabled); the config look tables are
-- tuned on top of that lift and crush on SDR. Resolved once per session on
-- the first Update: "auto" reads the live HDR state and
-- Config.LightCycle.DisplayProfile forces "hdr"/"sdr"; "sdr" swaps
-- PP_OVERRIDES/BIAS_CURVE for the Config.LightCycle.SDR tables. An
-- in-session HDR toggle is not tracked (restart to re-resolve).

local DISPLAY_PROFILE_CFG = "auto"
local SDR_TABLES = nil
local displayProfile = nil   -- resolved: "hdr" | "sdr"
local profileProbeInFlight = false

--- Latch the resolved profile and swap the SDR tables. Pure Lua, safe
--- from either thread; first caller wins (a probe landing after a forced
--- fallback is a no-op).
local function finishDisplayProfile(prof, src)
    if displayProfile then return end
    displayProfile = prof
    if prof == "sdr" and type(SDR_TABLES) == "table" then
        if type(SDR_TABLES.PostProcess) == "table" then
            PP_OVERRIDES = next(SDR_TABLES.PostProcess) ~= nil
                and SDR_TABLES.PostProcess or nil
        end
        if type(SDR_TABLES.BiasCurve) == "table"
            and #SDR_TABLES.BiasCurve > 0 then
            BIAS_CURVE = SDR_TABLES.BiasCurve
            table.sort(BIAS_CURVE, function(a, b) return a.elev > b.elev end)
        end
    end
    Log.Info(MODULE, "Display profile", {profile = prof, source = src})
end

--- force=true resolves even when the HDR state is unreadable (falls back to
--- "hdr", the historical look) so the PP one-shots never stall on it. The
--- readback runs in a GT closure: a bare FindFirstOf + UFunction call on the
--- 8 Hz async tick, retrying from mod boot while worlds churn, was the
--- wet_grip 3.8.0 crash class (fixed 2026-08-04).
local function resolveDisplayProfile(force)
    if displayProfile then return end
    local prof = DISPLAY_PROFILE_CFG
    if prof == "hdr" or prof == "sdr" then
        finishDisplayProfile(prof, "config")
        return
    end
    if not profileProbeInFlight and ExecuteInGameThread then
        profileProbeInFlight = true
        local ok = pcall(function()
            GT.Run(function()
                local hdrOn = nil
                pcall(function()
                    local gus = FindFirstOf("GameUserSettings")
                    if gus and gus.IsValid and gus:IsValid() then
                        pcall(function() hdrOn = gus.bUseHDRDisplayOutput end)
                        pcall(function()
                            local live = gus:IsHdrEnabled()
                            if type(live) == "boolean" then hdrOn = live end
                        end)
                    end
                end)
                if hdrOn ~= nil then
                    finishDisplayProfile(hdrOn and "hdr" or "sdr", "auto")
                end
                profileProbeInFlight = false
            end)
        end)
        if not ok then profileProbeInFlight = false end
    end
    if force and not displayProfile then
        finishDisplayProfile("hdr", "fallback (HDR state unreadable)")
    end
end

-- ============== PUBLIC API ==============

function LightCycle.Init()
    if isInitialized then return true end

    local cfg = Config.LightCycle
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.UpdateIntervalSeconds then UPDATE_INTERVAL = cfg.UpdateIntervalSeconds end
        if cfg.LeakAlbedo then LEAK_ALBEDO = cfg.LeakAlbedo end
        if type(cfg.SkylightMultiplier) == "number" then NEUTRAL_SKY = cfg.SkylightMultiplier end
        if cfg.AbsentBrightnessMult then ABSENT_MULT = cfg.AbsentBrightnessMult end
        if cfg.NightCloudyBrightness then NIGHT_CLOUDY = cfg.NightCloudyBrightness end
        if cfg.OvercastBrightnessNight then OVERCAST_NIGHT = cfg.OvercastBrightnessNight end
        if type(cfg.BiasCurve) == "table" then BIAS_CURVE = cfg.BiasCurve end
        if cfg.AdaptSpeedUp then ADAPT_UP = cfg.AdaptSpeedUp end
        if cfg.AdaptSpeedDown then ADAPT_DOWN = cfg.AdaptSpeedDown end
        if cfg.KillSkylightTranslucentLighting ~= nil then
            KILL_SKY_TRANSLUCENT = cfg.KillSkylightTranslucentLighting
        end
        if type(cfg.DisplayProfile) == "string" then DISPLAY_PROFILE_CFG = cfg.DisplayProfile end
        if type(cfg.SDR) == "table" then SDR_TABLES = cfg.SDR end
        if type(cfg.PostProcess) == "table" and next(cfg.PostProcess) ~= nil then
            PP_OVERRIDES = cfg.PostProcess
        end
        if cfg.SunVectorSign then SUN_VECTOR_SIGN = cfg.SunVectorSign end
        if cfg.SunriseTOD then SUNRISE_TOD = cfg.SunriseTOD end
        if cfg.SunsetTOD then SUNSET_TOD = cfg.SunsetTOD end
        if type(cfg.Tune) == "table" then
            if cfg.Tune.Step then TUNE_STEP = cfg.Tune.Step end
            if cfg.Tune.RoughnessBaseline then ROUGH_BASELINE = cfg.Tune.RoughnessBaseline end
        end
    end

    -- Photomode manual exposure curve (the 3.4.0 anchors), normalized to
    -- an elev/bias table for curveLookup. Only the lens column drives
    -- anything; the config sky column is 3.4.0 reference data.
    pcall(function()
        local mc = Config.PhotoMode and Config.PhotoMode.ManualCurve
        if type(mc) == "table" and #mc > 0 then
            PHOTO_LENS_CURVE = {}
            for _, a in ipairs(mc) do
                if type(a.elev) == "number" then
                    PHOTO_LENS_CURVE[#PHOTO_LENS_CURVE + 1] =
                        { elev = a.elev, bias = tonumber(a.lens) or NEUTRAL_LENS }
                end
            end
            table.sort(PHOTO_LENS_CURVE, function(x, y) return x.elev > y.elev end)
        end
        local g = Config.PhotoMode and Config.PhotoMode.ManualGarage
        if type(g) == "table" then
            PHOTO_GARAGE_LENS = tonumber(g.Lens) or PHOTO_GARAGE_LENS
        end
        local cl = Config.PhotoMode and Config.PhotoMode.CoveredLens
        if type(cl) == "number" and cl > 0 then
            PHOTO_COVERED_LENS = cl
        end
        local ns = Config.PhotoMode and Config.PhotoMode.NudgeStep
        if type(ns) == "number" and ns > 1.0 then
            PHOTO_NUDGE_STEP = ns
        end
        local dl = Config.PhotoMode and Config.PhotoMode.DarkLook
        if type(dl) == "table" and tonumber(dl.Lens) then
            PHOTO_DARK_LENS = tonumber(dl.Lens)
        end
    end)

    -- PA mode lives outside the LightCycle block (Config.PA, shared with
    -- main.lua): any non-stock mode makes the PA scene follow the elevation
    -- path instead of the garage constants.
    pcall(function()
        PA_FOLLOW = Config.PA ~= nil and Config.PA.Mode ~= nil
            and Config.PA.Mode ~= "stock"
    end)

    -- Sort anchors descending by elevation so the lookup can assume order
    table.sort(BIAS_CURVE, function(a, b) return a.elev > b.elev end)

    isInitialized = true
    State.SetModuleStatus("light_cycle", true)

    if not enabled then
        Log.Info(MODULE, "Light cycle module disabled in config")
        return true
    end

    Log.Info(MODULE, "Initializing light cycle module", {
        biasAnchors = #BIAS_CURVE,
        intervalSec = UPDATE_INTERVAL,
        absentMult = ABSENT_MULT,
    })
    return true
end

--- True when this module is the active exposure provider (keybinds/headlights
--- route here). Checks the module toggle too: consumers require() this file
--- directly, bypassing main.lua's nil-ing, so a toggled-off module would
--- otherwise still capture the Alt+D family and the headlight elevation provider.
function LightCycle.IsActive()
    if not (isInitialized and enabled) then return false end
    local tg = Config.ModuleToggles
    if tg and tg.LightCycle == false then return false end
    return true
end

function LightCycle.OnCourseLoad()
    lastCheckClock = 0.0
    lastApplied.sky, lastApplied.leak, lastApplied.lens = nil, nil, nil
    lastElevation = nil
    absentApplied = false
    lastBias = nil          -- fresh sky spawns with knob defaults; re-write
    scenarioZeroed = false
    ppShotsApplied = false  -- fresh CourseSky/UDS = fresh one-shots
    ppShotsProbeWait = 0
    ppShotsWroteClock = nil
    ppShotsCheckDone = false
    -- A teardown-close of photomode can leave the manual-metering latch
    -- set; the cvar is process-global, so assert the restore too
    if photoExpFrozen then
        photoExpFrozen = false
        scheduleExec({
            "r.EyeAdaptation.MethodOverride -1",
            string.format("%s %.6f", CVAR_LENS, NEUTRAL_LENS),
        })
    end
    photoCoveredLatch = false
    photoNudgeSteps = 0
    photoDarkOn = false
    armed = true
end

function LightCycle.OnCourseUnload()
    armed = false
end

--- Per-tick update, throttled to UPDATE_INTERVAL (writes are change-gated,
--- so 1s is nearly free).
function LightCycle.Update()
    if not enabled then return true end

    -- Display profile: resolve as early as possible (retries silently while
    -- GameUserSettings is not readable yet)
    if not displayProfile then resolveDisplayProfile(false) end

    local now = os.clock()
    local actors = getActors()
    if not actors then return true end

    if (now - lastCheckClock) < UPDATE_INTERVAL then return true end
    lastCheckClock = now

    -- Garage / PA-menu worlds: neutral push (no sun there; stock adaptation
    -- meters the garage fine, this only clears Alt+Z/X/C leftovers). Exception:
    -- the PA scene (validated own UDS/UDW, unlike the garage) has a real sun,
    -- so in PA continue/freeze mode it falls through to the elevation path
    -- (armed by main's PA apply).
    if actors.IsInGarage and actors.IsInGarage() then
        local paScene = PA_FOLLOW and actors.IsInPAScene and actors.IsInPAScene()
        if not paScene then
            noteDriveState("garage")
            -- Garage Alt+G/Alt+E ride on the neutral lens exactly like
            -- their photo-session versions ride the session branch
            local gLens = garageDarkOn and PHOTO_DARK_LENS or NEUTRAL_LENS
            if garageNudgeSteps ~= 0 then
                gLens = gLens * (PHOTO_NUDGE_STEP ^ garageNudgeSteps)
            end
            applyValues(NEUTRAL_SKY, LEAK_ALBEDO, gLens, nil,
                (garageDarkOn or garageNudgeSteps ~= 0)
                    and "garage-trimmed" or "garage-neutral")
            return true
        end
    end

    if not armed then
        noteDriveState("idle (not garage, course not armed)")
        return true
    end

    local uds = actors.GetUDS and actors.GetUDS()
    if not uds then
        noteDriveState("armed, no UDS")
        return true
    end

    -- Per-course pipeline one-shots (game thread) + their delayed readback.
    -- The display profile must settle first (they consume PP_OVERRIDES);
    -- force the fallback if auto-detect never resolved.
    if not ppShotsApplied then
        if not displayProfile then
            -- The auto probe may still be in flight (fast UDS discovery); a
            -- forced HDR fallback now would first-caller-win over a real SDR
            -- result, so give the probe a few Updates.
            if profileProbeInFlight and ppShotsProbeWait < 5 then
                ppShotsProbeWait = ppShotsProbeWait + 1
                return true
            end
            resolveDisplayProfile(true)
        end
        ppShotsApplied = true
        if ExecuteInGameThread then
            pcall(function() GT.Run(applyPPShotsGT) end)
        end
    elseif ppShotsWroteClock and not ppShotsCheckDone
        and (now - ppShotsWroteClock) >= 8.0 then
        ppShotsCheckDone = true
        if ExecuteInGameThread then
            pcall(function() GT.Run(ppShotsReadbackGT) end)
        end
    end

    local tod = nil
    local t = getTimeOfDay()
    if t then
        local ok, v = pcall(t.GetCurrentTOD)
        if ok then tod = v end
    end

    -- Sun elevation: real vector when available, pseudo (clock) fallback when
    -- the vector read fails.
    local elev = readSunElevation(uds, tod)
    if elev == nil then
        elev = pseudoElevation(tod)
        if elev ~= nil and not usedPseudoLogged then
            usedPseudoLogged = true
            Log.Info(MODULE, "Using pseudo elevation (sun vector not readable yet)")
        end
    end
    if elev == nil then
        noteDriveState("armed, no elevation")
        return true
    end
    lastElevation = elev

    -- Stock auto-exposure + elevation-driven EV bias via UDS's confirmed-live
    -- knobs. Cvars held at engine-neutral (one push per course).
    noteDriveState("course")
    applyValues(NEUTRAL_SKY, LEAK_ALBEDO, NEUTRAL_LENS, elev, "neutral-base")

    writeBiasKnobs(uds, biasLookup(elev))

    -- Night scene floors one-shot (needs a valid UDS; harmless if unset)
    applyAbsentBrightness(uds)

    return true
end

--- Last computed sun elevation in degrees (nil before the first course tick).
function LightCycle.GetSunElevation()
    return lastElevation
end

-- ============== FEEDBACK + SKYLIGHT TUNING (Alt+D family) ==============

local function captureContext()
    local tod, todStr = nil, "--:--"
    local t = getTimeOfDay()
    if t then
        local ok, v = pcall(t.GetCurrentTOD)
        if ok then tod = v end
        if t.FormatTime then pcall(function() todStr = t.FormatTime(tod) end) end
    end

    local preset = "unknown"
    pcall(function() preset = State.GetCurrentPreset() or "none" end)

    local where = "unknown"
    local actors = getActors()
    if actors then
        if actors.IsInGarage and actors.IsInGarage() then
            where = "garage"
        elseif actors.GetWorldTag then
            pcall(function() where = actors.GetWorldTag() or "unknown" end)
        end
    end

    return tod, todStr, preset, where
end

--- @param direction string "dark" | "bright"
function LightCycle.LogFeedback(direction)
    local tod, todStr, preset, where = captureContext()

    local covered = false
    pcall(function()
        local T = getTunnels()
        if T and T.IsCovered then covered = T.IsCovered() end
    end)

    Log.Info("ExposureTune", "FEEDBACK too-" .. tostring(direction), {
        verdict      = direction,
        time         = todStr,
        tod          = tod and string.format("%.0f", tod) or "nil",
        sun_elev     = lastElevation and string.format("%.1f", lastElevation) or "nil",
        driver       = "elevation",
        weather      = preset,
        profile      = displayProfile or "unresolved",
        where        = where,
        applied_bias = lastBias and string.format("%.2f", lastBias) or "nil",
        tunnel       = covered and "YES" or nil,
        applied_sky  = lastApplied.sky,
        applied_leak = lastApplied.leak,
        applied_lens = lastApplied.lens,
    })
end

--- @param which string "sky" | "leak" | "rough"
--- @param dir number +1 | -1
function LightCycle.NudgeSkylight(which, dir)
    local lim = TUNE_LIMITS[which]
    if not lim then
        Log.Warn(MODULE, "NudgeSkylight: unknown cvar key", {which = tostring(which)})
        return
    end

    local cur = tune[which]
    if cur == nil then
        if which == "rough" then
            cur = ROUGH_BASELINE
        else
            cur = lastApplied[which] or lim.fallback
        end
    end

    local new = clamp(cur + dir * TUNE_STEP, lim.min, lim.max)
    if new == cur then return end

    tune[which] = new

    local cvar = (which == "sky" and CVAR_SKY) or (which == "leak" and CVAR_LEAK) or CVAR_ROUGH
    scheduleExec({ string.format("%s %.6f", cvar, new) })
    if which ~= "rough" then lastApplied[which] = new end

    Log.Info("SkylightTune", "NUDGE " .. which .. (dir > 0 and " +" or " -"), {
        value = new,
        sun_elev = lastElevation and string.format("%.1f", lastElevation) or "nil",
    })
end

--- Log a confirmed-good skylight datapoint (Alt+V).
function LightCycle.LogSkylightConfirm()
    local tod, todStr, preset, where = captureContext()
    Log.Info("SkylightTune", "DATAPOINT", {
        time = todStr,
        tod = tod and string.format("%.0f", tod) or "nil",
        sun_elev = lastElevation and string.format("%.1f", lastElevation) or "nil",
        weather = preset,
        where = where,
        sky = tune.sky or lastApplied.sky,
        leak = tune.leak or lastApplied.leak,
        rough = tune.rough or ROUGH_BASELINE,
        lens = lastApplied.lens,
    })
end

--- Clear the skylight tuning overrides (Alt+Shift+V): back to the curve.
function LightCycle.ResetSkylightTune()
    tune.sky, tune.leak, tune.rough = nil, nil, nil
    -- Force a fresh push of curve values on the next update
    lastApplied.sky, lastApplied.leak, lastApplied.lens = nil, nil, nil
    lastCheckClock = 0.0
    scheduleExec({ string.format("%s %.6f", CVAR_ROUGH, ROUGH_BASELINE) })
    Log.Info("SkylightTune", "RESET to curve")
end

--- Alias so the module can be ticked as either Tick() or Update().
LightCycle.Tick = LightCycle.Update

return LightCycle
