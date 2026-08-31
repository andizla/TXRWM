-- TXR Weather Mod v3.0
-- systems/stars.lua
-- Phase 12: High-resolution (HD) real-stars night sky
--
-- SAFE REWRITE (2026-06-24). The old version resolved the Real_Stars texture asset
-- and wrote it into the OBJECT-typed "Real Stars Texture" UProperty off-thread
-- during course BeginPlay, corrupting UE4SS reflection -> 0xC0000005 crash. Even a
-- game-thread wrap didn't save it.
--
-- New approach (from the UE4SS_ObjectDump + UDS v9.5 docs): we do NOT touch the
-- texture object at all. "Real Stars Texture" is a SoftObjectProperty already
-- assigned in UDS, and "Static Properties - Stars" is UDS's own function that
-- resolves that soft-ref and applies it (SoftObjectToObject -> Cast Texture2D ->
-- SetScalarParameterValue, all internally). So we only:
--   1. set "Simulate Real Stars" = true (a primitive bool), + optional intensity/tiling,
--   2. call "Static Properties - Stars" on the GAME THREAD (UDS loads its own texture),
--   3. defer past the BeginPlay window with a settle gate (the shadow-module lesson).
-- No asset load, no object-typed write, nothing during construction.

local Stars = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local GT = require("core.gt")
local State = require("core.state")
local Config = require("config")

local Actors = nil  -- lazy

local MODULE = "Stars"

-- ============== UDS PROPERTY / FUNCTION NAMES (verified from dump) ==============
local PROP_SIMULATE_REAL_STARS = "Simulate Real Stars"   -- Bool
local PROP_STARS_INTENSITY     = "Stars Intensity"       -- Double
local PROP_STARS_TILING        = "Stars Tiling"          -- Double
local PROP_STARS_COLOR         = "Stars Color"           -- FLinearColor (HDR: >1 = brighter)
local FN_STATIC_STARS          = "Static Properties - Stars"  -- applies stars (loads soft-ref texture itself)

-- Ticks on course before applying, to clear the BeginPlay construction window.
-- 8 Hz loop, so 32 ticks ~= 4s.
local SETTLE_TICKS = 32

-- ============== CONFIG (filled in Init) ==============
local enabled = true
local intensity = nil  -- nil = keep UDS default
-- Real-star 360 map vs the simple tiling texture. The real map carries a
-- baked Milky Way band that reads as a "nebula" in the sky; false swaps
-- to the tiling texture (2026-07-23 test: eliminate the nebula variable
-- from the stars-vs-glow puzzle).
local simulateRealStars = true
local tiling = nil     -- nil = keep UDS default
-- City glow washes the night-sky background brighter than the stars, so
-- they read as dark holes. Intensity scales toward intensity*CITY_GLOW_BOOST
-- with the live glow factor (atmosphere.GetCityGlowFactor). 1.0 = off.
local CITY_GLOW_BOOST = 1.0

-- ============== STATE ==============
local isInitialized = false
local applied = false
local settleTicks = 0
local appliedThisCourse = false
local effectiveIntensity = nil  -- glow-boosted value; wins over `intensity`
local lastBoostApplied = nil    -- change gate for the boost writes
local lastBoostClock = 0.0      -- throttle (each step re-bakes)
-- Star COLOR boost: field-observed 2026-07-17, "Stars Intensity" acts as
-- the layer's OPACITY in this compositing, so against a glow-lifted sky
-- more intensity = darker star specks, never brighter. Luminance lives
-- in the Stars Color FLinearColor: RGB scaled >1 (HDR) is what actually
-- brightens the points. Stock color is captured once per course and the
-- multiplier always applies to STOCK (never compounds).
local starColorStock = nil
local starColorMult = 1.0
-- (The MIDStarColor emergency belt/stomp/burst machinery was removed in
-- the pre-4.0.0 dead-code pass: its gate shipped nil since 3.x and the
-- final star architecture never needed it. History lives in HANDOFF.md
-- and the reference library.)
local starsSpeed = nil           -- Config.Stars.TilingStarSpeed; nil = keep UDS default

-- ============== INTERNAL ==============

local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

local AtmosphereMod = nil
local function getAtmosphere()
    if not AtmosphereMod then
        local ok, mod = pcall(require, "systems.atmosphere")
        if ok then AtmosphereMod = mod end
    end
    return AtmosphereMod
end

local function getUDS()
    local actors = getActors()
    if not actors then return nil end
    return actors.GetUDS()
end

--- The actual UDS work. MUST run on the game thread. NO asset load, NO object
--- write; only a primitive bool/doubles plus UDS's own apply function.
local function enableStarsOnGameThread()
    local uds = getUDS()
    if not uds then return end

    pcall(function() uds[PROP_SIMULATE_REAL_STARS] = simulateRealStars end)
    local wantIntensity = effectiveIntensity or intensity
    if wantIntensity ~= nil then pcall(function() uds[PROP_STARS_INTENSITY] = wantIntensity end) end
    if tiling ~= nil then pcall(function() uds[PROP_STARS_TILING] = tiling end) end

    -- Tiling-mode star drift: the tiling texture pans with Stars Speed
    -- (the real-star rotation is unavailable, its mode is the pusher)
    if starsSpeed ~= nil then
        pcall(function() uds["Stars Speed"] = starsSpeed end)
    end

    -- UDS resolves its own Real Stars Texture soft-ref and applies it here.
    local fn = nil
    pcall(function() fn = uds[FN_STATIC_STARS] end)
    if fn then
        local ok, err = pcall(function() fn(uds) end)
        if ok then
            Log.Debug(MODULE, "Static Properties - Stars called")
        else
            Log.Warn(MODULE, "Static Properties - Stars failed", { error = tostring(err) })
        end
    else
        Log.Warn(MODULE, "Static Properties - Stars function not found")
    end
