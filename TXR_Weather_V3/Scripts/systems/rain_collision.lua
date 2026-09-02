-- TXR Weather Mod v3.0
-- systems/rain_collision.lua
-- Native rain occlusion, production form (v9 targeted, 2026-07-28).
-- Why targeted: v7 flipped the whole world rain-solid and v8 moved rain
-- to private channel 25 without the Visibility writes; the AI broke on
-- both, so the mass enablement was the AI vector, not the responses (v8
-- also killed rain globally under containing bodies until the
-- containment fan). v9 flips only the meshes that matter and hides them
-- from the game:
--   1. Targeted flip: disabled mesh components whose static-mesh asset
--      path matches TargetPatterns (tunnel linings "tnl", Mesh_tn
--      interior sets, bridge/overpass decks "_br": every confirmed
--      occluder in the field digs) get CollisionTraceFlag=3
--      (ComplexAsSimple; live readback proved 3) + QueryOnly enable.
--   2. Stealth bodies: each flipped body gets ObjectType=25 (a
--      game-undefined channel no AI object-space query can include) +
--      Ignore-all responses + Block on the rain channel alone. Rain
--      traces hit it; every other query and overlap passes through.
--   3. UDW's 'Weather Particle Collision Channel' is enforced at
--      Config.RainCollision.Channel (default 3 = stock Visibility,
--      field-verified; 22+ = the private-channel experiment, which also
--      arms the containment fan and shape neutralization below). Write +
--      'Update Static Variables' = the proven full re-bake.
-- Cells that stream in after a pass are un-flipped (16:53/17:06/17:07
-- field sequence), so the pass re-runs on a cadence while wet, is
-- idempotent (enabled components skip after one cheap read), and fires
-- at once on rain start. Dry sessions cost one property read per
-- enforcement tick.

local RainCollision = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local GT = require("core.gt")
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
-- Car sweep cadence: the panel/probe flip needs the pawn once per pawn, so
-- after the first pawn is processed the sweep drops to a 30 s safety net (a
-- new pawn in the same world, e.g. a race retry, is caught within that)
local CAR_SWEEP_FIRST_S = 2.0
local CAR_SWEEP_SETTLED_S = 30.0
local carSweepLast = 0.0
local carSweepInterval = CAR_SWEEP_FIRST_S
local FIX_SHADOW_LEAK = false  -- sun-leak fix; permanent shipping feature, config default true (see processCompGT)
-- Config.RainCollision.CtfWrite (default true = shipping behavior).
-- false = the pass never writes BodySetup CollisionTraceFlag and relies
-- on the pak-baked ComplexAsSimple instead (the 4.0.0 rehearsal): with
-- the test paks installed, occlusion works only where a pak covers the
-- mesh (preCtf3 counts those); an enabled target whose BodySetup still
-- lacks CTF shows up in ctfMissing= and rains through.
local CTF_WRITE = true
-- Config.RainCollision.PlayerCarProbe (default false): flips the rain
-- channel to Block on every enabled StaticMeshComponent the pawn owns and
-- logs each one, so a boot with rain shedding on the car names the
-- working component. Channel 3 is stock Visibility, so watch for
-- camera/HUD oddities during a probe boot; that risk is why this is a
-- probe and not the feature.
local PLAYER_CAR_PROBE = false
-- Config.RainCollision.PlayerCarBody (2026-08-12): the probe proved UDW
-- rain paths collide with pawn-owned blockers (splashes and rings on the
-- flipped hitbox envelope, floating ~10cm over the roof because the
-- envelope is oversized). The right surface is BaseBody: the tight visual
-- body mesh, sized per car, and AI vehicles already run it
-- collision-enabled (the AE86 sun-probe hit), so enabling the player's
-- matches the game's own state.
local PLAYER_CAR_BODY = false
-- Shadow-roster meshes shipping CastShadow=false never cast regardless
-- of two-sided flags; test key forces them on (see processCompGT).
local FORCE_CAST_SHADOW = false
local DEBUG = false
-- Lua patterns matched against each disabled mesh component's static
-- mesh asset full name: tunnel linings ("tnl"), the Mesh_tn interior-set
-- folders, and bridge/overpass decks ("_br"; the "%." / "$" anchors pin
-- it to the asset name end, so "_brk"-style names never match). Extend
-- via Config.RainCollision.TargetPatterns. Hard constraint: this list
-- feeds the collision block, and mass collision enablement is the proven
-- AI breaker (v7/v8, both channels), so keep it to the v9 trio unless a
-- confirmed rain-through spot names a new asset. Shadow-only families go
-- in SHADOW_PATTERNS.
local TARGET_PATTERNS = { "tnl", "Mesh_tn", "_br%.", "_br$" }
-- Sun-leak shadow flip only (broad structural roster: walls/kerbs/
-- sidewalks/aprons). Rendering flags, never collision, so breadth is safe.
-- Config.RainCollision.ShadowFixPatterns.
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

