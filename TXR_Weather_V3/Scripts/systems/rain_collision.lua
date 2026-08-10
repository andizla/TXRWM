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
local FIX_SHADOW_LEAK = false  -- sun-leak fix; permanent shipping feature, config default true (see processCompGT)
local DEBUG = false
-- Lua patterns matched against each disabled mesh component's STATIC MESH
-- asset full name: tunnel linings/pieces ("tnl"), the Mesh_tn interior-set
-- folders, and bridge/overpass deck pieces ("_br" suffix; the trailing
-- "%." / "$" anchor it to the asset name end, so "_brk"-style names never
-- match). Extend from field data via Config.RainCollision.TargetPatterns.
-- HARD CONSTRAINT: this list feeds the COLLISION block, and mass collision
-- enablement is the proven AI breaker (v7/v8 field failures, both
-- channels). Keep it to the v9 trio unless a confirmed rain-through spot
-- names a new asset. Shadow-only families go in SHADOW_PATTERNS below.
local TARGET_PATTERNS = { "tnl", "Mesh_tn", "_br%.", "_br$" }
-- Patterns for the sun-leak SHADOW flip only (broad structural roster:
-- walls/kerbs/sidewalks/aprons). Rendering flags only, never collision,
-- so breadth is safe here. Config.RainCollision.ShadowFixPatterns.
local SHADOW_PATTERNS = TARGET_PATTERNS

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
--- the AI vector all along, never the Visibility writes; the call was:
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
-- FIELD DATA 2026-07-29: across ~30 passes the per-class match counter
-- read `Stat=N Inst=0 Hier=0` EVERY time. Tunnel linings and bridge decks
-- are unique large meshes; the instanced classes carry scattered props and
-- never match a target pattern. Sweeping them cost 2 of the 3 FindAllOf
-- calls per pass for nothing, so they are retired. (If a future target
-- pattern ever needs instanced geometry, add the class back here and the
-- matchedBy counter will show it earning its keep.)
local CLASSES = {
    "StaticMeshComponent",
}
local SHAPE_CLASSES = {
    "BrushComponent",
    "BoxComponent",
    "SphereComponent",
    "CapsuleComponent",
}
local STEALTH_OBJ_TYPE = 25   -- game-undefined ECC: object queries never see it

local function meshMatchesAny(fn, patterns)
    for _, pat in ipairs(patterns) do
        if fn:find(pat) then return true end
    end
    return false
end

-- CHUNKED pass state. Two rounds of hitch work:
--   1. (first cut) the single-closure pass was a visible frame stall, so
--      the scan walks CHUNK components per 8 Hz tick.
--   2. (2026-07-28 telemetry: gt_ms_maxchunk read 27-34 ms) the residue
--      was FindAllOf itself: one unsplittable ~30 ms block that ran ON
--      THE GAME THREAD, three times per pass. That breaks our own
--      standing rule (sweeps are free on the async thread and ruinous on
--      the GT), so the fetch now happens ASYNC in Tick and only the
--      component work is marshalled. With the sweep gone the GT slices
--      cost ~1-5 ms, so CHUNK went up 4x: the pass finishes in ~3-4 ticks
--      instead of ~14, which also shrinks the window where component
--      refs are held across ticks (a cell streaming out mid-pass is the
--      one remaining dangling-ref risk).
-- The comps array lives WITHIN one world only: every touch re-validates,
-- and the teardown gate plus OnCourseLoad/Unload drop the state outright.
local CHUNK = 250   -- was 400: with the verdict cache dead, 400-comp
                    -- chunks ran 7-27ms ON THE GT (2026-08-10 13:55
                    -- field log) = dropped frames at every course entry
                    -- and ~23s micro-hitches while driving. 250 caps the
                    -- worst case; the GetAddress cache fix below cuts the
                    -- per-comp cost underneath it as well.
local passState = nil   -- see startWorldPass for the shape

local function startWorldPass(trigger)
    passState = {
        ci = 1, comps = nil, i = 1,
        enabledN = 0, casN = 0, scannedN = 0,
        gtMs = 0.0, maxMs = 0.0, chunks = 0, trigger = trigger,
        -- per-class match counts: one boot of data decides whether the
        -- instanced classes are ever worth sweeping (tunnel linings and
        -- decks are unique meshes; instancing is for scattered props)
        perClass = {},
    }