end

local function applyStars()
    if not getUDS() then return false end
    if ExecuteInGameThread then
        pcall(function() GT.Run(enableStarsOnGameThread) end)
    else
        enableStarsOnGameThread()
    end
    return true
end

--- Write Stars Color = stock * starColorMult and re-bake (game thread).
--- Captures the stock color on first use per course (fresh sky actor =
--- fresh stock), so the multiplier never compounds.
local function applyStarColorGT()
    local uds = getUDS()
    if not uds then return end
    if not starColorStock then
        local cap = nil
        pcall(function()
            local c = uds[PROP_STARS_COLOR]
            cap = { R = tonumber(c.R), G = tonumber(c.G), B = tonumber(c.B),
                    A = tonumber(c.A) or 1.0 }
        end)
        if not (cap and cap.R and cap.G and cap.B) then return end
        starColorStock = cap
    end
    local m = starColorMult
    local okW = pcall(function()
        uds[PROP_STARS_COLOR] = {
            R = starColorStock.R * m, G = starColorStock.G * m,
            B = starColorStock.B * m, A = starColorStock.A,
        }
    end)
    if okW then applyStars() end   -- bake via Static Properties - Stars
end

--- Marshal wrapper: the read+write pair must run on the game thread (the
--- Tick caller is async; a raw property touch there is the native-AV class).
local function applyStarColor()
    if ExecuteInGameThread then
        pcall(function() GT.Run(applyStarColorGT) end)
    else
        applyStarColorGT()
    end
end

-- ============== PUBLIC API ==============

function Stars.Init()
    if isInitialized then return true end
    local cfg = Config.Stars
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.Intensity ~= nil then intensity = cfg.Intensity end
        if cfg.Tiling ~= nil then tiling = cfg.Tiling end
        if cfg.SimulateRealStars ~= nil then simulateRealStars = cfg.SimulateRealStars end
        if type(cfg.CityGlowBoost) == "number" and cfg.CityGlowBoost >= 1.0 then
            CITY_GLOW_BOOST = cfg.CityGlowBoost
        end
        if type(cfg.ColorBoost) == "number" and cfg.ColorBoost > 0 then
            starColorMult = cfg.ColorBoost
        end
        if type(cfg.TilingStarSpeed) == "number" then
            starsSpeed = cfg.TilingStarSpeed
        end
    end
    isInitialized = true
    State.SetModuleStatus("stars", true)
    Log.Info(MODULE, "Initializing stars module", { enabled = enabled })
    return true
end

--- Called per course load. Just re-arms the settle gate; the actual apply happens
--- in Tick, well after BeginPlay (NOT during the construction window).
function Stars.Setup()
    settleTicks = 0
    appliedThisCourse = false
    lastBoostApplied = nil   -- fresh sky = re-apply the glow boost
    effectiveIntensity = nil -- a boosted value from the LAST course must not
                             -- become this course's one-shot base apply
    starColorStock = nil     -- fresh sky = fresh stock color capture
end

--- Per-tick: apply once per course, after the settle gate, if enabled.
function Stars.Tick()
    if not isInitialized or not enabled then return end

    local actors = getActors()
    if not actors or not actors.IsOnCourse() then
        settleTicks = 0
        appliedThisCourse = false
        return
    end

    settleTicks = settleTicks + 1
    if not appliedThisCourse and settleTicks >= SETTLE_TICKS then
        appliedThisCourse = true
        applied = applyStars()
        if applied then
            Log.Info(MODULE, "Stars applied (real-stars enabled, deferred past BeginPlay)")
        end
        -- Persisted color boost (Config.Stars.ColorBoost) re-applies to
        -- the fresh sky's stock color
        if starColorMult ~= 1.0 then
            applyStarColor()
        end
    end

    -- CITY GLOW COMPENSATION (see CITY_GLOW_BOOST): follow the live glow
    -- factor so stars stay brighter than the lifted sky background.
    -- Throttled + change-gated: every applied step re-bakes via Static
    -- Properties (the SetIntensity precedent; a dusk ramp = a handful of
    -- bakes, steady night = none).
    if appliedThisCourse and CITY_GLOW_BOOST > 1.0 and intensity ~= nil then
        local now = os.clock()
        if now - lastBoostClock >= 2.0 then
            lastBoostClock = now
            local glow = 0.0
            pcall(function()
                local atmo = getAtmosphere()
                if atmo and atmo.GetCityGlowFactor then
                    glow = atmo.GetCityGlowFactor() or 0.0
                end
            end)
            local eff = intensity * (1.0 + (CITY_GLOW_BOOST - 1.0) * glow)
            -- Baseline = the configured intensity (the one-shot apply
            -- already wrote it): at zero glow this stays silent instead
            -- of re-baking a no-op on every course entry
            if math.abs(eff - (lastBoostApplied or intensity)) >= 0.25 then
                lastBoostApplied = eff
                effectiveIntensity = eff
                applyStars()
                Log.Info(MODULE, "Stars glow boost", {
                    intensity = string.format("%.2f", eff),
                    glow = string.format("%.2f", glow),
                })
            end
        end
    end
end

return Stars