--- Keep UDW's particle collision channel at CHANNEL. Cheap steady state
--- (one property read); writes + re-bakes only when the live value
--- differs (fresh course instance, or CoolConsoleCommands' warmup
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

-- ============== INTERNAL: player-car rain collision (game thread) ==============

-- Probe state: pawns already swept this world (keyed by pawn address)
local probeDonePawns = {}
-- Panel-route state: pawns whose body panels are already flipped
local panelDonePawns = {}

-- Body-panel mesh families (Lua patterns on the short mesh name); _EF_
-- and SM_Hit are excluded by the rejects below.
local PANEL_PATTERNS = {
    "^SM_Body_", "^SM_BN_", "^SM_FB_", "^SM_RB_",
    "^SM_SS_", "^SM_RS_", "^SM_Window_", "^SM_RHL_",
}
-- SM_Aura_Body rejected 2026-08-12: an inflated ghost shell (outline
-- effect mesh); flipping it recreated the floating-plane artifact a few
-- cm off the paint (field: rings on an invisible plane, door hits only
-- where the shell does not wrap). SM_Hit is the even bigger envelope.
local PANEL_REJECTS = { "_EF_", "EF$", "^SM_Hit", "^SM_Aura", "DriverModel" }

local function isPanelMesh(short)
    for _, rej in ipairs(PANEL_REJECTS) do
        if short:find(rej) then return false end
    end
    for _, pat in ipairs(PANEL_PATTERNS) do
        if short:find(pat) then return true end
    end
    return false
end

--- Flip the rain response on every pawn-owned body-panel SMC, once per
--- pawn instance. Runs in the GT closure like the probe sweep.
local function playerCarPanelsGT(pawn, comps)
    local pawnAddr = nil
    pcall(function() pawnAddr = pawn:GetAddress() end)
    if not pawnAddr or panelDonePawns[pawnAddr] then return end
    panelDonePawns[pawnAddr] = true
    local flipped, enabled, suppressed = 0, 0, 0
    pcall(function()
        if type(comps) ~= "table" then return end
        for _, c in ipairs(comps) do
            if validRef(c) then
                local mine = false
                pcall(function()
                    local o = c:GetOwner()
                    mine = o and o:GetAddress() == pawnAddr
                end)
                if mine then
                    local short = nil
                    pcall(function()
                        local sm = c.StaticMesh
                        local fn = sm and sm:GetFullName()
                        if type(fn) == "string" then
                            short = fn:match("([^%.%s/]+)$")
                        end
                    end)
                    if short and isPanelMesh(short) then
                        local en = nil
                        pcall(function() en = c:GetCollisionEnabled() end)
                        if en == 0 then
                            pcall(function() c:SetCollisionResponseToAllChannels(0) end)
                            pcall(function() c:SetCollisionEnabled(1) end)
                            enabled = enabled + 1
                        end
                        local wrote = pcall(function()
                            c:SetCollisionResponseToChannel(CHANNEL, 2)
                        end)
                        if wrote then flipped = flipped + 1 end
                    elseif short and (short:find("^SM_Hit")
                            or short:find("^SM_Aura")) then
                        -- Counter-flip the inflated envelopes (10cm-proud
                        -- shells): one that is enabled and blocking the
                        -- rain channel (stock state unknown: the probe
                        -- only logged what it changed) eats the paths
                        -- before the real panels can. Force Ignore.
                        local resp = nil
                        pcall(function() resp = c:GetCollisionResponseToChannel(CHANNEL) end)
                        if resp and resp ~= 0 then
                            pcall(function() c:SetCollisionResponseToChannel(CHANNEL, 0) end)
                            suppressed = suppressed + 1
                        end
                    end
                end
            end
        end
    end)
    Log.Info(MODULE, "Player car panels rain collision applied", {
        panels = flipped, newlyEnabled = enabled,
        envelopesSuppressed = suppressed, channel = CHANNEL,
    })
end

--- Probe sweep (PLAYER_CAR_PROBE): flip the rain channel to Block on
--- every enabled SMC the current pawn owns, once per pawn instance.
local function playerCarProbeGT(pawn, comps)
    local pawnAddr = nil
    pcall(function() pawnAddr = pawn:GetAddress() end)
    if not pawnAddr or probeDonePawns[pawnAddr] then return end
    probeDonePawns[pawnAddr] = true
    local flipped = 0
    pcall(function()
        if type(comps) ~= "table" then return end
        for _, c in ipairs(comps) do
            if validRef(c) then
                local mine = false
                pcall(function()
                    local o = c:GetOwner()
                    mine = o and o:GetAddress() == pawnAddr
                end)
                if mine then
                    local en = nil
                    pcall(function() en = c:GetCollisionEnabled() end)
                    if en and en ~= 0 then
                        local resp = nil
                        pcall(function() resp = c:GetCollisionResponseToChannel(CHANNEL) end)
                        if resp ~= 2 then
                            local wrote = pcall(function()
                                c:SetCollisionResponseToChannel(CHANNEL, 2)
                            end)
                            flipped = flipped + 1
                            local nm = "?"
                            pcall(function()
                                local sm = c.StaticMesh
                                local fn = sm and sm:GetFullName()
                                if type(fn) == "string" then
                                    nm = fn:match("([^%.%s/]+)$") or fn
                                end
                            end)
                            Log.Info(MODULE, "CarProbe flip", {
                                mesh = nm, en = en, was = resp,
                                wrote = tostring(wrote),
                            })
                        end
                    end
                end
            end
        end
    end)
    Log.Info(MODULE, "CarProbe pawn sweep done", { flipped = flipped })
end

--- Worker for the car routes (probe, body panels): resolves the pawn on
--- the game thread and hands it, with the async-fetched component array,
--- to whichever routes are on. Each route runs once per pawn, so after
--- the first pawn the steady state is one pawn lookup per car sweep.
local function playerCarGT(comps)
    local actors = getActors()
    if actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
        return
    end
    pcall(function()
        local UEH = getUEHelpers()
        local pc = UEH and UEH.GetPlayerController and UEH.GetPlayerController()
        local pawn = pc and pc.Pawn
        if not (pawn and pawn.IsValid and pawn:IsValid()) then return end
        carSweepInterval = CAR_SWEEP_SETTLED_S   -- pawn seen: safety-net cadence from here
        -- (The Tick gate must arm this worker when any car route is on:
        -- the first PlayerCarBody boot, 2026-08-12, did nothing because
        -- the gate checked a single flag.)
        if PLAYER_CAR_PROBE then playerCarProbeGT(pawn, comps) end
        -- Panel-family route (2026-08-12, from the mesh catalog: the
        -- visible body panels are the right rain surface): every
        -- pawn-owned SMC whose mesh is a Body shell, BN bonnet, FB/RB
        -- bumper, SS skirt, RS spoiler or Window (the convention holds
        -- across the whole Car tree, addons included). Excluded: SM_Hit
        -- (the oversized envelope, the floating-ring artifact) and _EF_
        -- effect cards (emissive glows, not surfaces). Recipe per panel:
        -- enable QueryOnly with zeroed responses when disabled stock, then
        -- Block the rain channel; never ObjectType, never BodySetup
        -- (shared assets).
        if PLAYER_CAR_BODY then
            pcall(function() playerCarPanelsGT(pawn, comps) end)
        end
    end)
end

-- ============== INTERNAL: containment fan (game thread) ==============

--- Containment fan (private channels only). 2026-07-28 17:49 field: zero
--- rain anywhere on channel 25 despite a healthy apply, because a body
--- whose simple collision contains the car (section-envelope volumes, AI
--- sight spheres, sky enclosures) default-Blocks an undefined channel;
--- UDW's per-particle ceiling probe (8000 uu up) then hits it at
--- distance ~0 from every spawn point and all rain dies. Such bodies
--- ignore Visibility by authored response, but nothing authored the high
--- channels. Fix: an upward object-type trace fan from the car; any hit
--- at containment distance (< 50 uu; real ComplexAsSimple geometry hits
--- at true surface distances) that Blocks the private channel gets that
--- one response flipped to Ignore. Nothing in the game queries the
--- channel, so the write is invisible to every other system. 21 traces
--- per enforce tick while wet; each write logs the culprit's name.
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

--- Targeted rain-solid pass (v9, 2026-07-28): only mesh components whose
--- static mesh asset path matches the target patterns get flipped, and
--- each flipped body becomes a stealth body: CollisionTraceFlag = 3
--- (ComplexAsSimple, so simple rain traces route to the cooked trimesh),
--- QueryOnly enable (en 0 -> 1 only, physics never touched), ObjectType
--- 25, and Ignore-all + Block on the rain channel (no overlap events, no
--- phantom hits on any game channel). Idempotent: enabled components
--- skip after one read; disabled non-matching components pay one
--- asset-name read per pass (ms= in the log is the real cost).
-- Classes swept. The instanced classes were retired 2026-07-29 on a C1
-- census (Inst=0 Hier=0 across ~30 passes) and restored 2026-09-02: with
-- the same paks installed, 3.8.0 (which swept all three) occludes every
-- bore and 3.9.0 through 4.0.0 (static only) occlude none, so instanced
-- linings exist that the census never saw. The matchedBy counter in the
-- pass line shows what each class contributes.
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

local function meshMatchesAny(fn, patterns)
    for _, pat in ipairs(patterns) do
        if fn:find(pat) then return true end
    end
    return false
end

-- Chunked pass state. The single-closure pass was a visible frame stall,
-- so the scan walks CHUNK components per 8 Hz tick; the residue
-- (2026-07-28 telemetry: gt_ms_maxchunk 27-34 ms) was FindAllOf itself,
-- an unsplittable ~30 ms block on the game thread three times per pass,
-- so the fetch now happens async in Tick and only the component work is
-- marshalled (GT slices ~1-5 ms; a cell streaming out mid-pass is the one
-- remaining dangling-ref risk). The comps array lives within one world:
-- every touch re-validates, and the teardown gate plus
-- OnCourseLoad/Unload drop the state outright.
local CHUNK = 250   -- 400-comp chunks ran 7-27ms on the GT (2026-08-10
                    -- 13:55 field log): dropped frames at every course
                    -- entry and ~23s micro-hitches while driving. 250 caps
                    -- the worst case; the GetAddress verdict cache cuts
                    -- the per-comp cost underneath it.
local CHUNK_BUDGET_S = 0.004   -- game-thread time per chunk (see passChunkGT)
local passState = nil   -- see startWorldPass for the shape

local function startWorldPass(trigger)
    passState = {
        ci = 1, comps = nil, i = 1,
        enabledN = 0, casN = 0, scannedN = 0,
        gtMs = 0.0, maxMs = 0.0, chunks = 0, trigger = trigger,
        -- per-class match counts (matchedBy= in the pass line)
        perClass = {},
    }
end

-- Distance gate state. The car position comes from tunnels' pawn cache
-- (plain numbers, async-readable); the gate fails open in every unknown
-- case, so a missing reading can never silently stop the pass.
local MOVE_THRESHOLD = 2500.0   -- uu (25 m); cells cannot stream without motion
local carX, carY, carZ = nil, nil, nil          -- async-read from tunnels' pawn cache
local passOX, passOY, passOZ = nil, nil, nil    -- car position at pass start

local Tunnels = nil
local function getTunnels()
    if not Tunnels then
        local ok, mod = pcall(require, "systems.tunnels")
        if ok then Tunnels = mod end
    end
    return Tunnels
end

--- Async side: the car position comes from tunnels' 4 Hz pawn cache (a
--- plain number triple), so no controller sweep runs on the game thread
--- for it any more.
local function updateCarPosAsync()
    local T = getTunnels()
    if not (T and T.GetCarPos) then return end
    local px, py, pz = T.GetCarPos()
    if px and py and pz then carX, carY, carZ = px, py, pz end
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

