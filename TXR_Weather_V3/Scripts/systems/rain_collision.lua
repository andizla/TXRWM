-- TXR Weather Mod v3.0
-- systems/rain_collision.lua
-- Native rain occlusion, production form (v9 TARGETED, 2026-07-28).
-- HISTORY OF THE SHAPE: v7 flipped the whole world rain-solid (worked,
-- but AI broke); v8 moved rain to private channel 25 to drop the
-- Visibility writes (rain died globally: containing bodies, envelopes/
-- sight spheres/sky enclosures, default-Block undefined channels; the
-- containment fan fixed that but mid-air rain loss remained) and the AI
-- STILL broke on both channels = the mass ENABLEMENT was the AI vector,
-- not the responses. v9 therefore targets ONLY the meshes that matter
-- and makes them invisible to the game:
--   1. TARGETED FLIP: disabled mesh components whose static-mesh asset
--      path matches TargetPatterns (tunnel linings "tnl", Mesh_tn
--      interior sets, bridge/overpass decks "_br": every confirmed
--      occluder hit in the field digs) get CollisionTraceFlag=3
--      (ComplexAsSimple; live readback proved 3) + QueryOnly enable.
--   2. STEALTH BODIES: each flipped body gets ObjectType=25 (a
--      game-undefined channel: AI object-space queries, obstacle/sight/
--      road-gap, can never include it) + Ignore-ALL responses + Block on
--      the rain channel alone. Rain channel traces hit it; every other
--      query and overlap in the game passes through.
--   3. UDW's 'Weather Particle Collision Channel' is enforced at
--      Config.RainCollision.Channel (default 3 = stock Visibility,
--      field-verified correct occlusion; 22+ = the private-channel
--      experiment, which also arms the containment fan + shape
--      neutralization machinery below). Write + 'Update Static
--      Variables' = the proven full re-bake.
-- Streaming re-application (16:53/17:06/17:07 field sequence: cells that
-- stream in AFTER a pass are un-flipped): the pass re-runs on a cadence
-- while the weather is wet, is idempotent (already-enabled components
-- are skipped after one cheap read), and fires immediately on rain
-- start. Dry sessions cost one property read per enforcement tick.

local RainCollision = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")
local Config = require("config")

-- Lazy-loaded to avoid circular dependencies
local Actors = nil
local PresetsMod = nil

local MODULE = "RainCollision"

-- ============== CONFIG-DERIVED (filled in Init, with safe fallbacks) ==============
local enabled = true
local CHANNEL = 3           -- ECollisionChannel index for rain traces
local REAPPLY_S = 20.0      -- streamed-cell re-pass cadence while wet
local SETTLE_S = 3.0        -- course-arm settle before the first pass
local ENFORCE_S = 2.0       -- UDW channel enforcement cadence (cheap read)
local DEBUG = false
-- Lua patterns matched against each disabled mesh component's STATIC MESH
-- asset full name: tunnel linings/pieces ("tnl"), the Mesh_tn interior-set
-- folders, and bridge/overpass deck pieces ("_br" suffix; the trailing
-- "%." / "$" anchor it to the asset name end, so "_brk"-style names never
-- match). Extend from field data via Config.RainCollision.TargetPatterns.
local TARGET_PATTERNS = { "tnl", "Mesh_tn", "_br%.", "_br$" }

-- ============== STATE ==============
local isInitialized = false
local armed = false          -- course gate (main.lua OnCourseLoad)
local armedAt = 0.0
local nextEnforce = 0.0
local lastPass = nil         -- os.clock of the last world pass (nil = none yet)
local passPending = false    -- immediate pass requested (rain start / load)
local passTrigger = "load"
local chanLoggedCourse = false

-- ============== INTERNAL: lazy refs ==============

local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

local UEHelpers = nil
local function getUEHelpers()
    if not UEHelpers then
        pcall(function() UEHelpers = require("UEHelpers") end)
    end
    return UEHelpers
end

local function getPresets()
    if not PresetsMod then
        local ok, mod = pcall(require, "systems.presets")
        if ok then PresetsMod = mod end
    end
    return PresetsMod
end