end

-- DISTANCE GATE state. K2_GetActorLocation is a UFunction, so the car
-- position is read on the GAME THREAD (one call per enforce tick, riding
-- the closure that is already dispatched) and cached as plain numbers
-- that the async side reads: the standing "cache on GT, async consumes
-- the verdict" pattern. Fails OPEN in every unknown case, so a missing
-- reading can never silently stop the pass from running.
local MOVE_THRESHOLD = 2500.0   -- uu (25 m); cells cannot stream without motion
local carX, carY, carZ = nil, nil, nil          -- GT-written, async-read
local passOX, passOY, passOZ = nil, nil, nil    -- car position at pass start

local function updateCarPosGT()
    -- Run-time teardown re-check, same as every other GT closure body in
    -- this module: the closure can land while the GT is destroying the
    -- world, and pcall cannot catch that AV (IsValid can false-pass too).
    local actors = getActors()
    if actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
        return
    end
    pcall(function()
        local UEH = getUEHelpers()
        local pc = UEH and UEH.GetPlayerController and UEH.GetPlayerController()
        local pawn = pc and pc.Pawn
        if pawn and pawn.IsValid and pawn:IsValid() then
            local loc = pawn:K2_GetActorLocation()
            if loc then
                carX, carY, carZ = tonumber(loc.X), tonumber(loc.Y), tonumber(loc.Z)
            end
        end
    end)
end

--- Has the car moved far enough since the last pass for new cells to
--- have streamed in? Unknown position, or no recorded origin = TRUE
--- (fail open: never skip work because a reading is missing).
local function movedSincePass()
    if carX == nil or passOX == nil then return true end
    local dx, dy, dz = carX - passOX, carY - passOY, carZ - passOZ
    return (dx * dx + dy * dy + dz * dz) >= (MOVE_THRESHOLD * MOVE_THRESHOLD)
end

local function markPassOrigin()
    passOX, passOY, passOZ = carX, carY, carZ
end

-- Per-ASSET match verdicts, keyed by the mesh userdata's tostring (the
-- OBJECT ADDRESS on this UE4SS build: cheap, unique per live asset).
-- GetFullName is the expensive reflection read; with the cache it runs
-- once per unique mesh asset per course instead of once per disabled
-- component per pass. Cleared on course load/unload.
-- KEY STABILITY IN DOUBT (2026-08-09): a PA pass logged 56 fresh
-- verdicts for ONE asset name (SMobj_pylon_a), and a later pass in the
-- same world recomputed pylon verdicts without flipping anything (the
-- components were already two-sided), consistent with the Alt+I lesson:
-- tostring keys that do not survive re-access. cacheMiss= in the pass
-- line measures it. If it tracks scanned across passes the cache never
-- hits and every component pays GetFullName every pass. That cost is
-- already inside today's measured gt_ms numbers, so leave the cache
-- alone until the counter has field data.
local meshVerdict = {}
-- Raised 25 -> 60 (2026-07-30): at 25 the list was truncating before we
-- could tell whether a newly added pattern (_wc/_wl/_wr, _kb) had matched
-- anything at all, which is the question the log exists to answer.
local MATCHED_NAME_CAP = 60
local matchedNamesLogged = 0
-- Log dedupe by SHORT NAME (2026-08-09): the address-keyed cache above
-- does not dedupe same-named meshes (the 56 pylon lines), so the cap now
-- counts unique NAMES: one prop family can no longer blind the readout
-- the cap exists for. Bounded at MATCHED_NAME_CAP entries; cleared with
-- the cache.
local matchedNamesSeen = {}
-- (shadowFlipped and the Alt+I forcePass state deleted 2026-08-04 with
-- the toggle: the revert path keyed on tostring(component), which is not
-- stable across passes, so an A/B via toggle falsely exonerated the fix.)