-- Per-asset match verdicts keyed by the mesh's GetAddress (the UObject
-- address, stable per live asset, the tuning.lua idiom). tostring(sm)
-- minted a fresh userdata per access, so that key never hit
-- (cacheMiss==scanned on every pass, 08-09 and 08-10 field logs) and
-- every component re-paid GetFullName, the expensive reflection read,
-- every pass: the bulk of the 7-27ms GT chunks. Cleared on course
-- load/unload so it cannot alias across worlds. cacheMiss= in the pass
-- line is the health counter: if it tracks scanned pass after pass, the
-- key is unstable and the cache never hits.
local meshVerdict = {}
-- 60 (raised from 25, 2026-07-30): at 25 the list truncated before it
-- could show whether a newly added pattern had matched anything.
local MATCHED_NAME_CAP = 60
local matchedNamesLogged = 0
-- Dedupe by short name (2026-08-09): the address-keyed cache does not
-- dedupe same-named meshes (56 SMobj_pylon_a lines in one PA pass), so
-- the cap counts unique names. Cleared with the cache.
local matchedNamesSeen = {}

--- Order matters for cost (2026-07-29 telemetry: gt_ms_maxchunk stayed
--- ~20 ms after the sweep left the GT, so per-component work at ~15-20 us
--- each was the expense). GetCollisionEnabled is a UFunction call
--- (ProcessEvent marshalling); the asset verdict is a property read plus
--- a cached lookup, so the verdict runs first and the UFunction only for
--- components whose mesh matches. The en==0 gate remains a safety
--- property (never touch a body the game already enabled), consulted
--- later.
local function processCompGT(st, c)
    if not validRef(c) then return end
    st.scannedN = st.scannedN + 1
    local sm = nil
    pcall(function() sm = c.StaticMesh end)
    if not sm then return end
    -- GetAddress key (2026-08-10, see meshVerdict); the tostring fallback
    -- only covers a failed address read.
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
        -- Name the accepted assets, deduped by short name and capped: the
        -- patterns are substring matches, so an unintended asset with
        -- "tnl" in its path would otherwise hide inside the counts.
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

    -- Sun-leak fix (Config.RainCollision.FixShadowLeak). Diagnosis
    -- 2026-07-29: these decks ship CastShadow=true but
    -- bCastShadowAsTwoSided=false, so the shadow depth pass culls their
    -- backfaces from the sun's side and sunlight lands inside the tunnel
    -- (the same one-sided geometry that makes rain traces need an upward
    -- leg). bCastShadowAsTwoSided has no setter on this cook and UE
    -- snapshots it into the scene proxy at render-state creation, so a
    -- bare write is a silent no-op; SetCastShadow dirties render state
    -- but early-outs on an unchanged value, hence the false->true toggle.
    -- Outside the en==0 gate on purpose: a leaking deck usually already
    -- has collision. Idempotent via the twoSided read. Keys on the broad
    -- shadow verdict; the collision block keys on the narrow coll verdict
    -- (one list until 2026-08-04, when the kerb-hunt pattern expansion
    -- widened the stealth-body set to every wall/kerb/sidewalk and
    -- re-created the v7/v8 AI breakage). No live A/B toggle: a revert
    -- keyed on tostring(component) is unstable across passes and falsely
    -- exonerated the fix; A/B by course reload.
    if verdict.shadow and FIX_SHADOW_LEAK then
        local twoSided = nil
        pcall(function() twoSided = c.bCastShadowAsTwoSided end)
        if twoSided == false then
            -- Casters this flip turns on (shipped CastShadow=false, e.g.
            -- every BUIL building) never reach the force block below, so
            -- count them here too or castForced= undercounts the buildings.
            if FORCE_CAST_SHADOW then
                local preCast = nil
                pcall(function() preCast = c.CastShadow end)
                if preCast == false then
                    st.castForcedN = (st.castForcedN or 0) + 1
                end
            end
            pcall(function() c.bCastShadowAsTwoSided = true end)
            -- Force the proxy rebuild that makes the flag take effect
            pcall(function() c:SetCastShadow(false) end)
            pcall(function() c:SetCastShadow(true) end)
            st.shadowN = (st.shadowN or 0) + 1
        end
        -- Force-cast test (Config.RainCollision.ForceCastShadow,
        -- 2026-08-12): a mesh shipping CastShadow=false passes every sun
        -- ray whatever its two-sided flag (the ginza-ramp leak candidates
        -- include that case), so any shadow-roster mesh with
        -- CastShadow=false gets it forced true (castForced=; A/B by
        -- course reload).
        if FORCE_CAST_SHADOW then
            local casting = nil
            pcall(function() casting = c.CastShadow end)
            if casting == false then
                pcall(function() c:SetCastShadow(true) end)
                st.castForcedN = (st.castForcedN or 0) + 1
            end
        end
    end

    -- Matching collision mesh (narrow v9 set only): only now pay for the
    -- UFunction. en ~= 0 means the game already gave this body collision,
    -- so leave it alone.
    if not verdict.coll then return end
    local en = nil
    pcall(function() en = c:GetCollisionEnabled() end)
    if en ~= 0 then
        -- AI-residual forensics (2026-08-07, parked risk (c)): a
        -- stock-enabled instance of a target asset. The shared BodySetup
        -- CollisionTraceFlag=3 write reaches it too, so AI queries against
        -- it return trimesh hits instead of simple-hull hits; a nonzero
        -- count in the pass log means risk (c) is live geometry. The
        -- ObjectType filter (2026-08-09) excludes our own targets, which
        -- carry 25 (without it the counter re-counted them on every later
        -- pass: enable 43, next pass 43). Cost: one UFunction read per
        -- already-enabled target (~4 ms worst case, spread across
        -- chunks). A failed read (ot=nil) counts as stock, never toward
        -- hiding a live risk.
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
            elseif CTF_WRITE then
                bs.CollisionTraceFlag = 3
            else
                -- CtfWrite=false: no write, so this body rains through and
                -- the counter names the gap the pak failed to cover.
                st.ctfMissN = (st.ctfMissN or 0) + 1
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