local function validRef(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local cachedKsl = nil
local function getKslRef()
    if validRef(cachedKsl) then return cachedKsl end
    local UEH = getUEHelpers()
    if not UEH or not UEH.GetKismetSystemLibrary then return nil end
    local ksl = nil
    pcall(function() ksl = UEH.GetKismetSystemLibrary() end)
    if validRef(ksl) then cachedKsl = ksl; return ksl end
    return nil
end

local function isWet()
    local wet = false
    pcall(function()
        local p = State.GetCurrentPreset()
        if p then
            local pr = getPresets()
            if pr and pr.IsDry then wet = not pr.IsDry(p) end
        end
    end)
    return wet
end

-- ============== INTERNAL: UDW channel enforcement (game thread) ==============

--- Keep UDW's particle collision channel on the private channel. Cheap
--- steady state (one property read); writes + re-bakes only when the live
--- value differs (fresh course instance, or CoolConsoleCommands' warmup
--- re-constructing UDW state mid-course). The re-bake restarts rain
--- particles, so it must never run redundantly.
local function enforceChannelGT()
    local actors = getActors()
    if actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
        return
    end
    local udw = actors and actors.GetUDW and actors.GetUDW()
    if not (udw and validRef(udw)) then return end
    local cur = nil
    pcall(function() cur = tonumber(udw["Weather Particle Collision Channel"]) end)
    if cur == nil then return end
    if cur == CHANNEL then
        if not chanLoggedCourse then
            chanLoggedCourse = true
            Log.Info(MODULE, "Rain channel verified", {channel = CHANNEL})
        end
        return
    end
    local wrote = pcall(function()
        udw["Weather Particle Collision Channel"] = CHANNEL
    end)
    local rebaked = false
    pcall(function()
        local fn = udw["Update Static Variables"]
        if fn then fn(udw); rebaked = true end
    end)
    chanLoggedCourse = true
    Log.Info(MODULE, "Rain channel set", {
        channel = CHANNEL, was = cur,
        wrote = tostring(wrote), rebaked = tostring(rebaked),
    })
end

-- ============== INTERNAL: containment fan (game thread) ==============

--- THE NO-RAIN KILLER CLASS (2026-07-28 17:49 field: zero rain anywhere
--- on channel 25 despite a healthy apply): a body whose SIMPLE collision
--- CONTAINS the car (section-envelope volumes, AI sight spheres, sky
--- enclosures) and whose profile default-Blocks the undefined private
--- channel. UDW's per-particle ceiling probe (8000 uu up) then hits it at
--- distance ~0 from every spawn point = "roof overhead, everywhere" =
--- all rain dies. Such bodies ignore Visibility by AUTHORED response
--- (stock rain never saw them), but nothing authored the high channels.
--- Fix: an upward object-type trace fan from the car; any hit at
--- containment distance (< 50 uu; real geometry, being ComplexAsSimple
--- trimesh, hits at true surface distances) that Blocks the private
--- channel gets that ONE response flipped to Ignore. Nothing in the game
--- queries the channel, so the write is invisible to every other system.
--- Runs every enforce tick while wet (21 traces, trivial); each write
--- logs the culprit's name = the diagnosis and the fix in one motion.
local TRACE_COLOR = { R = 0.0, G = 0.0, B = 0.0, A = 1.0 }

local function containmentFanGT()
    local actors = getActors()
    if actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
        return
    end
    local ksl = getKslRef()
    local pawnObj, px, py, pz = nil, nil, nil, nil
    pcall(function()
        local UEH = getUEHelpers()
        local pc = UEH and UEH.GetPlayerController and UEH.GetPlayerController()
        local pawn = pc and pc.Pawn
        if pawn and pawn.IsValid and pawn:IsValid() then
            local loc = pawn:K2_GetActorLocation()
            if loc then px, py, pz = loc.X, loc.Y, loc.Z; pawnObj = pawn end
        end
    end)
    if not (ksl and pawnObj) then return end
    local s = { X = px, Y = py, Z = pz + 250.0 }
    local e = { X = px, Y = py, Z = pz + 8250.0 }
    for ot = 0, 20 do
        pcall(function()
            local outHit = {}
            local r = ksl:LineTraceSingleForObjects(pawnObj, s, e, {ot},
                false, {}, 0, outHit, true, TRACE_COLOR, TRACE_COLOR, 0.0)
            local h = outHit
            pcall(function() if h.OutHit then h = h.OutHit end end)
            local blocking = (r == true)
            if not blocking then
                pcall(function() blocking = (h.bBlockingHit == true) end)
            end
            if not blocking then return end
            local dist = nil
            pcall(function() dist = tonumber(h.Distance) end)
            if not (dist and dist < 50.0) then return end
            local comp = nil
            pcall(function() comp = h.Component end)
            pcall(function()
                if comp and comp.Get then
                    local o = comp:Get()
                    if o then comp = o end
                end
            end)
            if not comp then return end
            local resp = nil
            pcall(function() resp = comp:GetCollisionResponseToChannel(CHANNEL) end)
            if resp ~= 2 then return end
            local wrote = pcall(function()
                comp:SetCollisionResponseToChannel(CHANNEL, 0)
            end)
            local nm = "?"
            pcall(function()
                local fn = comp:GetFullName()
                if type(fn) == "string" then nm = fn:sub(-70) end
            end)
            Log.Info(MODULE, "Containment blocker neutralized", {
                ot = ot, dist = string.format("%.0f", dist),
                wrote = tostring(wrote), name = nm,
            })
        end)
    end
end

-- ============== INTERNAL: world pass (game thread) ==============

--- TARGETED rain-solid pass (v9, 2026-07-28 field round 2: the v7/v8
--- world-wide flip broke AI on BOTH channels = the mass ENABLEMENT was
--- the AI vector all along, never the Visibility writes; user call:
--- "target the correct meshes"). Only mesh components whose STATIC MESH
--- ASSET path matches the target patterns (tunnel linings + interior
--- sets + bridge/overpass decks: the exact assets every confirmed
--- occlusion hit named today) get flipped, and each flipped body is a
--- STEALTH BODY the game cannot see:
---   - CollisionTraceFlag = 3 (ComplexAsSimple: simple rain traces route
---     to the cooked trimesh),
---   - QueryOnly enable (en 0 -> 1 only; physics never touched),
---   - ObjectType = 25 (a game-undefined channel: NO object-space query
---     the AI runs, obstacle/sight/road-gap, can ever include it),
---   - responses = Ignore ALL + Block the rain channel alone (no overlap
---     events, no phantom hits on any game channel).
--- Rain (a channel trace) hits it; everything else passes through.
--- Idempotent: already-enabled components are skipped after one read;
--- disabled non-matching components pay one asset-name read per pass
--- (ms= in the log tells the real cost).
local CLASSES = {
    "StaticMeshComponent",
    "InstancedStaticMeshComponent",
    "HierarchicalInstancedStaticMeshComponent",
}
local SHAPE_CLASSES = {
    "BrushComponent",
    "BoxComponent",
    "SphereComponent",
    "CapsuleComponent",
}
local STEALTH_OBJ_TYPE = 25   -- game-undefined ECC: object queries never see it

local function meshMatchesTarget(fn)
    for _, pat in ipairs(TARGET_PATTERNS) do
        if fn:find(pat) then return true end
    end
    return false
end

-- CHUNKED pass state (2026-07-28 late: the single-closure pass was a
-- visible frame HITCH at the 20s mark; the scan now walks ~CHUNK
-- components per 8 Hz tick, sub-millisecond of GT work per frame, full
-- coverage in ~2-3s: well inside the 10s rain ramp). The comps array is
-- held across ticks WITHIN one world only: every touch re-validates, the
-- teardown gate and OnCourseUnload drop the state outright.
local CHUNK = 250
local passState = nil   -- { ci, comps, i, enabledN, casN, scannedN, gtMs, chunks, trigger }

local function startWorldPass(trigger)
    passState = {
        ci = 1, comps = nil, i = 1,
        enabledN = 0, casN = 0, scannedN = 0,
        gtMs = 0.0, maxMs = 0.0, chunks = 0, trigger = trigger,
    }
end

-- Per-ASSET match verdicts, keyed by the mesh userdata's tostring (the
-- OBJECT ADDRESS on this UE4SS build: cheap, unique per live asset).
-- GetFullName is the expensive reflection read; with the cache it runs
-- once per unique mesh asset per course instead of once per disabled
-- component per pass. Cleared on course load/unload.
local meshVerdict = {}

