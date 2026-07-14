-- TXR Weather Mod v3.0
-- systems/light_cycle.lua
-- Exposure + look. Stock auto-exposure runs; this module:
--   1. Can bias it via UDS "Exposure Bias Day/Night" from the sun's REAL
--      elevation (BiasCurve; season-proof, unlike a clock table).
--   2. Applies per-course one-shots onto the course sky's main PP
--      component: adaptation speeds, the optional compensation-curve kill,
--      and the Config.LightCycle.PostProcess look overrides. All writes are
--      readback-verified ("held=false" = a per-tick writer owns that field;
--      measure, don't silently re-assert).
--   3. One-shot UDS night floors + Hard Reset Cache bake.
--   4. Neutral cvar parking + the garage neutral push (no valid UDS there)
--      + the Alt+Z/X/C skylight tuning and Alt+D feedback keys.
-- Tunnel/rain detection lives in systems/tunnels.lua; per-volume exposure
-- writes are a closed dead end (non-blendable fields snap at the blend
-- edge). History for all of this: HANDOFF.md.

local LightCycle = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")
local Config = require("config")

-- Lazy-loaded to avoid circular dependencies
local Actors = nil
local TimeOfDay = nil
local Tunnels = nil
local UEHelpers = nil

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
local PROP_COMP_CURVE = "Exposure Compensation Curve"

-- Engine auto-exposure ADAPTATION speeds (f-stops/sec), written once per
-- course onto BP_CourseSky's composited PostProcess component. UE defaults
-- (3 up / 1 down) are the felt "exposure reacts slowly" under bridges and
-- at portals. nil = leave stock. Write verified to stick (readback).
local ADAPT_UP, ADAPT_DOWN = nil, nil

-- Compensation curve kill (see header). false = leave the devs' curve alone.
local KILL_COMP_CURVE = true

-- Skylight off translucents (Config.LightCycle.KillSkylightTranslucentLighting):
-- bAffectTranslucentLighting=false on the course skylights, once per course.
local KILL_SKY_TRANSLUCENT = false

-- Generic post-process look overrides (Config.LightCycle.PostProcess):
-- field name -> value, written with bOverride flags onto the course sky's
-- main PP component in the same per-course one-shot, verified by the
-- readback. Vector/color fields arrive as {X=,Y=,Z=,W=} tables.
local PP_OVERRIDES = nil

-- Bias output: drives UDS's Exposure Bias knobs (user-confirmed live) on top
-- of stock auto-exposure.
local BIAS_CURVE = {}

-- Engine-neutral cvar values (sky mult 1.0, lens 0.78 = UE physical default):
-- pushed once per course so nothing from the old cvar era masks the
-- UDS-driven picture.
local NEUTRAL_SKY, NEUTRAL_LENS = 1.0, 0.78

-- DIAGNOSTIC neutral-cvars mode (Config.LightCycle.DiagnosticNeutralCvars):
-- pushes the neutral values everywhere incl. the garage and skips the bias
-- writes; the picture then shows RAW UDS light + the source-lever one-shots
-- with nothing from the exposure layer masking it. TEMPORARY, testing only.
local DIAGNOSTIC = false

-- Pseudo-elevation fallback (also calibrates the vector sign): effective sun
-- events measured on the stock install (DST-shifted).
local SUNRISE_TOD, SUNSET_TOD = 600.0, 1930.0

-- ============== STATE ==============
local isInitialized = false
local lastCheckClock = 0.0
local lastElevation = nil            -- last computed sun elevation (degrees)
local lastDiagElev = nil
local lastBias = nil
local scenarioZeroed = false
local absentApplied = false          -- one-shot flag for the night floors
local armed = false                  -- course gate (fresh UDS reads garbage
                                     -- before the restore has run)

-- One-shot PP pipeline writes + their delayed readback (per course)
local ppShotsApplied = false
local ppShotsWroteClock = nil
local ppShotsCheckDone = false

-- Photomode session state (SetPhotoExposureFreeze) and the 3.4.0 manual
-- exposure curves it applies (Config.PhotoMode.ManualCurve, normalized in
-- Init to two elev/bias tables for curveLookup). Declared here because
-- applyValues sits above the photomode section (local-ordering rule).
local photoExpFrozen = false
local PHOTO_SKY_CURVE = {}
local PHOTO_LENS_CURVE = {}
local PHOTO_GARAGE_SKY = 1.005   -- the 3.4.0 garage pair (no sun there)
local PHOTO_GARAGE_LENS = 30.0
local PHOTO_USE_SKY = false      -- apply the curve's sky column too
                                 -- (Config.PhotoMode.ManualCurveSky)

-- UDS sun-vector vertical convention: the cached vector is the LIGHT direction,
-- so raw Z = -sin(elevation) and the sign is a CONSTANT -1 (measured across
-- sessions: Nov midday raw=-39 with real +39; a full inverted December day when
-- v1's auto-calibration latched +1). Auto-calibration was removed because it
-- RACED the course-load restore. Config.LightCycle.SunVectorSign overrides if
-- a UDS update ever flips the convention; a trusted-window sanity check WARNS
-- on persistent disagreement but never auto-flips.
local SUN_VECTOR_SIGN = -1
local signViolations = 0
local signWarned = false
local usedPseudoLogged = false
local lastApplied = { sky = nil, leak = nil, lens = nil }

-- Skylight tuning overrides (Alt+Z/X/C): identical semantics to exposure.lua
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

local function getUEHelpers()
    if not UEHelpers then
        pcall(function() UEHelpers = require("UEHelpers") end)
    end
    return UEHelpers
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

local cachedEngine = nil
local cachedKsl = nil

local function validRef(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function getEngineRef()
    if validRef(cachedEngine) then return cachedEngine end
    local eng = nil
    pcall(function() eng = FindFirstOf("Engine") end)
    if validRef(eng) then cachedEngine = eng; return eng end
    return nil
end

local function getKslRef()
    if validRef(cachedKsl) then return cachedKsl end
    local UEH = getUEHelpers()
    if not UEH or not UEH.GetKismetSystemLibrary then return nil end
    local ksl = nil
    pcall(function() ksl = UEH.GetKismetSystemLibrary() end)
    if validRef(ksl) then cachedKsl = ksl; return ksl end
    return nil
end

--- Short object name for logs ("None" for nil), read defensively.
local function objName(o)
    if o == nil then return "None" end
    local n = nil
    pcall(function() n = o:GetFullName() end)
    if type(n) == "string" and #n > 0 then
        return n:match("([^%.%s]+)$") or n:sub(-40)
    end
    return "?"
end

-- ============== INTERNAL: cvar push machinery ==============

local execBatches = 0
local dropBatches = 0
local execLoggedOnce = false
local cmdErrWarned = false
local function scheduleExec(cmds)
    if not cmds or #cmds == 0 then return false end
    local run = function()
        local ksl = getKslRef()
        local eng = getEngineRef()
        if not ksl or not eng then
            dropBatches = dropBatches + 1
            if dropBatches == 1 or dropBatches % 50 == 0 then
                Log.Warn(MODULE, "Cvar batch DROPPED: Engine/KSL unavailable at run time",
                    {drops = dropBatches, ksl = ksl ~= nil, eng = eng ~= nil})
            end
            return
        end
        local allOk = true
        for _, cmd in ipairs(cmds) do
            local ok = pcall(function() ksl:ExecuteConsoleCommand(eng, cmd, nil) end)
            if not ok then allOk = false end
        end
        execBatches = execBatches + 1
        if not execLoggedOnce then
            execLoggedOnce = true
            Log.Info(MODULE, "First cvar batch EXECUTED on game thread", {cmds = #cmds})
        end
        if not allOk and not cmdErrWarned then
            cmdErrWarned = true
            Log.Warn(MODULE, "ExecuteConsoleCommand errored for at least one cvar push")
        end
    end
    if ExecuteInGameThread then
        return pcall(function() ExecuteInGameThread(run) end)
    end
    run()
    return true
end

local lastDriveState = nil
local function noteDriveState(state)
    if state == lastDriveState then return end
    lastDriveState = state
    local tag = "?"
    local actors = getActors()
    if actors and actors.GetWorldTag then
        pcall(function() tag = actors.GetWorldTag() or "?" end)
    end
    Log.Info(MODULE, "Drive state: " .. state, {world = tag})
end

-- Photomode covered-skylight damp: when a PHOTO SESSION opens with the car
-- under road-data cover, the sky multiplier drops to
-- Config.PhotoMode.CoveredSkylightMult; restores on close. Kills the
-- leaked-sky sheen on glass/taillight translucents for tunnel shots
-- (user-diagnosed via Alt+Shift+C 2026-07-14). Driving is untouched: the
-- always-on tunnel damp was tried the same night and rejected (whole-scene
-- skylight stepping at every portal). Wins over the Alt+C tune.
local COVERED_SKY_MULT = nil   -- nil = feature off (Config.PhotoMode)
local coveredSkyDamp = false

--- Push the cvar trio; skips values unchanged since the last push.
local function applyValues(sky, leak, lens, elev, reason)
    local eps = 1e-4
    if tune.sky  then sky  = tune.sky  end
    if tune.leak then leak = tune.leak end
    -- Photo session: manual metering is live, the 3.4.0 curve sets the
    -- level from SUN ELEVATION (garage/PA menu: the fixed garage pair;
    -- there is no sun there and 3.4.0 forced night values). The sky
    -- column only applies when Config.PhotoMode.ManualCurveSky is on:
    -- lens carries the exposure alone by default, so photomode never
    -- scales the skylight (it masked the translucent-skylight work).
    if photoExpFrozen and #PHOTO_LENS_CURVE > 0 then
        if elev == nil then
            lens = PHOTO_GARAGE_LENS
            if PHOTO_USE_SKY then sky = PHOTO_GARAGE_SKY end
        else
            lens = curveLookup(PHOTO_LENS_CURVE, elev)
            if PHOTO_USE_SKY then sky = curveLookup(PHOTO_SKY_CURVE, elev) end
        end
    end
    -- Covered damp wins over everything on sky (tunnel glass sheen)
    if coveredSkyDamp and COVERED_SKY_MULT then sky = COVERED_SKY_MULT end
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

--- One-shot (game thread): adaptation speeds + compensation-curve kill.
--- Runs once per course when the module arms; both writes are re-verified by
--- ppShotsReadbackGT ~8s later. GT closure re-checks world state at RUN time
--- (teardown rule).
local function applyPPShotsGT()
    local actors = getActors()
    if actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
        ppShotsApplied = false   -- retry on the next update; world is mid-swap
        return
    end

    -- ADAPTATION SPEEDS onto BP_CourseSky's composited PP component
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

    -- GENERIC LOOK OVERRIDES (Config.LightCycle.PostProcess): numbers/bools
    -- write directly, struct fields (color/vector) write component-wise
    -- into the live struct. Each in its own pcall; the readback verifies.
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

    -- SKYLIGHT OFF TRANSLUCENTS: the skylight's translucent-lighting feed is
    -- what paints leaked sky onto glass/taillight lenses under ceilings
    -- (the translucency probe grid is too coarse to occlude it). Killing
    -- the feed costs nothing: glass is specular/reflection dominated, and
    -- opaque surfaces keep their normally-occluded skylight via Lumen GI.
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

    -- COMPENSATION CURVE KILL: clear the curve at both ends (see header).
    -- Object-property nil-writes may not be supported by every UE4SS build:
    -- each attempt sits in its own pcall and the log carries what stuck.
    -- The PP-side override-flag drop alone already stops the curve from
    -- applying IF nothing re-pushes it; the readback settles that.
    if KILL_COMP_CURVE then
        local info = {}
        local uds = actors and actors.GetUDS and actors.GetUDS()
        if uds and uds.IsValid and uds:IsValid() then
            pcall(function() info.uds_before = objName(uds[PROP_COMP_CURVE]) end)
            info.uds_clear = pcall(function() uds[PROP_COMP_CURVE] = nil end)
        else
            info.uds_clear = "no-uds"
        end
        if pp then
            pcall(function() info.pp_before = objName(pp.Settings.AutoExposureBiasCurve) end)
            info.pp_flag = pcall(function() pp.Settings.bOverride_AutoExposureBiasCurve = false end)
            info.pp_slot = pcall(function() pp.Settings.AutoExposureBiasCurve = nil end)
        end
        Log.Info(MODULE, "Comp curve kill", info)
    end

    ppShotsWroteClock = os.clock()
end

--- Delayed one-shot readback ~8s after the writes: held=false means a
--- per-tick writer re-asserts that field and the kill/speeds need a carrier
--- (measure first, do NOT silently re-assert).
local function ppShotsReadbackGT()
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
                if KILL_COMP_CURVE then
                    pcall(function() info.pp_curve = objName(s.AutoExposureBiasCurve) end)
                    pcall(function() info.pp_flag = tostring(s.bOverride_AutoExposureBiasCurve) end)
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
        if KILL_COMP_CURVE then
            local actors = getActors()
            local uds = actors and actors.GetUDS and actors.GetUDS()
            if uds and uds.IsValid and uds:IsValid() then
                pcall(function() info.uds_curve = objName(uds[PROP_COMP_CURVE]) end)
            end
        end
        Log.Info(MODULE, "PP one-shots readback", info)
    end)
end

-- ============== INTERNAL: display PP dump (TEMP diagnostic) ==============
-- One-shot full FPostProcessSettings dump of every live PostProcessComponent
-- (CourseSky x2, BP_HDR, BP_CourseWeather) with the GameUserSettings HDR
-- output state in the header and filename. Purpose: diff an HDR-on boot
-- against an HDR-off boot to learn what BP_HDR's UpdatePostProcessSettings
-- changes for SDR displays (the 3.5.x look reads crushed on SDR screens).
-- Field list: the cook's 246 FPostProcessSettings fields in declaration
-- order (reference: pp_override_fields.txt). Config.LightCycle.DumpDisplayPP.

local DUMP_DISPLAY_PP = false
local displayDumpDone = false   -- session-level: one file per game boot

local PP_FIELDS = {
    "TemperatureType", "WhiteTemp", "WhiteTint", "ColorSaturation",
    "ColorContrast", "ColorGamma", "ColorGain", "ColorOffset",
    "ColorSaturationShadows", "ColorContrastShadows", "ColorGammaShadows", "ColorGainShadows",
    "ColorOffsetShadows", "ColorSaturationMidtones", "ColorContrastMidtones", "ColorGammaMidtones",
    "ColorGainMidtones", "ColorOffsetMidtones", "ColorSaturationHighlights", "ColorContrastHighlights",
    "ColorGammaHighlights", "ColorGainHighlights", "ColorOffsetHighlights", "ColorCorrectionShadowsMax",
    "ColorCorrectionHighlightsMin", "ColorCorrectionHighlightsMax", "BlueCorrection", "ExpandGamut",
    "ToneCurveAmount", "FilmSlope", "FilmToe", "FilmShoulder",
    "FilmBlackClip", "FilmWhiteClip", "SceneColorTint", "SceneFringeIntensity",
    "ChromaticAberrationStartOffset", "bMegaLights", "AmbientCubemapTint", "AmbientCubemapIntensity",
    "BloomMethod", "BloomIntensity", "BloomThreshold", "Bloom1Tint",
    "Bloom1Size", "Bloom2Size", "Bloom2Tint", "Bloom3Tint",
    "Bloom3Size", "Bloom4Tint", "Bloom4Size", "Bloom5Tint",
    "Bloom5Size", "Bloom6Tint", "Bloom6Size", "BloomSizeScale",
    "BloomConvolutionTexture", "BloomConvolutionScatterDispersion", "BloomConvolutionSize", "BloomConvolutionCenterUV",
    "BloomConvolutionPreFilter", "BloomConvolutionPreFilterMin", "BloomConvolutionPreFilterMax", "BloomConvolutionPreFilterMult",
    "BloomConvolutionBufferScale", "BloomDirtMaskIntensity", "BloomDirtMaskTint", "BloomDirtMask",
    "CameraShutterSpeed", "CameraISO", "AutoExposureMethod", "AutoExposureLowPercent",
    "AutoExposureHighPercent", "AutoExposureMinBrightness", "AutoExposureMaxBrightness", "AutoExposureCalibrationConstant",
    "AutoExposureSpeedUp", "AutoExposureSpeedDown", "AutoExposureBias", "AutoExposureBiasCurve",
    "AutoExposureMeterMask", "AutoExposureApplyPhysicalCameraExposure", "HistogramLogMin", "HistogramLogMax",
    "LocalExposureMethod", "LocalExposureContrastScale", "LocalExposureHighlightContrastScale", "LocalExposureShadowContrastScale",
    "LocalExposureHighlightContrastCurve", "LocalExposureShadowContrastCurve", "LocalExposureHighlightThreshold", "LocalExposureShadowThreshold",
    "LocalExposureDetailStrength", "LocalExposureBlurredLuminanceBlend", "LocalExposureBlurredLuminanceKernelSizePercent", "LocalExposureHighlightThresholdStrength",
    "LocalExposureShadowThresholdStrength", "LocalExposureMiddleGreyBias", "LensFlareIntensity", "LensFlareTint",
    "LensFlareTints", "LensFlareBokehSize", "LensFlareBokehShape", "LensFlareThreshold",
    "VignetteIntensity", "Sharpen", "GrainIntensity", "GrainJitter",
    "FilmGrainIntensity", "FilmGrainIntensityShadows", "FilmGrainIntensityMidtones", "FilmGrainIntensityHighlights",
    "FilmGrainShadowsMax", "FilmGrainHighlightsMin", "FilmGrainHighlightsMax", "FilmGrainTexelSize",
    "FilmGrainTexture", "AmbientOcclusionIntensity", "AmbientOcclusionStaticFraction", "AmbientOcclusionRadius",
    "AmbientOcclusionFadeDistance", "AmbientOcclusionFadeRadius", "AmbientOcclusionDistance", "AmbientOcclusionRadiusInWS",
    "AmbientOcclusionPower", "AmbientOcclusionBias", "AmbientOcclusionQuality", "AmbientOcclusionMipBlend",
    "AmbientOcclusionMipScale", "AmbientOcclusionMipThreshold", "AmbientOcclusionTemporalBlendWeight", "RayTracingAO",
    "RayTracingAOSamplesPerPixel", "RayTracingAOIntensity", "RayTracingAORadius", "LPVIntensity",
    "LPVDirectionalOcclusionIntensity", "LPVDirectionalOcclusionRadius", "LPVDiffuseOcclusionExponent", "LPVSpecularOcclusionExponent",
    "LPVDiffuseOcclusionIntensity", "LPVSpecularOcclusionIntensity", "LPVSize", "LPVSecondaryOcclusionIntensity",
    "LPVSecondaryBounceIntensity", "LPVGeometryVolumeBias", "LPVVplInjectionBias", "LPVEmissiveInjectionIntensity",
    "LPVFadeRange", "LPVDirectionalOcclusionFadeRange", "IndirectLightingColor", "IndirectLightingIntensity",
    "ColorGradingIntensity", "ColorGradingLUT", "DepthOfFieldFocalDistance", "DepthOfFieldFstop",
    "DepthOfFieldMinFstop", "DepthOfFieldBladeCount", "DepthOfFieldSensorWidth", "DepthOfFieldSqueezeFactor",
    "DepthOfFieldDepthBlurRadius", "DepthOfFieldUseHairDepth", "DepthOfFieldPetzvalBokeh", "DepthOfFieldPetzvalBokehFalloff",
    "DepthOfFieldPetzvalExclusionBoxExtents", "DepthOfFieldPetzvalExclusionBoxRadius", "DepthOfFieldAspectRatioScalar", "DepthOfFieldMatteBoxFlags",
    "DepthOfFieldBarrelRadius", "DepthOfFieldBarrelLength", "DepthOfFieldDepthBlurAmount", "DepthOfFieldFocalRegion",
    "DepthOfFieldNearTransitionRegion", "DepthOfFieldFarTransitionRegion", "DepthOfFieldScale", "DepthOfFieldNearBlurSize",
    "DepthOfFieldFarBlurSize", "MobileHQGaussian", "DepthOfFieldOcclusion", "DepthOfFieldSkyFocusDistance",
    "DepthOfFieldVignetteSize", "MotionBlurAmount", "MotionBlurMax", "MotionBlurTargetFPS",
    "MotionBlurPerObjectSize", "ScreenPercentage", "ReflectionMethod", "LumenReflectionQuality",
    "ScreenSpaceReflectionIntensity", "ScreenSpaceReflectionQuality", "ScreenSpaceReflectionMaxRoughness", "ScreenSpaceReflectionRoughnessScale",
    "UserFlags", "ReflectionsType", "RayTracingReflectionsMaxRoughness", "RayTracingReflectionsMaxBounces",
    "RayTracingReflectionsSamplesPerPixel", "RayTracingReflectionsShadows", "RayTracingReflectionsTranslucency", "TranslucencyType",
    "RayTracingTranslucencyMaxRoughness", "RayTracingTranslucencyRefractionRays", "RayTracingTranslucencySamplesPerPixel", "RayTracingTranslucencyShadows",
    "RayTracingTranslucencyRefraction", "RayTracingTranslucencyMaxPrimaryHitEvents", "RayTracingTranslucencyMaxSecondaryHitEvents", "RayTracingTranslucencyUseRayTracedRefraction",
    "DynamicGlobalIlluminationMethod", "LumenSceneLightingQuality", "LumenSceneDetail", "LumenSceneViewDistance",
    "LumenSceneLightingUpdateSpeed", "LumenFinalGatherQuality", "LumenFinalGatherLightingUpdateSpeed", "LumenFinalGatherScreenTraces",
    "LumenMaxTraceDistance", "LumenDiffuseColorBoost", "LumenSkylightLeaking", "LumenSkylightLeakingTint",
    "LumenFullSkylightLeakingDistance", "LumenRayLightingMode", "LumenReflectionsScreenTraces", "LumenFrontLayerTranslucencyReflections",
    "LumenMaxRoughnessToTraceReflections", "LumenMaxReflectionBounces", "LumenMaxRefractionBounces", "LumenSurfaceCacheResolution",
    "RayTracingGI", "RayTracingGIMaxBounces", "RayTracingGISamplesPerPixel", "PathTracingMaxBounces",
    "PathTracingSamplesPerPixel", "PathTracingMaxPathIntensity", "PathTracingEnableEmissiveMaterials", "PathTracingEnableReferenceDOF",
    "PathTracingEnableReferenceAtmosphere", "PathTracingEnableDenoiser", "PathTracingIncludeEmissive", "PathTracingIncludeDiffuse",
    "PathTracingIncludeIndirectDiffuse", "PathTracingIncludeSpecular", "PathTracingIncludeIndirectSpecular", "PathTracingIncludeVolume",
    "PathTracingIncludeIndirectVolume", "AutoExposureBiasBackup", 
}

local function fmtNum(n) return string.format("%.6g", n) end

--- Serialize one FPostProcessSettings field value for the dump: numbers and
--- bools direct, colors RGBA(...), vectors XYZ/XYZW(...), objects by name.
local function ppValueString(v)
    local tv = type(v)
    if v == nil then return "nil" end
    if tv == "number" then return fmtNum(v) end
    if tv == "boolean" then return tostring(v) end
    if tv == "string" then return v end
    local out = nil
    pcall(function()
        local r, g, b, a = v.R, v.G, v.B, v.A
        if type(r) == "number" and type(g) == "number" and type(b) == "number" then
            out = string.format("RGBA(%s,%s,%s,%s)", fmtNum(r), fmtNum(g), fmtNum(b),
                type(a) == "number" and fmtNum(a) or "?")
        end
    end)
    if out then return out end
    pcall(function()
        local x, y, z = v.X, v.Y, v.Z
        if type(x) == "number" and type(y) == "number" and type(z) == "number" then
            local w = nil
            pcall(function() w = v.W end)
            if type(w) == "number" then
                out = string.format("XYZW(%s,%s,%s,%s)", fmtNum(x), fmtNum(y), fmtNum(z), fmtNum(w))
            else
                out = string.format("XYZ(%s,%s,%s)", fmtNum(x), fmtNum(y), fmtNum(z))
            end
        end
    end)
    if out then return out end
    return objName(v)
end

--- bOverride_ flag for a field; bool fields drop their b prefix in the flag
--- name (bMegaLights pairs with bOverride_MegaLights).
local function ppFlagFor(s, name)
    local flag = nil
    pcall(function() flag = s["bOverride_" .. name] end)
    if flag == nil and name:match("^b%u") then
        pcall(function() flag = s["bOverride_" .. name:sub(2)] end)
    end
    return flag
end

--- Mod Logs/ dir from this chunk's source path. UE4SS chunk sources carry
--- MIXED slashes; normalize before matching (the DumpPPValues footgun).
local function modLogsDir()
    local src = nil
    pcall(function() src = debug.getinfo(1, "S").source end)
    if type(src) ~= "string" then return nil end
    src = src:gsub("^@", ""):gsub("\\", "/")
    local root = src:match("^(.*)/Scripts/")
    if not root then return nil end
    return root .. "/Logs/"
end

local function dumpDisplayPPGT()
    local hdrState, hdrNits = "unk", "?"
    pcall(function()
        local gus = FindFirstOf("GameUserSettings")
        if gus and gus.IsValid and gus:IsValid() then
            local on = nil
            pcall(function() on = gus.bUseHDRDisplayOutput end)
            pcall(function()
                local live = gus:IsHdrEnabled()
                if type(live) == "boolean" then on = live end
            end)
            if on == true then hdrState = "on" elseif on == false then hdrState = "off" end
            pcall(function() hdrNits = tostring(gus.HDRDisplayOutputNits) end)
        end
    end)

    local dir = modLogsDir()
    if not dir then
        Log.Warn(MODULE, "Display PP dump: could not resolve Logs dir")
        return
    end
    local fname = string.format("pp_values_%s_hdr-%s.txt", os.date("%Y%m%d_%H%M%S"), hdrState)
    local f = io.open(dir .. fname, "w")
    if not f then
        Log.Warn(MODULE, "Display PP dump: file open failed", {file = fname})
        return
    end

    f:write(string.format("FPostProcessSettings VALUES dump (display diagnostic): %s\n",
        os.date("%Y-%m-%d %H:%M:%S")))
    f:write(string.format("GameUserSettings HDR output: %s (nits=%s)\n", hdrState, hdrNits))
    f:write("ov=* marks fields whose bOverride_ flag is TRUE (actually applying);\n")
    f:write("all other values are inert struct defaults, listed for reference.\n")

    local comps = {}
    pcall(function()
        local all = FindAllOf("PostProcessComponent")
        if not all then return end
        for _, comp in ipairs(all) do
            if comp and comp.IsValid and comp:IsValid() then
                local full = ""
                pcall(function() full = comp:GetFullName() end)
                if full ~= "" and not full:find("Default__") and not full:find("GEN_VARIABLE") then
                    comps[#comps + 1] = {
                        comp = comp,
                        label = full:match("PersistentLevel%.(.+)$") or full,
                    }
                end
            end
        end
    end)
    table.sort(comps, function(a, b) return a.label < b.label end)

    for _, e in ipairs(comps) do
        f:write(string.format("\n========== %s ==========\n", e.label))
        local en, bw, ub = "?", "?", "?"
        pcall(function() en = tostring(e.comp.bEnabled) end)
        pcall(function() bw = tostring(e.comp.BlendWeight) end)
        pcall(function() ub = tostring(e.comp.bUnbound) end)
        f:write(string.format("(bEnabled=%s BlendWeight=%s bUnbound=%s)\n", en, bw, ub))
        local s = nil
        pcall(function() s = e.comp.Settings end)
        if s then
            for _, name in ipairs(PP_FIELDS) do
                local flag = ppFlagFor(s, name)
                local val = "?"
                pcall(function() val = ppValueString(s[name]) end)
                f:write(string.format("%s %-46s = %s\n", flag and "ov=*" or "    ", name, val))
            end
        else
            f:write("(Settings unreadable)\n")
        end
    end
    f:close()
    Log.Info(MODULE, "Display PP dump written", {file = fname, comps = #comps, hdr = hdrState})
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

    -- Sanity check in windows that are day/night in EVERY season at Tokyo's
    -- latitude (clock 10:00-14:00 = sun up; 22:00-03:00 = sun down). Three
    -- consecutive strong disagreements = the convention likely changed in a
    -- UDS update: WARN once, never auto-flip (one bad latch already cost a
    -- whole session).
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


--- Write the bias to UDS's knobs: Day and Night get the SAME value (our
--- elevation curve owns the number; UDS's internal day/night blend becomes a
--- no-op), scenario knobs zeroed once per course so UDS can't double-blend.
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
            Log.Info(MODULE, "Overcast night keep-fraction applied", {
                stock = tostring(stockO),
                new = OVERCAST_NIGHT,
            })
        else
            Log.Warn(MODULE, "Overcast night: write failed", {prop = PROP_OVERCAST_NIGHT})
        end
    end

    pcall(function()
        local fn = uds["Hard Reset Cache"]
        if fn then
            local ok = pcall(function() fn(uds) end)
            Log.Info(MODULE, "Night floor bake (Hard Reset Cache)", {ok = ok})
        end
    end)
end

-- ============== PHOTOMODE MANUAL METERING (legacy lens curve) ==============
-- photomode.lua drives this on session open/close. Manual metering
-- (MethodOverride 3) is the ONLY mode where the photomode aperture
-- physically drives exposure (user-verified; every read/hook emulation of
-- the applied f-stop failed, the value is unreachable). The manual level
-- rides the legacy lens-attenuation machinery, now keyed on SUN ELEVATION
-- (photoLensForElev above, applied inside applyValues), like every other
-- modern curve in this module. Histogram AE + neutral lens return on close.

function LightCycle.SetPhotoExposureFreeze(on)
    if on == photoExpFrozen then return end
    photoExpFrozen = on
    scheduleExec({ "r.EyeAdaptation.MethodOverride " .. (on and "3" or "-1") })
    -- Re-push the cvar trio on the next main tick (125ms): the lens value
    -- must land with the metering switch
    lastCheckClock = 0.0
    Log.Info(MODULE, on and "Photo session: manual metering ON (legacy lens curve)"
        or "Photo session: manual metering OFF")
end

--- Photomode covered-skylight damp signal (photomode.lua, session
--- open/close). Engages ONLY if the session opens with the car under
--- road-data cover; no-op unless Config.PhotoMode.CoveredSkylightMult set.
function LightCycle.SetPhotoCoveredSkyDamp(on)
    local want = false
    if on and COVERED_SKY_MULT then
        pcall(function()
            local T = getTunnels()
            want = (T and T.IsCovered and T.IsCovered()) or false
        end)
    end
    if want == coveredSkyDamp then return end
    coveredSkyDamp = want
    lastCheckClock = 0.0   -- re-push on the next 125ms tick
    Log.Info(MODULE, want and "Photo covered sky damp ON" or "Photo covered sky damp OFF",
        {mult = want and COVERED_SKY_MULT or "restore"})
end

-- ============== DISPLAY PROFILE (HDR vs SDR) ==============
-- The game lifts shadows 1.5x + global 1.2x for HDR displays only (BP_HDR
-- enables its grading component when GameUserSettings.IsHdrEnabled). The
-- config look tables are tuned on HDR on top of that lift; on SDR they
-- crush. Resolved ONCE per session on the first Update ("auto" reads the
-- live HDR output state; Config.LightCycle.DisplayProfile forces "hdr"/
-- "sdr"); the SDR profile swaps PP_OVERRIDES/BIAS_CURVE for the
-- Config.LightCycle.SDR tables. An in-session HDR toggle is NOT tracked
-- (restart to re-resolve).

local DISPLAY_PROFILE_CFG = "auto"
local SDR_TABLES = nil
local displayProfile = nil   -- resolved: "hdr" | "sdr"

--- force=true resolves even when the HDR state is unreadable (falls back
--- to "hdr" = the historical look) so the PP one-shots never stall on it.
local function resolveDisplayProfile(force)
    if displayProfile then return end
    local prof = DISPLAY_PROFILE_CFG
    local src = "config"
    if prof ~= "hdr" and prof ~= "sdr" then
        src = "auto"
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
        if hdrOn == nil then
            if not force then return end   -- retry on a later tick
            prof = "hdr"
            src = "fallback (HDR state unreadable)"
        else
            prof = hdrOn and "hdr" or "sdr"
        end
    end
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
        if cfg.DiagnosticNeutralCvars ~= nil then DIAGNOSTIC = cfg.DiagnosticNeutralCvars end
        if type(cfg.BiasCurve) == "table" then BIAS_CURVE = cfg.BiasCurve end
        if cfg.AdaptSpeedUp then ADAPT_UP = cfg.AdaptSpeedUp end
        if cfg.AdaptSpeedDown then ADAPT_DOWN = cfg.AdaptSpeedDown end
        if cfg.KillExposureCompCurve ~= nil then KILL_COMP_CURVE = cfg.KillExposureCompCurve end
        if cfg.KillSkylightTranslucentLighting ~= nil then
            KILL_SKY_TRANSLUCENT = cfg.KillSkylightTranslucentLighting
        end
        if cfg.DumpDisplayPP ~= nil then DUMP_DISPLAY_PP = cfg.DumpDisplayPP end
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

    -- Photomode covered-skylight damp value lives under Config.PhotoMode
    -- (session behavior), but the sky cvar is ours
    pcall(function()
        local v = Config.PhotoMode and Config.PhotoMode.CoveredSkylightMult
        if type(v) == "number" and v >= 0.0 and v < 1.0 then
            COVERED_SKY_MULT = v
        end
    end)

    -- Photomode manual exposure curve (the 3.4.0 sky+lens pairs), split
    -- into two elev/bias tables so curveLookup serves both
    pcall(function()
        local mc = Config.PhotoMode and Config.PhotoMode.ManualCurve
        if type(mc) == "table" and #mc > 0 then
            PHOTO_SKY_CURVE, PHOTO_LENS_CURVE = {}, {}
            for _, a in ipairs(mc) do
                if type(a.elev) == "number" then
                    PHOTO_SKY_CURVE[#PHOTO_SKY_CURVE + 1] =
                        { elev = a.elev, bias = tonumber(a.sky) or 1.0 }
                    PHOTO_LENS_CURVE[#PHOTO_LENS_CURVE + 1] =
                        { elev = a.elev, bias = tonumber(a.lens) or NEUTRAL_LENS }
                end
            end
            local desc = function(x, y) return x.elev > y.elev end
            table.sort(PHOTO_SKY_CURVE, desc)
            table.sort(PHOTO_LENS_CURVE, desc)
        end
        local g = Config.PhotoMode and Config.PhotoMode.ManualGarage
        if type(g) == "table" then
            PHOTO_GARAGE_SKY = tonumber(g.Sky) or PHOTO_GARAGE_SKY
            PHOTO_GARAGE_LENS = tonumber(g.Lens) or PHOTO_GARAGE_LENS
        end
        if Config.PhotoMode and Config.PhotoMode.ManualCurveSky ~= nil then
            PHOTO_USE_SKY = Config.PhotoMode.ManualCurveSky and true or false
        end
    end)

    -- PA mode lives OUTSIDE the LightCycle block (Config.PA, shared with
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
        curveKill = KILL_COMP_CURVE,
        diagnosticNeutral = DIAGNOSTIC,
    })
    if DIAGNOSTIC then
        Log.Warn(MODULE, "DIAGNOSTIC neutral-cvars mode ON: raw UDS light, no exposure shaping")
    end
    return true
end

--- True when this module is the active exposure provider (keybinds/headlights
--- route here instead of the legacy exposure module). Checks the module toggle
--- too: consumers require() this file directly, bypassing main.lua's nil-ing,
--- so without the check a toggled-off (never-ticking) module would still
--- capture the Alt+D family and the headlight elevation provider.
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
    ppShotsWroteClock = nil
    ppShotsCheckDone = false
    -- A teardown-close of photomode can leave the manual-metering latch
    -- set; the cvar is process-global, so assert the restore too
    if photoExpFrozen then
        photoExpFrozen = false
        scheduleExec({ "r.EyeAdaptation.MethodOverride -1" })
    end
    coveredSkyDamp = false  -- fresh course starts uncovered
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
    -- meters the garage fine by itself, this just clears Alt+Z/X/C leftovers).
    -- EXCEPTION: the PA scene (validated own UDS/UDW; the garage never
    -- validates) has a real sun; in PA continue/freeze mode it falls
    -- through to the normal elevation path (armed by main's PA apply).
    if actors.IsInGarage and actors.IsInGarage() then
        local paScene = PA_FOLLOW and actors.IsInPAScene and actors.IsInPAScene()
        if not paScene then
            noteDriveState("garage")
            applyValues(NEUTRAL_SKY, LEAK_ALBEDO, NEUTRAL_LENS, nil, "garage-neutral")
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
    -- The display profile MUST be settled before these fire (they consume
    -- PP_OVERRIDES); force the fallback if auto-detect never resolved.
    if not ppShotsApplied then
        if not displayProfile then resolveDisplayProfile(true) end
        ppShotsApplied = true
        if ExecuteInGameThread then
            pcall(function() ExecuteInGameThread(applyPPShotsGT) end)
        end
    elseif ppShotsWroteClock and not ppShotsCheckDone
        and (now - ppShotsWroteClock) >= 8.0 then
        ppShotsCheckDone = true
        if ExecuteInGameThread then
            pcall(function() ExecuteInGameThread(ppShotsReadbackGT) end)
        end
        if DUMP_DISPLAY_PP and not displayDumpDone and ExecuteInGameThread then
            displayDumpDone = true
            pcall(function() ExecuteInGameThread(dumpDisplayPPGT) end)
        end
    end

    local tod = nil
    local t = getTimeOfDay()
    if t then
        local ok, v = pcall(t.GetCurrentTOD)
        if ok then tod = v end
    end

    -- Sun elevation: real vector when available, pseudo (clock) fallback until
    -- the sign is calibrated / when the vector read fails.
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

    -- DIAGNOSTIC: raw UDS light, neutral cvars, no bias writes. Elevation
    -- logged on change so captures stay mappable.
    if DIAGNOSTIC then
        if lastDiagElev == nil or math.abs(elev - lastDiagElev) >= 0.4 then
            lastDiagElev = elev
            Log.Info(MODULE, "Diag elevation", {sun_elev = string.format("%.1f", elev)})
        end
        noteDriveState("course (diagnostic)")
        applyValues(NEUTRAL_SKY, LEAK_ALBEDO, NEUTRAL_LENS, elev, "diag-neutral")
        applyAbsentBrightness(uds)
        return true
    end

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

-- Alt+H exposure liveness test: toggle +2 EV on ALL of UDS's Exposure Bias
-- knobs (the proven native path). Screen brightens and holds while driving =
-- the UDS knob pipeline is alive. (Historic: this test identified UDS as the
-- per-tick AutoExposureBias writer, 2026-07-08.)
local ppBiasOn = false
function LightCycle.ToggleHDRDebug()   -- name kept for the keybind wiring
    ppBiasOn = not ppBiasOn
    local on = ppBiasOn
    local run = function()
        local actors = getActors()
        if actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
            Log.Warn(MODULE, "UDS bias test skipped (world teardown)")
            return
        end
        local uds = actors and actors.GetUDS and actors.GetUDS()
        if not (uds and uds.IsValid and uds:IsValid()) then
            Log.Warn(MODULE, "UDS bias test: no UDS")
            return
        end
        local v = on and 2.0 or 0.0
        local ok = pcall(function()
            uds["Exposure Bias Day"] = v
            uds["Exposure Bias Night"] = v
            uds["Exposure Bias Cloudy"] = v
            uds["Exposure Bias Foggy"] = v
            uds["Exposure Bias Dusty"] = v
        end)
        Log.Info(MODULE, "UDS bias test " .. (on and "ON (+2 EV all scenarios)" or "OFF (0.0)"), {ok = ok})
    end
    if ExecuteInGameThread then
        pcall(function() ExecuteInGameThread(run) end)
    else
        run()
    end
end

function LightCycle.GetStatus()
    return {
        initialized = isInitialized,
        enabled = enabled,
        armed = armed,
        sunElevation = lastElevation,
        sunVectorSign = SUN_VECTOR_SIGN,
        lastApplied = lastApplied,
        lastBias = lastBias,
        execBatches = execBatches,
        dropBatches = dropBatches,
    }
end

function LightCycle.IsInitialized()
    return isInitialized
end

--- Alias so the module can be ticked as either Tick() or Update().
LightCycle.Tick = LightCycle.Update

return LightCycle