--- Order matters for cost (2026-07-29 telemetry: gt_ms_maxchunk stayed
--- ~20 ms after the sweep moved off the GT, so the PER-COMPONENT work
--- was the real expense at ~15-20 us each). GetCollisionEnabled is a
--- UFunction call (ProcessEvent marshalling); the asset verdict is a
--- property read plus a cached table lookup. So the cheap check runs
--- FIRST and the UFunction only runs for the handful of components whose
--- mesh actually matches. The en==0 gate stays exactly where it was, as
--- a SAFETY property (never touch a body the game already enabled), it
--- is just consulted later.
local function processCompGT(st, c)
    if not validRef(c) then return end
    st.scannedN = st.scannedN + 1
    local sm = nil
    pcall(function() sm = c.StaticMesh end)
    if not sm then return end
    -- OBJECT-address key (2026-08-10): tostring(sm) keys never repeat
    -- because every c.StaticMesh access mints a fresh userdata, so the
    -- cache never hit (cacheMiss==scanned on every pass, 08-09 and 08-10
    -- field logs) and every component re-paid GetFullName every pass:
    -- the bulk of the 7-27ms GT chunks. GetAddress is the UObject
    -- address (stable per live asset, proven idiom in tuning.lua);
    -- cleared per world with the rest of the cache, so it cannot alias
    -- across worlds.
    local key = nil
    pcall(function() key = sm:GetAddress() end)
    if key == nil then pcall(function() key = tostring(sm) end) end
    local verdict = key and meshVerdict[key]
    if verdict == nil then
        st.missN = (st.missN or 0) + 1   -- fresh verdict computed (cacheMiss=)
        local meshName = nil
        pcall(function() meshName = sm:GetFullName() end)
        if type(meshName) == "string" then
            verdict = {
                coll = meshMatchesAny(meshName, TARGET_PATTERNS),
                shadow = meshMatchesAny(meshName, SHADOW_PATTERNS),
            }
        else
            verdict = { coll = false, shadow = false }
        end
        if key then meshVerdict[key] = verdict end
        -- Name the ASSETS we accept, deduped by SHORT NAME and capped.
        -- This is the readout that answers "are we flipping the right
        -- meshes?": the patterns are substring matches, so an unintended
        -- asset with "tnl" in its path would otherwise be invisible in
        -- the counts. Name-keyed on purpose (2026-08-09): the address-
        -- keyed cache above missed 56 times on one pylon asset in a
        -- single PA pass and the cap spent itself on duplicates.
        if (verdict.coll or verdict.shadow)
           and matchedNamesLogged < MATCHED_NAME_CAP then
            local short = (type(meshName) == "string")
                and (meshName:match("([^%.%s/]+)$") or meshName) or "?"
            if not matchedNamesSeen[short] then
                matchedNamesSeen[short] = true
                matchedNamesLogged = matchedNamesLogged + 1
                Log.Info(MODULE, "Target asset matched", {
                    n = matchedNamesLogged,
                    as = verdict.coll and (verdict.shadow and "coll+shadow" or "coll")
                        or "shadow",
                    mesh = short,
                })
            end
        end
    end
    if not (verdict.coll or verdict.shadow) then return end

    -- SUN-LEAK FIX (permanent, Config.RainCollision.FixShadowLeak).
    -- Field-proven diagnosis 2026-07-29: these decks ship CastShadow=true
    -- but bCastShadowAsTwoSided=FALSE, so from the sun's side the shadow
    -- depth pass culls their backfaces, writes no depth, and sunlight
    -- lands INSIDE the tunnel. Same one-sided geometry that makes rain
    -- traces need an upward leg: one authoring decision, two leaks.
    -- bCastShadowAsTwoSided has NO setter on this cook and UE snapshots
    -- it into the scene proxy at render-state creation, so a bare write
    -- is a silent no-op. SetCastShadow DOES exist and dirties render
    -- state, but early-outs on an unchanged value: hence the false->true
    -- toggle to force the proxy to rebuild and pick the flag up.
    -- Deliberately OUTSIDE the en==0 gate below: a leaking deck usually
    -- already has collision, so gating the shadow write on "collision
    -- disabled" would skip exactly the meshes that leak. Idempotent: the
    -- twoSided read short-circuits once a component is done.
    -- Keys on the SHADOW verdict (broad roster); the collision block below
    -- keys on the narrow coll verdict. The lists were one until 2026-08-04:
    -- the kerb-hunt pattern expansion silently widened the STEALTH BODY
    -- set to every wall/kerb/sidewalk, re-creating the v7/v8 mass-
    -- enablement AI breakage the v9 targeting exists to prevent.
    -- (The Alt+I live-revert machinery is deleted: its revert keyed on
    -- tostring(component), which is not stable across passes, so an A/B
    -- via toggle falsely exonerates the fix. A/B by course reload.)
    if verdict.shadow and FIX_SHADOW_LEAK then
        local twoSided = nil
        pcall(function() twoSided = c.bCastShadowAsTwoSided end)
        if twoSided == false then
            pcall(function() c.bCastShadowAsTwoSided = true end)
            -- Force the proxy rebuild that makes the flag take effect
            pcall(function() c:SetCastShadow(false) end)
            pcall(function() c:SetCastShadow(true) end)
            st.shadowN = (st.shadowN or 0) + 1
        end
    end

    -- Matching COLLISION mesh (narrow v9 set only): only now pay for the
    -- UFunction. en ~= 0 means the game already gave this body collision,
    -- so leave it strictly alone.
    if not verdict.coll then return end
    local en = nil
    pcall(function() en = c:GetCollisionEnabled() end)
    if en ~= 0 then
        -- AI-residual forensics (2026-08-07, parked risk (c)): this is a
        -- STOCK-ENABLED instance of a target asset. The BodySetup
        -- CollisionTraceFlag=3 write below lands on the SHARED asset, so
        -- these instances silently go ComplexAsSimple too: AI queries
        -- against them return trimesh hits instead of simple-hull hits.
        -- A nonzero count in the pass log = risk (c) is live geometry.
        -- MOD-ENABLED FILTER (2026-08-09): everything the block below
        -- enables is stamped ObjectType 25; stock geometry carries a
        -- real game type. Without the filter the counter re-counted our
        -- own targets on every later pass (both 08-08 logs: enable 43,
        -- next pass stockEnabledTargets=43; enable 218, next pass 218),
        -- so the risk (c) watch measured nothing. Cost: one UFunction
        -- read per already-enabled target (218-target worst case ~4 ms,
        -- spread across chunks). A failed read (ot=nil) still counts as
        -- stock: over-counting fails toward the pre-filter behavior,
        -- never toward hiding a live risk.
        local ot = nil
        pcall(function() ot = c:GetCollisionObjectType() end)
        if ot ~= STEALTH_OBJ_TYPE then
            st.collStockN = (st.collStockN or 0) + 1
        end
        return
    end
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
    local cls = CLASSES[st.ci]
    if cls then st.perClass[cls] = (st.perClass[cls] or 0) + 1 end