local function processCompGT(st, c)
    if not validRef(c) then return end
    local en = nil
    pcall(function() en = c:GetCollisionEnabled() end)
    if en ~= 0 then return end
    st.scannedN = st.scannedN + 1
    local sm = nil
    pcall(function() sm = c.StaticMesh end)
    if not sm then return end
    local key = nil
    pcall(function() key = tostring(sm) end)
    local verdict = key and meshVerdict[key]
    if verdict == nil then
        local meshName = nil
        pcall(function() meshName = sm:GetFullName() end)
        verdict = (type(meshName) == "string") and meshMatchesTarget(meshName) or false
        if key then meshVerdict[key] = verdict end
    end
    if not verdict then return end
    pcall(function()
        local bs = c.StaticMesh and c.StaticMesh.BodySetup
        if bs then
            if tonumber(bs.CollisionTraceFlag) == 3 then
                st.casN = st.casN + 1
            else
                bs.CollisionTraceFlag = 3
            end
        end
    end)
    pcall(function() c:SetCollisionObjectType(STEALTH_OBJ_TYPE) end)
    pcall(function() c:SetCollisionResponseToAllChannels(0) end)
    pcall(function() c:SetCollisionResponseToChannel(CHANNEL, 2) end)
    pcall(function() c:SetCollisionEnabled(1) end)
    st.enabledN = st.enabledN + 1