--- Async side of the pass: fetch the next class array when the walker
--- needs one (FindAllOf is a ~30 ms object-array walk, work that belongs
--- off the game thread). Teardown must be gated before calling this, as
--- for any async sweep (the wet_grip lesson: an ungated sweep runs
--- against a dying world).
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

--- Game-thread side: process up to CHUNK components from the array the
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
    -- Count ceiling plus a time budget: the first chunks of a load pass
    -- (cold verdict cache, one GetFullName per unique mesh) ran 28-34 ms on
    -- the 08-31 logs, later passes 2-6 ms
    while budget > 0 and (os.clock() - t0) < CHUNK_BUDGET_S do
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
--- telemetry line. gt_ms_total is the sum of per-frame GT time across
--- all chunks (each individual chunk stays well under a frame).
finishWorldPassGT = function(st)
    -- Shape-class neutralization, private channels only (>= 22, outside
    -- the game-defined 0..21 band; on a game channel like Visibility
    -- these writes would alter real game behavior): query-enabled
    -- Brush/Box/Sphere/Capsule bodies (PP volumes, triggers, section
    -- envelopes, AI sight spheres) are sensors, not geometry, so their
    -- private-channel response goes to Ignore (idempotent; small enough
    -- to run inline at pass end).
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
        or (st.shadowN or 0) > 0 or (st.castForcedN or 0) > 0 or DEBUG then
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
            -- stockEnabledTargets > 0 = the shared ctf=3 write reaches
            -- stock-enabled target instances (risk (c), see processCompGT);
            -- pos lets an "AI bugged here" field report be matched against
            -- pass activity near that spot.
            stockEnabledTargets = st.collStockN or 0,
            -- CtfWrite=false rehearsal only: enabled targets whose
            -- BodySetup had no baked CTF (0 everywhere = pak complete)
            ctfMissing = st.ctfMissN or 0,
            -- ForceCastShadow test only: shadow-roster meshes that
            -- shipped CastShadow=false and got it forced on
            castForced = st.castForcedN or 0,
            -- cacheMiss: fresh meshVerdict computes this pass (see the
            -- note at meshVerdict)
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
        if cfg.CtfWrite ~= nil then CTF_WRITE = cfg.CtfWrite end
        if cfg.PlayerCarProbe ~= nil then PLAYER_CAR_PROBE = cfg.PlayerCarProbe end
        if cfg.PlayerCarBody ~= nil then PLAYER_CAR_BODY = cfg.PlayerCarBody end
        if cfg.ForceCastShadow ~= nil then FORCE_CAST_SHADOW = cfg.ForceCastShadow end
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
        ctfWrite = tostring(CTF_WRITE),
        playerCarBody = tostring(PLAYER_CAR_BODY),
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
    probeDonePawns = {}     -- pawn addresses are world-local
    carSweepLast, carSweepInterval = 0.0, CAR_SWEEP_FIRST_S
    panelDonePawns = {}
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
    probeDonePawns = {}
    panelDonePawns = {}
    carSweepLast, carSweepInterval = 0.0, CAR_SWEEP_FIRST_S
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