end

local finishWorldPassGT   -- defined below (local-ordering rule)

--- ASYNC side of the pass: fetch the next class array when the walker
--- needs one. FindAllOf is an object-array walk (~30 ms on this world),
--- which is exactly the work that belongs off the game thread. Teardown
--- must be gated here just like any other async sweep (the wet_grip
--- lesson: an ungated sweep runs against a dying world).
--- @return boolean true if a GT chunk is worth dispatching
local function passFetchAsync()
    local st = passState
    if not st then return false end
    if st.comps ~= nil then return true end
    local cls = CLASSES[st.ci]
    if cls == nil then return true end   -- exhausted: let the GT side finish
    local comps = nil
    pcall(function() comps = FindAllOf(cls) end)
    st.comps = (type(comps) == "table") and comps or {}
    st.i = 1
    st.sweeps = (st.sweeps or 0) + 1
    return true
end

--- GAME-THREAD side: process up to CHUNK components from the array the
--- async side fetched. Never sweeps; when it runs out of the current
--- array it stops and lets the next async tick fetch the next class.
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
            -- Out of components and nothing fetched yet: if every class is
            -- done the pass ends here, otherwise wait for the async fetch.
            if CLASSES[st.ci] == nil then
                finishWorldPassGT(st)
                return
            end
            break
        end
        local c = st.comps[st.i]
        if c == nil then
            st.comps = nil          -- class exhausted; async fetches the next
            st.ci = st.ci + 1
            break
        end
        pcall(function() processCompGT(st, c) end)
        st.i = st.i + 1
        budget = budget - 1
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
    if st.trigger ~= "periodic" or st.enabledN > 0 or shapesN > 0
        or (st.shadowN or 0) > 0 or DEBUG then
        local byClass = {}
        for _, cls in ipairs(CLASSES) do
            byClass[#byClass + 1] = cls:sub(1, 4) .. "=" .. (st.perClass[cls] or 0)
        end
        Log.Info(MODULE, "World rain collision pass", {
            trigger = st.trigger, targetsEnabled = st.enabledN,
            preCtf3 = st.casN, scanned = st.scannedN,
            shapesIgnored = shapesN, chunks = st.chunks,
            sweeps = st.sweeps or 0,
            shadowFixed = st.shadowN or 0,
            shadowReverted = st.shadowRevertedN or 0,
            -- AI-residual forensics (2026-08-07): stockEnabledTargets > 0
            -- means the shared BodySetup ctf=3 write reaches stock-enabled
            -- instances of target assets (parked risk (c)); pos lets a
            -- field "AI bugged HERE around THEN" report be matched against
            -- pass activity (shadow rebuilds / enables) near that spot.
            stockEnabledTargets = st.collStockN or 0,
            -- cacheMiss (2026-08-09): fresh meshVerdict computes this
            -- pass. If it tracks scanned pass after pass, the address
            -- key is not stable and the cache never hits (see the note
            -- at meshVerdict).
            cacheMiss = st.missN or 0,
            pos = (carX and string.format("%.0f,%.0f,%.0f", carX, carY, carZ))
                or "?",
            matchedBy = table.concat(byClass, " "),
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
        if cfg.FixShadowLeak ~= nil then FIX_SHADOW_LEAK = cfg.FixShadowLeak end
        if type(cfg.TargetPatterns) == "table" and #cfg.TargetPatterns > 0 then
            TARGET_PATTERNS = cfg.TargetPatterns
        end
        if type(cfg.ShadowFixPatterns) == "table" and #cfg.ShadowFixPatterns > 0 then
            SHADOW_PATTERNS = cfg.ShadowFixPatterns
        else
            SHADOW_PATTERNS = TARGET_PATTERNS
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
        shadow_patterns = table.concat(SHADOW_PATTERNS, ","),
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
    matchedNamesLogged = 0
    matchedNamesSeen = {}
    carX, carY, carZ = nil, nil, nil        -- coordinates are world-local
    passOX, passOY, passOZ = nil, nil, nil  -- (stale ones would mis-gate)
    chanLoggedCourse = false
end

function RainCollision.OnCourseUnload()
    armed = false
    lastPass = nil
    passPending = false
    passState = nil
    meshVerdict = {}
    matchedNamesLogged = 0
    matchedNamesSeen = {}
    carX, carY, carZ = nil, nil, nil
    passOX, passOY, passOZ = nil, nil, nil
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
    -- The pass normally only runs while wet (zero dry-session cost). The
    -- shadow-leak fix is the exception and MUST break that rule: the sun
    -- leak happens in DRY, SUNNY weather, so gating it behind the rain
    -- check meant it could never run when it mattered (field 2026-07-29
    -- 18:00, Clear_Skies session: zero passes, "it didnt take").
    local wet, wantStart = false, false
    if doEnforce then
        wet = isWet()
        if (wet or FIX_SHADOW_LEAK) and passState == nil then
            if passPending then
                wantStart = true
            elseif lastPass == nil or (now - lastPass) >= REAPPLY_S then
                -- DISTANCE GATE: world-partition cells only stream in when
                -- the car moves, so a periodic re-pass after sitting still
                -- is guaranteed to find nothing. Skip it (and re-arm the
                -- cadence) unless we have travelled far enough for new
                -- cells to have appeared. Triggered passes (load, rain
                -- start) ignore this: they must always run.
                if movedSincePass() then
                    wantStart = true
                    passTrigger = "periodic"
                else
                    lastPass = now
                end
            end
        end
    end

    -- ASYNC: fetch the component array here, never on the game thread
    -- (the ~30 ms FindAllOf was the residual hitch; this is the thread it
    -- belongs on). Safe because the teardown gate above already returned.
    if wantStart and passState == nil then
        startWorldPass(passTrigger)
        markPassOrigin()
        passPending = false
    end
    if passState ~= nil then passFetchAsync() end

    if ExecuteInGameThread then
        pcall(function()
            ExecuteInGameThread(function()
                if doEnforce then
                    enforceChannelGT()
                    updateCarPosGT()   -- feeds the async distance gate
                    -- The fan mutates responses on game bodies: private
                    -- channels only (on a game channel like Visibility
                    -- it would rewrite real game behavior)
                    if wet and CHANNEL >= 22 then containmentFanGT() end
                end
                if passState ~= nil then passChunkGT() end
            end)
        end)
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