end

local finishWorldPassGT   -- defined below (local-ordering rule)

local function passChunkGT()
    local st = passState
    if not st then return end
    local actors = getActors()
    if actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
        passState = nil
        return
    end
    local t0 = os.clock()
    local budget = CHUNK
    while budget > 0 do
        if st.comps == nil then
            local cls = CLASSES[st.ci]
            if cls == nil then
                finishWorldPassGT(st)
                return
            end
            local comps = nil
            pcall(function() comps = FindAllOf(cls) end)
            st.comps = (type(comps) == "table") and comps or {}
            st.i = 1
        end
        local c = st.comps[st.i]
        if c == nil then
            st.comps = nil
            st.ci = st.ci + 1
        else
            pcall(function() processCompGT(st, c) end)
            st.i = st.i + 1
            budget = budget - 1
        end
    end
    st.chunks = st.chunks + 1
    local dMs = (os.clock() - t0) * 1000.0
    st.gtMs = st.gtMs + dMs
    if dMs > st.maxMs then st.maxMs = dMs end
end

--- Pass completion: shape neutralization (private channels only) + the
--- telemetry line. gt_ms_total is the SUM of per-frame GT time across
--- all chunks (each individual chunk stays well under a frame).
finishWorldPassGT = function(st)
    -- Shape-class neutralization, PRIVATE channels only (>= 22, outside
    -- the game-defined 0..21 band: on a game channel like Visibility
    -- these writes would alter real game behavior): query-enabled
    -- Brush/Box/Sphere/Capsule bodies (PP volumes, triggers, section
    -- envelopes, AI sight spheres) must never occlude rain: they are
    -- sensors and invisible volumes, not geometry. Flip their
    -- private-channel response to Ignore (idempotent; the shape classes
    -- are small enough to run inline at pass end).
    local t0 = os.clock()
    local shapesN = 0
    for _, cls in ipairs(CHANNEL >= 22 and SHAPE_CLASSES or {}) do
        pcall(function()
            local comps = FindAllOf(cls)
            if type(comps) ~= "table" then return end
            for _, c in ipairs(comps) do
                if validRef(c) then
                    local en = nil
                    pcall(function() en = c:GetCollisionEnabled() end)
                    if en == 1 or en == 3 then
                        local r = nil
                        pcall(function() r = c:GetCollisionResponseToChannel(CHANNEL) end)
                        if r == 2 then
                            pcall(function() c:SetCollisionResponseToChannel(CHANNEL, 0) end)
                            shapesN = shapesN + 1
                        end
                    end
                end
            end
        end)
    end
    st.gtMs = st.gtMs + (os.clock() - t0) * 1000.0
    lastPass = os.clock()
    passState = nil
    -- Log every triggered pass and any periodic pass that found
    -- streamed-in work; quiet no-op periodic re-passes unless Debug.
    if st.trigger ~= "periodic" or st.enabledN > 0 or shapesN > 0 or DEBUG then
        Log.Info(MODULE, "World rain collision pass", {
            trigger = st.trigger, targetsEnabled = st.enabledN,
            preCtf3 = st.casN, scannedDisabled = st.scannedN,
            shapesIgnored = shapesN, chunks = st.chunks,
            gt_ms_total = string.format("%.1f", st.gtMs),
            gt_ms_maxchunk = string.format("%.1f", st.maxMs),
        })
    end
end

-- ============== PUBLIC API ==============