-- Cover-enter trigger cooldown: the roof trace flaps through girder
-- gaps, so rising edges can arrive every poll on lattice bridges. One
-- pass per window is plenty (the pass covers the whole world anyway).
local COVER_TRIGGER_COOLDOWN_S = 8.0
local lastCoverTrigger = nil

--- Cover began (tunnels.lua, road-data bit or roof trace rising edge).
--- The five 2026-08-11 Alt+N reports were all rain under a cover whose
--- deck the pass had not reached (streamed-in cells wait for the periodic
--- cadence, up to REAPPLY_S late on a first approach); a pass requested
--- at cover entry closes that window where an un-flipped deck is visible.
function RainCollision.OnCoverEnter()
    if not (enabled and armed) then return end
    if not isWet() then return end
    local now = os.clock()
    if lastCoverTrigger and (now - lastCoverTrigger) < COVER_TRIGGER_COOLDOWN_S then
        return
    end
    lastCoverTrigger = now
    if passState == nil and not passPending then
        passPending = true
        passTrigger = "cover-enter"
    end
end

--- Per-tick entry (8 Hz from main); self-paced. Enforcement (and the
--- private-channel fan) run every ENFORCE_S; while a chunked pass is
--- active, every tick dispatches one chunk so the pass finishes in a few
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

    -- The world pass runs while wet (a pending request from course load
    -- or rain start starts at the next enforce tick; the periodic re-pass
    -- covers streamed-in cells after that; a request raised while dry
    -- waits for the flip to rain) or while the shadow-leak fix is on: the
    -- sun leak happens in dry, sunny weather, and gating it behind the
    -- rain check meant it never ran when it mattered (field 2026-07-29
    -- 18:00, Clear_Skies session: zero passes). Never start while a pass
    -- is already walking (a restart every enforce tick would starve it).
    local wet, wantStart = false, false
    if doEnforce then
        wet = isWet()
        if (wet or FIX_SHADOW_LEAK) and passState == nil then
            if passPending then
                wantStart = true
            elseif lastPass == nil or (now - lastPass) >= REAPPLY_S then
                -- Distance gate: cells only stream in when the car moves,
                -- so a periodic re-pass after sitting still finds nothing.
                -- Skip it and re-arm the cadence unless the car travelled
                -- far enough for new cells; triggered passes (load, rain
                -- start) always run.
                if movedSincePass() then
                    wantStart = true
                    passTrigger = "periodic"
                else
                    lastPass = now
                end
            end
        end
    end

    -- Async: the component array is fetched here, never on the game thread
    -- (the ~30 ms FindAllOf); safe because the teardown gate above passed.
    if wantStart and passState == nil then
        startWorldPass(passTrigger)
        markPassOrigin()
        passPending = false
    end
    if passState ~= nil then passFetchAsync() end

    -- Car position (async, from tunnels) and the car-sweep component array
    -- (fetched here, consumed by the game-thread closure below), so the
    -- game thread walks the object array for neither
    local carComps = nil
    if doEnforce then
        updateCarPosAsync()
        if (PLAYER_CAR_BODY or PLAYER_CAR_PROBE) and (now - carSweepLast) >= carSweepInterval then
            carSweepLast = now
            pcall(function() carComps = FindAllOf("StaticMeshComponent") end)
        end
    end

    if ExecuteInGameThread then
        pcall(function()
            GT.Run(function()
                if doEnforce then
                    enforceChannelGT()
                    if carComps then
                        playerCarGT(carComps)
                    end
                    -- The fan mutates responses on game bodies: private
                    -- channels only
                    if wet and CHANNEL >= 22 then containmentFanGT() end
                end
                if passState ~= nil then passChunkGT() end
            end)
        end)
    end
    return true
end

return RainCollision