function RainCollision.Init()
    if isInitialized then return true end

    local cfg = Config.RainCollision
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if tonumber(cfg.Channel) then CHANNEL = tonumber(cfg.Channel) end
        if tonumber(cfg.ReapplySeconds) then REAPPLY_S = tonumber(cfg.ReapplySeconds) end
        if tonumber(cfg.SettleSeconds) then SETTLE_S = tonumber(cfg.SettleSeconds) end
        if cfg.Debug ~= nil then DEBUG = cfg.Debug end
        if type(cfg.TargetPatterns) == "table" and #cfg.TargetPatterns > 0 then
            TARGET_PATTERNS = cfg.TargetPatterns
        end
    end

    isInitialized = true
    State.SetModuleStatus("rain_collision", true)

    if not enabled then
        Log.Info(MODULE, "Rain collision module disabled in config")
        return true
    end
    Log.Info(MODULE, "Initializing rain collision", {
        channel = CHANNEL, reapply_s = REAPPLY_S,
        patterns = table.concat(TARGET_PATTERNS, ","),
    })
    return true
end

function RainCollision.OnCourseLoad()
    armed = true
    armedAt = os.clock()
    nextEnforce = 0.0
    lastPass = nil
    passPending = true      -- first pass after the settle window
    passTrigger = "load"
    passState = nil         -- never carry a walker (and its refs) across worlds
    meshVerdict = {}        -- asset addresses do not survive a world swap
    chanLoggedCourse = false
end

function RainCollision.OnCourseUnload()
    armed = false
    lastPass = nil
    passPending = false
    passState = nil
    meshVerdict = {}
end

--- Rain started or changed (weather.lua Apply path, same wiring as the
--- god-ray gate): request an immediate pass so a mid-course weather flip
--- to rain never waits out the periodic cadence. Dry presets just let the
--- cadence gate close.
function RainCollision.OnWeatherChange(_presetName)
    if not (enabled and armed) then return end
    if isWet() then
        passPending = true
        passTrigger = "rain-start"
    end
end

--- Per-tick entry (8 Hz from main); self-paced. Enforcement (and the
--- private-channel fan) run every ENFORCE_S; while a chunked pass is
--- active, EVERY tick dispatches one chunk so the pass finishes in a few
--- seconds with no single-frame hitch. All object work runs in
--- game-thread closures that re-check the teardown gate at run time.
function RainCollision.Tick()
    if not (enabled and armed and isInitialized) then return true end
    local now = os.clock()
    local chunkActive = passState ~= nil
    local doEnforce = now >= nextEnforce
    if not (chunkActive or doEnforce) then return true end
    if doEnforce then nextEnforce = now + ENFORCE_S end

    local actors = getActors()
    if actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
        passState = nil
        return true
    end
    if (now - armedAt) < SETTLE_S then return true end

    -- The world pass runs only while the weather is wet (zero dry-session
    -- cost): a pending request (course load with a wet restore, rain
    -- start) starts at the next enforce tick, the periodic re-pass covers
    -- streamed-in cells after that. A pending request raised while dry
    -- just waits for the flip to rain. Never start while a pass is
    -- already walking (a restart every enforce tick would starve it).
    local wet, wantStart = false, false
    if doEnforce then
        wet = isWet()
        if wet and passState == nil then
            if passPending then
                wantStart = true
            elseif lastPass == nil or (now - lastPass) >= REAPPLY_S then
                wantStart = true
                passTrigger = "periodic"
            end
        end
    end

    if ExecuteInGameThread then
        pcall(function()
            ExecuteInGameThread(function()
                if doEnforce then
                    enforceChannelGT()
                    -- The fan mutates responses on game bodies: private
                    -- channels only (on a game channel like Visibility
                    -- it would rewrite real game behavior)
                    if wet and CHANNEL >= 22 then containmentFanGT() end
                end
                if wantStart and passState == nil then
                    startWorldPass(passTrigger)
                end
                if passState ~= nil then passChunkGT() end
            end)
        end)
        if wantStart then passPending = false end
    end
    return true
end

function RainCollision.GetStatus()
    return {
        initialized = isInitialized,
        enabled = enabled,
        armed = armed,
        channel = CHANNEL,
        lastPassAgo = lastPass and (os.clock() - lastPass) or nil,
    }
end

function RainCollision.IsInitialized()
    return isInitialized
end

--- Alias so the module can be ticked as either Tick() or Update().
RainCollision.Update = RainCollision.Tick

return RainCollision
