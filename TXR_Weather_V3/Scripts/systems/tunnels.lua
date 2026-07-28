-- TXR Weather Mod v3.0
-- systems/tunnels.lua
-- Covered-road handling. Two signals feed one "covered" state:
--   1. Road data (primary): the pawn's tunnel_attribute
--      (ERPDTunnelBitAttribute: Left=1, Right=2, Up=4); the Up bit = roofed
--      road, exact dev-authored boundaries, all real bores.
--   2. Roof trace: lone overpasses are not marked in the road data, so a
--      Visibility trace covers them (downward for deck tops, upward for
--      linings; TXR road meshes are one-sided for queries).
-- Covered = precipitation components HIDDEN via Weather.SetPrecipSuppressed
-- (they keep simulating; restore = unhide, instant). Trace-sourced cover
-- releases with hysteresis so girder gaps don't strobe the rain.
-- Also clears the course volumes' authored LumenSkylightLeaking override
-- once per course (it flooded covered sections with flat sky ambient at
-- every volume edge). NO exposure writes here: per-volume exposure is a
-- closed dead end (blend-edge snapping), and stock exposure handles bores
-- correctly with the leak dead.

local Tunnels = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")
local Config = require("config")

-- Lazy-loaded to avoid circular dependencies
local Actors = nil
local Weather = nil
local PresetsMod = nil
local UEHelpers = nil

local MODULE = "Tunnels"

-- ============== CONFIG-DERIVED (filled in Init, with safe fallbacks) ==============
local enabled = true
local TUNNEL_RAIN_KILL = true
local TUNNEL_LOOKAHEAD_S = 1.2   -- rain-kill lookahead seconds
local KILL_SKY_LEAK = true       -- clear the volumes' authored
                                 -- LumenSkylightLeaking override (see header)
local OVERPASS_KILL = true
local OVERPASS_TRACE_LEN = 5000.0 -- cm of headroom checked (50 m)
local RAIN_CLEAR_POLLS = 4       -- uncovered polls before the kill releases
local POLL_RAIN_S = 0.25         -- poll cadence while precipitation can fall
local POLL_DRY_S = 1.0           -- poll cadence when dry

-- ============== STATE ==============
local isInitialized = false
local featuresActive = false     -- computed in Init: any feature on
local armed = false              -- course gate (set by main via OnCourseLoad)
local ppArmed = false            -- per-course one-shot latch (leak kill ran)
local ppNextPoll = 0.0
local tunnelNow = false          -- car inside a covered volume
local rainZoneNow = false        -- car/lookahead/roof covered (drives the kill)
local rainClearCount = 0
local roofNow = false            -- roof signal from the last poll
local coverWasRoad = false       -- last covered poll included the road-data bit
local roofProbeLogged = false    -- one-shot per course: proves the trace call works
local hitShapeLogged = false     -- one-shot per session: FHitResult shape dump
local lastPX, lastPY, lastPZ, lastPollClock = nil, nil, nil, nil
local lastTunnelAttr = nil       -- pawn road-data tunnel attribute (logged on change)

-- ============== INTERNAL: lazy refs ==============

local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

local function getWeather()
    if not Weather then
        local ok, mod = pcall(require, "systems.weather")
        if ok then Weather = mod end
    end
    return Weather
end

-- Presets, lazy-required for the poll cadence (is the current preset wet?);
-- pure data module, no require cycles.
local function getPresets()
    if not PresetsMod then
        local ok, mod = pcall(require, "systems.presets")
        if ok then PresetsMod = mod end
    end
    return PresetsMod
end

local function getUEHelpers()
    if not UEHelpers then
        pcall(function() UEHelpers = require("UEHelpers") end)
    end
    return UEHelpers
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

-- ============== INTERNAL: state machine ==============

--- Pure-state reset (refs dropped: unload/teardown/re-arm). NO weather
--- calls, safe from any thread; the next Weather.Apply clears any lingering
--- suppression itself (full restore path, see weather.lua).
local function tunnelReset()
    tunnelNow, rainZoneNow = false, false
    lastPX, lastPY, lastPZ, lastPollClock = nil, nil, nil, nil
    roofNow, rainClearCount, coverWasRoad = false, 0, false
    lastTunnelAttr = nil
end

--- Apply the covered state computed by the poll (game thread). The rain
--- kill accepts the road-data cover (carIn) and the roof trace (rainAhead,
--- which includes the lookahead point) so the kill lands at the portal or
--- bridge edge.
local function tunnelApplyState(carIn, rainAhead)
    if carIn ~= tunnelNow then
        tunnelNow = carIn
        Log.Info(MODULE, tunnelNow and "Tunnel cover ON (road data)" or "Tunnel cover OFF")
        -- Fog damp rides the road-data cover only (bores; brief overpass
        -- shadows don't need it). EnhancedFog owns the fog writes.
        pcall(function()
            local ok, EF = pcall(require, "systems.enhanced_fog")
            if ok and EF and EF.SetCoveredDamp then EF.SetCoveredDamp(tunnelNow) end
        end)
    end
    -- Kill instantly on cover. Release depends on which signal covered
    -- last: the road-data bit is exact, so its cover releases on the FIRST
    -- uncovered poll (rain returns right at the portal); the roof TRACE
    -- flaps through girder/lattice gaps, so its cover holds for
    -- RAIN_CLEAR_POLLS uncovered polls before releasing.
    local covered = (TUNNEL_RAIN_KILL and (carIn or rainAhead)) or false
    local wantKill = rainZoneNow
    if covered then
        rainClearCount = 0
        wantKill = true
        coverWasRoad = carIn
    elseif rainZoneNow then
        rainClearCount = rainClearCount + 1
        if rainClearCount >= (coverWasRoad and 1 or RAIN_CLEAR_POLLS) then
            rainClearCount = 0
            wantKill = false
        end
    end
    if wantKill ~= rainZoneNow then
        rainZoneNow = wantKill
        pcall(function()
            local W = getWeather()
            if W and W.SetPrecipSuppressed then W.SetPrecipSuppressed(wantKill) end
        end)
    elseif wantKill then
        -- A weather change mid-tunnel (Weather.Apply) clears the suppression
        -- without telling us; re-assert whenever the actual state disagrees,
        -- so rain can't run inside a tunnel until the next ENTER.
        pcall(function()
            local W = getWeather()
            if W and W.IsPrecipSuppressed and not W.IsPrecipSuppressed() then
                W.SetPrecipSuppressed(true)
            end
        end)
    end
end

-- ============== INTERNAL: roof probe ==============

-- Shared out-hit interpretation: the bool ReturnValue is the primary result;
-- OutHit is a table-fill out-param probed only as a fallback shape.
local TRACE_COLOR = { R = 0.0, G = 0.0, B = 0.0, A = 1.0 }
local function traceResult(r, outHit)
    if r == true then return true end
    local b = nil
    pcall(function() b = outHit.bBlockingHit end)
    if b == nil then
        pcall(function() b = outHit.OutHit and outHit.OutHit.bBlockingHit end)
    end
    return (b == true)
end

--- Short display name from a hit reference. The 00:06 shape dump showed
--- FHitResult.Component as a weak-ptr-style userdata (direct GetFullName
--- fails; deref via :Get() first) and HitObjectHandle as a table with an
--- Actor reference of the same kind.
local function nameFromRef(ref)
    if ref == nil then return nil end
    local fn = nil
    pcall(function() fn = ref:GetFullName() end)
    if type(fn) ~= "string" or #fn == 0 then
        fn = nil
        pcall(function()
            local obj = ref:Get()   -- TWeakObjectPtr deref
            if obj then fn = obj:GetFullName() end
        end)
    end
    if type(fn) == "string" and #fn > 0 then
        return fn:match("([^%.:%s]+%.[^%.:%s]+)$") or fn:sub(-48)
    end
    return nil
end

--- Channel trace over an explicit segment (game thread), with hit distance
--- + hit name extracted from the out struct for diagnosis.
--- @param channel number ETraceTypeQuery index (0=Visibility, 1=Camera)
--- @param complex boolean|nil true = per-triangle (complex) collision query;
---        default false = simple collision (what UDW particle traces use)
--- @return boolean hit, boolean callOk, number|nil dist, string|nil hitName, userdata|nil compRef
local function traceChanSegGT(ksl, pawn, s, e, channel, complex)
    local hit, callOk, dist, hitName, compRef = false, false, nil, nil, nil
    local ok = pcall(function()
        local outHit = {}
        local r = ksl:LineTraceSingle(pawn, s, e, channel,
            complex == true, {}, 0, outHit, true, TRACE_COLOR, TRACE_COLOR, 0.0)
        callOk = true
        hit = traceResult(r, outHit)
        if hit then
            local h = outHit
            pcall(function() if h.OutHit then h = h.OutHit end end)
            pcall(function() dist = tonumber(h.Distance) end)
            pcall(function() compRef = h.Component end)
            pcall(function() hitName = nameFromRef(h.Component) end)
            if hitName == nil then
                pcall(function()
                    local hh = h.HitObjectHandle
                    if hh then hitName = nameFromRef(hh.Actor) end
                end)
            end
            -- One-shot struct-shape dump if the name still won't resolve
            -- (fires at most once per session; silent once extraction works)
            if hitName == nil and not hitShapeLogged then
                hitShapeLogged = true
                local keys = {}
                pcall(function()
                    for k, v in pairs(h) do
                        keys[#keys + 1] = tostring(k) .. "=" .. type(v)
                    end
                end)
                Log.Info(MODULE, "Hit shape debug", {
                    outType = type(h),
                    keys = (#keys > 0) and table.concat(keys, " ") or "NONE",
                })
            end
        end
    end)
    return hit, (ok and callOk), dist, hitName, compRef
end

--- Full collision profile of a hit component (game thread): enabled mode,
--- object type, response row for channels 0..15 (0=Ignore 1=Overlap
--- 2=Block), and the static-mesh asset name. This is the "what makes this
--- mesh different" readout (2026-07-28 field question: some geometry
--- carries wheels/rain, some does not).
local function describeCollisionGT(ref)
    local comp = nil
    pcall(function()
        if ref and ref.Get then comp = ref:Get() else comp = ref end
    end)
    if not comp then return "unresolvable" end
    local parts = {}
    pcall(function() parts[#parts + 1] = "en=" .. tostring(comp:GetCollisionEnabled()) end)
    pcall(function() parts[#parts + 1] = "obj=" .. tostring(comp:GetCollisionObjectType()) end)
    local resp = {}
    for ch = 0, 31 do
        local r = "?"
        pcall(function() r = tostring(comp:GetCollisionResponseToChannel(ch)) end)
        resp[#resp + 1] = r
    end
    parts[#parts + 1] = "resp0-31=" .. table.concat(resp, "")
    pcall(function()
        local sm = comp.StaticMesh
        if sm then
            local fn = sm:GetFullName()
            if type(fn) == "string" then
                parts[#parts + 1] = "mesh=" .. (fn:match("([^%.%s/]+)$") or fn:sub(-40))
            end
            -- Live BodySetup trace flag: 2 = ComplexAsSimple = our pak's
            -- patch LOADED; 0 = UseDefault = the base asset won (pak not
            -- mounting or not overriding). The decisive pak diagnostic.
            pcall(function()
                local bs = sm.BodySetup
                if bs then parts[#parts + 1] = "ctf=" .. tostring(bs.CollisionTraceFlag) end
            end)
        end
    end)
    return table.concat(parts, " ")
end

--- Roof signal v4 (2026-07-12). Two Visibility legs, both consequences of
--- TXR's one-sided query meshes (established over the 07-11 diagnosis
--- drives: no object channel carries the decks, g8 = a section-envelope
--- volume, roads block Visibility only on their front faces):
--- 1. DOWNWARD from OVERPASS_TRACE_LEN above the car to just above it:
---    overpass deck TOPS are front faces; the car's own road is below the
---    segment and cannot false-positive.
--- 2. UPWARD fallback for tunnel interiors: inside a bore the downward
---    start sits inside the hill/structure and exits the lining's BACKface
---    (no hit), while the lining's interior surface front-faces an upward
---    ray. Overpass undersides are backfaces for it, so the legs don't
---    overlap ("short tunnels still rain" field report, 2026-07-12).
--- @return boolean hit, boolean callOk, number|nil dist, string|nil hitName, string|nil leg
local function roofProbeGT(ksl, pawn, x, y, z)
    local sD = { X = x, Y = y, Z = z + 250.0 + OVERPASS_TRACE_LEN }
    local eD = { X = x, Y = y, Z = z + 250.0 }
    local hit, ok, dist, name = traceChanSegGT(ksl, pawn, sD, eD, 0)
    if hit then return hit, ok, dist, name, "down" end
    local hit2, ok2, dist2, name2 = traceChanSegGT(ksl, pawn, eD, sD, 0)
    if hit2 then return hit2, (ok or ok2), dist2, name2, "up" end
    return false, (ok or ok2), nil, nil, nil
end

-- ============== INTERNAL: rain blocker (game thread) ==============
-- The occlusion solution (2026-07-28, mechanism field-proven; dig verdict:
-- reference\udwdig\OCCLUSION_FINDINGS.md): no trace channel sees TXR roof
-- geometry from below, so UDW's native per-particle rain occlusion gets
-- collision WE provide: ONE invisible slab following the car while the
-- road data says covered. UDW spawns all rain particles within 2000 uu of
-- the camera, so a single 240 m slab covers the whole game; the particle
-- ceiling/fall traces hit it (ECC_Visibility) and rain dies under cover.
-- A native TriggerBox is used (runtime-spawned brush Volumes have no brush
-- model = no collision); QueryOnly + ignore-all + Block Visibility only,
-- and it exists ONLY while covered, so side-effect surface is minimal.

local RB_ENABLED = true
local RB_Z_OFFSET = 1500.0
local RB_HALF_XY = 12000.0
local RB_HALF_Z = 200.0
local RB_HOLD_S = 2.0
local rbActor = nil
local rbHoldUntil = nil
local rbLogged = false
-- Reset debounce (2026-07-28 01:21 log lesson: gantry-sliver attr flickers
-- fired the global rain-paths reset three times in 20 s = visible rain
-- popping, "the old rain kill feel"). A reset only fires when the cover is
-- not a flicker re-entry and not within the rate limit.
local rbLastOff = 0.0
local rbLastReset = 0.0

-- Auto-census (2026-07-28, user ask): run the read-only ceiling census on
-- every bore ENTRY automatically (rate-limited) so lining-identification
-- data accumulates from normal driving, no keypress. Config
-- Tunnels.AutoCensus; the collision FLIP stays manual (Alt+Shift+I).
local AUTO_CENSUS = true
local autoCensusLast = 0.0
local prevAttrCovered = false

--- Spawn one collision slab above (x, y, z). Game thread only.
--- @return userdata|nil the spawned actor
local function spawnSlabGT(x, y, z)
    local world = nil
    pcall(function()
        local UEH = getUEHelpers()
        world = UEH and UEH.GetWorld and UEH.GetWorld()
    end)
    local cls = nil
    pcall(function() cls = StaticFindObject("/Script/Engine.TriggerBox") end)
    if not world or not (cls and cls.IsValid and cls:IsValid()) then
        Log.Warn(MODULE, "Slab spawn: world/class unavailable")
        return nil
    end
    local spawned = nil
    pcall(function()
        spawned = world:SpawnActor(cls,
            {X = x, Y = y, Z = z + RB_Z_OFFSET}, {Pitch = 0, Yaw = 0, Roll = 0})
    end)
    if not (spawned and spawned.IsValid and spawned:IsValid()) then
        Log.Warn(MODULE, "Slab spawn: SpawnActor failed")
        return nil
    end
    pcall(function()
        local shape = spawned.CollisionComponent
        if shape then
            pcall(function() shape:SetBoxExtent({X = RB_HALF_XY, Y = RB_HALF_XY, Z = RB_HALF_Z}, false) end)
            pcall(function() shape:SetCollisionEnabled(1) end)               -- QueryOnly
            pcall(function() shape:SetCollisionResponseToAllChannels(0) end) -- ECR_Ignore
            pcall(function() shape:SetCollisionResponseToChannel(3, 2) end)  -- ECC_Visibility = ECR_Block
        end
    end)
    return spawned
end

--- Per-poll blocker state machine (game thread; called from ppPollGT).
--- Covered: ensure the slab exists and rides above the car. Uncovered:
--- hold HoldS (smooths attr flicker/girder gaps), then destroy.
local function blockerPollGT(covered, x, y, z, now)
    if not RB_ENABLED then return end
    if covered then
        rbHoldUntil = nil
        if rbActor ~= nil and validRef(rbActor) then
            pcall(function()
                rbActor:K2_SetActorLocation(
                    {X = x, Y = y, Z = z + RB_Z_OFFSET}, false, {}, true)
            end)
        else
            rbActor = spawnSlabGT(x, y, z)
            if rbActor and not rbLogged then
                rbLogged = true
                Log.Info(MODULE, "Rain blocker live (first spawn this course)")
            end
            if rbActor then
                Log.Info(MODULE, "Rain blocker ON (covered)")
                -- DELAY FIX (01:06 probe verdict, 2026-07-28): UDW reuses
                -- particle paths for seconds, so rain kept falling into
                -- portals. "Static Properties - Rain" is the bytecode-proven
                -- native re-bake (SetAsset with reset + param re-push): stale
                -- paths drop and fresh particles respect the slab at once.
                -- DEBOUNCED: skipped on flicker re-covers (<2.5 s since the
                -- last OFF, gantry slivers) and rate-limited to one reset
                -- per 8 s; the slab itself still works either way, only the
                -- latency mitigation is skipped.
                local flicker = (now - rbLastOff) < 2.5
                local limited = (now - rbLastReset) < 8.0
                if not flicker and not limited then
                    rbLastReset = now
                    pcall(function()
                        local actors = getActors()
                        local udw = actors and actors.GetUDW and actors.GetUDW()
                        if udw and udw.IsValid and udw:IsValid() then
                            local fn = udw["Static Properties - Rain"]
                            if fn then
                                fn(udw)
                                Log.Info(MODULE, "Rain paths reset (portal entry)")
                            end
                        end
                    end)
                end
            end
        end
    elseif rbActor ~= nil then
        rbHoldUntil = rbHoldUntil or (now + RB_HOLD_S)
        if now >= rbHoldUntil then
            pcall(function()
                if validRef(rbActor) then rbActor:K2_DestroyActor() end
            end)
            rbActor = nil
            rbHoldUntil = nil
            rbLastOff = now
            Log.Info(MODULE, "Rain blocker OFF (cover ended)")
        end
    end
end

-- ============== INTERNAL: containment poll (game thread) ==============

local function ppPollGT()
    local actors = getActors()
    if actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
        ppArmed = false
        tunnelReset()
        return
    end

    if not ppArmed then
        ppArmed = true
        tunnelReset()
        -- SKYLIGHT LEAK KILL (see header): clear the authored
        -- LumenSkylightLeaking override on EVERY course volume (all 33
        -- carry it), so no volume boundary changes the world's GI anymore.
        -- Idempotent; volumes spawn fresh per course.
        local volumes, leakCleared = 0, 0
        pcall(function()
            local vols = FindAllOf("PostProcessVolume")
            if not vols then return end
            for _, v in ipairs(vols) do
                volumes = volumes + 1
                if KILL_SKY_LEAK then
                    pcall(function()
                        local s = v.Settings
                        if s.bOverride_LumenSkylightLeaking == true then
                            s.bOverride_LumenSkylightLeaking = false
                            leakCleared = leakCleared + 1
                        end
                    end)
                end
            end
            Log.Info(MODULE, "PP watcher armed", {
                volumes = volumes, leakCleared = leakCleared,
            })
        end)
        return
    end

    -- Pawn position: feeds the road-data read, the lookahead projection and
    -- the roof probe (which needs the pawn as trace WorldContextObject).
    local px, py, pz = nil, nil, nil
    local pawnObj = nil
    pcall(function()
        local UEH = getUEHelpers()
        local pc = UEH and UEH.GetPlayerController and UEH.GetPlayerController()
        local pawn = pc and pc.Pawn
        if pawn and pawn.IsValid and pawn:IsValid() then
            local loc = pawn:K2_GetActorLocation()
            if loc then
                px, py, pz = loc.X, loc.Y, loc.Z
                pawnObj = pawn
            end
        end
    end)
    if px == nil then return end

    -- COVERED SIGNAL #1 (primary since 2026-07-12): the game's own road
    -- data. Every BP_GameVehicle carries tunnel_attribute (native
    -- ERPDTunnelBitAttribute: TunnelLeft=1, TunnelRight=2, TunnelUp=4),
    -- maintained per road point by the game itself. The Up bit = roof over
    -- this exact stretch of road, with dev-authored boundaries. Field
    -- verdict (20:09 log): fires for real bores AND short covered segments
    -- (more precise than the volume AABBs, catches the weird-mesh bores the
    -- traces are blind to), but NOT for lone overpasses above open road,
    -- which is what the roof trace below remains for.
    local attrCovered = false
    pcall(function()
        local attr = pawnObj.tunnel_attribute
        if type(attr) == "number" then
            attrCovered = (math.floor(attr / 4) % 2) == 1
            if attr ~= lastTunnelAttr then
                Log.Info(MODULE, "Tunnel attr", {
                    from = tostring(lastTunnelAttr), to = attr,
                    roof_bit = tostring(attrCovered),
                })
                lastTunnelAttr = attr
            end
        end
    end)

    -- Roof-trace lookahead point: project the car ~TUNNEL_LOOKAHEAD_S ahead
    -- using the position delta between polls (no reflection dependency),
    -- clamped to 120 m so a course-restart teleport can't produce a wild
    -- point. Only needed while still uncovered (attrCovered already
    -- suppresses; the attribute itself has no lookahead, the trace at the
    -- projected point is what pre-arms the kill before portals and decks).
    local nowC = os.clock()
    local lx, ly = nil, nil
    if TUNNEL_RAIN_KILL and not attrCovered then
        lx, ly = px, py
        if lastPX and lastPollClock and nowC > lastPollClock then
            local sc = TUNNEL_LOOKAHEAD_S / (nowC - lastPollClock)
            local dx, dy, dz = (px - lastPX) * sc, (py - lastPY) * sc, (pz - lastPZ) * sc
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d > 12000.0 then
                local k = 12000.0 / d
                dx, dy = dx * k, dy * k
            end
            lx, ly = px + dx, py + dy
        end
    end
    lastPX, lastPY, lastPZ, lastPollClock = px, py, pz, nowC

    -- COVERED SIGNAL #2, the roof trace: lone overpasses above open road are
    -- NOT marked in the road data, so a Visibility trace at the car (and at
    -- the lookahead point) supplies the second signal. Skipped while the
    -- road data already says covered; the rain-kill release hysteresis in
    -- tunnelApplyState smooths girder gaps.
    if OVERPASS_KILL and TUNNEL_RAIN_KILL and not attrCovered then
        local ksl = getKslRef()
        local roofSeen, callOk = false, false
        if ksl and pawnObj then
            roofSeen, callOk = roofProbeGT(ksl, pawnObj, px, py, pz)
            if not roofSeen and lx then
                -- Lookahead trace uses the CAR's Z, not the projected lz:
                -- over a crest / downhill the projection can dip below the
                -- road ahead, and an up-trace starting under the road hits
                -- it from below = false cover.
                local h, ok2 = roofProbeGT(ksl, pawnObj, lx, ly, pz)
                roofSeen = h
                callOk = callOk or ok2
            end
            if not roofProbeLogged then
                roofProbeLogged = true
                Log.Info(MODULE, "Roof probe live", {
                    hit = tostring(roofSeen), call_ok = tostring(callOk),
                    signal = "visDown",
                })
            end
        end
        if roofSeen ~= roofNow then
            roofNow = roofSeen
            Log.Info(MODULE, roofSeen and "Roof cover ON" or "Roof cover OFF")
        end
    elseif attrCovered and roofNow then
        -- Under road-data cover the roof signal is moot; drop it so the
        -- exit release starts clean from the attribute state alone.
        roofNow = false
    end

    -- Auto-census on the bore-entry edge (table indirection: CeilingCensus
    -- is defined below this function; read-only, rate-limited)
    if AUTO_CENSUS and attrCovered and not prevAttrCovered
        and (nowC - autoCensusLast) > 10.0 then
        autoCensusLast = nowC
        pcall(function()
            if Tunnels.CeilingCensus then Tunnels.CeilingCensus() end
        end)
    end
    prevAttrCovered = attrCovered

    -- Rain blocker rides the same covered verdict (roofNow stays relevant
    -- for a future overpass signal; it is inert while the trace is off),
    -- gated on precipitation being possible so the slab, and its
    -- Visibility-blocking side-effect surface, exists only when it earns
    -- its keep. A weather flip mid-bore is picked up on the next poll.
    local wet = false
    pcall(function()
        local p = State.GetCurrentPreset()
        if p then
            local pr = getPresets()
            if pr and pr.IsDry then wet = not pr.IsDry(p) end
        end
    end)
    blockerPollGT((attrCovered or roofNow) and wet, px, py, pz, nowC)

    tunnelApplyState(attrCovered, roofNow)
end

--- Async-side watcher trigger, entered at the full 8 Hz tick rate and
--- self-paced here: POLL_RAIN_S while precipitation can fall (or a kill is
--- currently held, so restores react just as fast), POLL_DRY_S otherwise.
--- Steady-state cost is pawn loc + one attribute read + 1-2 roof traces.
--- MUST be defined AFTER ppPollGT (local-ordering footgun: defined before
--- it, the name resolves to a nil global inside pcall and the watcher dies
--- silently).
local function ppWatchTick(now)
    if now < ppNextPoll then return end
    local fast = rainZoneNow or roofNow
    if not fast then
        pcall(function()
            local p = State.GetCurrentPreset()
            if p then
                local pr = getPresets()
                if pr and pr.IsDry then fast = not pr.IsDry(p) end
            end
        end)
    end
    ppNextPoll = now + (fast and POLL_RAIN_S or POLL_DRY_S)
    local actors = getActors()
    local suspended = actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended()
    if suspended then
        ppArmed = false
        -- Async side: tunnelReset is pure state (no weather calls); the
        -- next Weather.Apply clears any lingering suppression itself.
        tunnelReset()
        -- Table indirection (locals live below this definition): drop the
        -- slab/blocker refs, the dying world takes the actors with it
        if Tunnels.DropOcclusionVolumeRef then Tunnels.DropOcclusionVolumeRef() end
    elseif ExecuteInGameThread then
        pcall(function() ExecuteInGameThread(ppPollGT) end)
    end
end

-- ============== PUBLIC API ==============

function Tunnels.Init()
    if isInitialized then return true end

    local cfg = Config.Tunnels
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.TunnelRainKill ~= nil then TUNNEL_RAIN_KILL = cfg.TunnelRainKill end
        if cfg.TunnelRainLookahead ~= nil then TUNNEL_LOOKAHEAD_S = cfg.TunnelRainLookahead end
        if cfg.KillVolumeSkylightLeak ~= nil then KILL_SKY_LEAK = cfg.KillVolumeSkylightLeak end
        if cfg.OverpassRainKill ~= nil then OVERPASS_KILL = cfg.OverpassRainKill end
        if cfg.OverpassTraceLength then OVERPASS_TRACE_LEN = cfg.OverpassTraceLength end
        if cfg.RainClearPolls then RAIN_CLEAR_POLLS = cfg.RainClearPolls end
        if cfg.PollSecondsRain then POLL_RAIN_S = cfg.PollSecondsRain end
        if cfg.PollSecondsDry then POLL_DRY_S = cfg.PollSecondsDry end
        if type(cfg.RainBlocker) == "table" then
            local rb = cfg.RainBlocker
            if rb.Enabled ~= nil then RB_ENABLED = rb.Enabled end
            if tonumber(rb.ZOffset) then RB_Z_OFFSET = tonumber(rb.ZOffset) end
            if tonumber(rb.HalfXY) then RB_HALF_XY = tonumber(rb.HalfXY) end
            if tonumber(rb.HalfZ) then RB_HALF_Z = tonumber(rb.HalfZ) end
            if tonumber(rb.HoldS) then RB_HOLD_S = tonumber(rb.HoldS) end
        end
        if cfg.AutoCensus ~= nil then AUTO_CENSUS = cfg.AutoCensus end
    end

    featuresActive = TUNNEL_RAIN_KILL
        or KILL_SKY_LEAK
        or RB_ENABLED

    isInitialized = true
    State.SetModuleStatus("tunnels", true)

    if not enabled then
        Log.Info(MODULE, "Tunnels module disabled in config")
        return true
    end

    Log.Info(MODULE, "Initializing tunnels module", {
        rainKill = TUNNEL_RAIN_KILL,
        overpass = OVERPASS_KILL,
        rainBlocker = RB_ENABLED,
    })
    return true
end

function Tunnels.OnCourseLoad()
    ppArmed = false         -- fresh course volumes: re-run the leak kill
    ppNextPoll = 0.0
    roofProbeLogged = false
    tunnelReset()           -- Weather.Apply on load clears any suppression
    armed = true
    -- Table indirection: the local lives below (local-ordering rule)
    if Tunnels.DropOcclusionVolumeRef then Tunnels.DropOcclusionVolumeRef() end
end

function Tunnels.OnCourseUnload()
    armed = false
    ppArmed = false
    tunnelReset()
    -- Never carry the test-volume actor ref across worlds (footgun rule);
    -- the dying world destroys the actor itself
    if Tunnels.DropOcclusionVolumeRef then Tunnels.DropOcclusionVolumeRef() end
end

--- Per-tick entry (8 Hz from main); self-paces inside ppWatchTick.
function Tunnels.Update()
    if not (enabled and armed and featuresActive) then return true end
    ppWatchTick(os.clock())
    return true
end

--- Car inside a covered volume right now (feeds light_cycle's Alt+D line).
function Tunnels.IsCovered()
    return tunnelNow
end

--- Rain currently suppressed by the covered-zone state.
function Tunnels.IsRainSuppressed()
    return rainZoneNow
end

--- Rain-spot datapoint (Alt+N): one line with everything the rain kill
--- knows at the car's current position, for pinning down spots where rain
--- presence looks wrong (missing on open road, falling under a roof, not
--- restarting after a bore). Tag "RainSpot" also lands the line in
--- Logs/tuning_feedback.log. Keybind handlers run on the game thread, so
--- the pawn read and the fresh roof trace are direct.
function Tunnels.NoteRainSpot()
    local px, py, pz = nil, nil, nil
    local pawnObj = nil
    pcall(function()
        local UEH = getUEHelpers()
        local pc = UEH and UEH.GetPlayerController and UEH.GetPlayerController()
        local pawn = pc and pc.Pawn
        if pawn and pawn.IsValid and pawn:IsValid() then
            local loc = pawn:K2_GetActorLocation()
            if loc then
                px, py, pz = loc.X, loc.Y, loc.Z
                pawnObj = pawn
            end
        end
    end)
    if px == nil then
        Log.Warn(MODULE, "Rain spot note: no pawn (not on course?)")
        return
    end

    local attr = nil
    pcall(function() attr = pawnObj.tunnel_attribute end)
    local roofBit = type(attr) == "number" and ((math.floor(attr / 4) % 2) == 1)

    -- Fresh probe at press time, with distance + hit name (the latched
    -- roofNow can lag a poll behind and hides WHAT the trace hit).
    local probe = "no-ksl"
    local ksl = getKslRef()
    if ksl then
        local h, okc, dist, hitName, leg = roofProbeGT(ksl, pawnObj, px, py, pz)
        if h then
            probe = string.format("HIT(%s)@%scm:%s", leg or "?",
                dist and string.format("%.0f", dist) or "?", hitName or "?")
        elseif okc then
            probe = "miss"
        else
            probe = "ERR"
        end
    end

    local preset = "unknown"
    pcall(function() preset = State.GetCurrentPreset() or "none" end)

    Log.Info("RainSpot", "SPOT", {
        pos = string.format("%.0f,%.0f,%.0f", px, py, pz),
        attr = tostring(attr),
        roof_bit = tostring(roofBit),
        roof_probe = probe,
        roof_latched = tostring(roofNow),
        kill_active = tostring(rainZoneNow),
        cover_src = rainZoneNow and (coverWasRoad and "road-data" or "trace") or "none",
        weather = preset,
    })
end

--- Alt+O diagnostic (2026-07-27, UDW occlusion dig fix ladder, steps 0+1;
--- full context: reference\udwdig\OCCLUSION_FINDINGS.md). One press logs:
--- (a) the LIVE UDW particle-collision properties (the placed course
---     instance may override the CDO; Mode 2 = collision off entirely),
--- (b) an upward 8000 uu trace sweep over ETraceTypeQuery bytes 0..15
---     from the car, stamped with the road-data covered state.
--- Run once on OPEN road and once INSIDE a tunnel; the pair identifies
--- which channel carries tunnel linings (tunnel HIT + open MISS) and
--- guards against the g8 section envelopes blocking everywhere. Keybind
--- handlers run on the game thread, so all reads/traces are direct.
function Tunnels.OcclusionProbe()
    -- (a) live UDW property reads (step 0 of the fix ladder)
    local udwVals = {}
    pcall(function()
        local actors = getActors()
        local udw = actors and actors.GetUDW and actors.GetUDW()
        if not (udw and udw.IsValid and udw:IsValid()) then
            udwVals.udw = "UNREADABLE"
            return
        end
        for _, p in ipairs({
            "Particle Collision Mode",
            "Weather Particle Collision Channel",
            "Ceiling Check Height",
            "Enable Rain Particles",
            "Spawn Box Height",
            "Max Spawn Distance",
        }) do
            local v = nil
            pcall(function() v = udw[p] end)
            udwVals[p:gsub("%s", "_")] = tostring(v)
        end
    end)
    Log.Info(MODULE, "OcclusionProbe UDW props", udwVals)

    -- (b) upward channel sweep from the car (step 1 probe)
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
    if not (ksl and pawnObj) then
        Log.Warn(MODULE, "OcclusionProbe: no ksl/pawn (run on a course)")
        return
    end
    local s = { X = px, Y = py, Z = pz + 250.0 }
    local e = { X = px, Y = py, Z = pz + 250.0 + 8000.0 }
    -- Both collision flavors per channel (2026-07-28): SIMPLE = what UDW
    -- particle traces query (docs 1369); COMPLEX = per-triangle, the flavor
    -- car physics/camera sweeps commonly use. The field contradiction
    -- (camera/car collide with linings, rain and the simple sweep pass
    -- through) is resolved if linings carry complex-only collision:
    -- expect chNc=HIT with chNs still MISS inside a bore if so.
    -- 0..23 (2026-07-28 user challenge "the camera DOES collide with the
    -- ceiling": the earlier 0..15 sweep missed trace-type indices 16-23,
    -- and TXR provably uses high custom channels: GTC4/5 object types on
    -- the collision shells. A ceiling body responding only above 15 would
    -- have been invisible to every previous sweep.)
    local parts = {}
    local firstUpRef = nil
    for ch = 0, 23 do
        local hitS, okS, distS, nameS, refS = traceChanSegGT(ksl, pawnObj, s, e, ch, false)
        local hitC, okC, distC, nameC, refC = traceChanSegGT(ksl, pawnObj, s, e, ch, true)
        if not (okS and okC) then
            parts[#parts + 1] = string.format("ch%d=ERR", ch)
        else
            if hitS then
                parts[#parts + 1] = string.format("ch%ds=HIT(%s,%s)",
                    ch, distS and string.format("%.0f", distS) or "?", nameS or "?")
                firstUpRef = firstUpRef or refS
            end
            if hitC then
                parts[#parts + 1] = string.format("ch%dc=HIT(%s,%s)",
                    ch, distC and string.format("%.0f", distC) or "?", nameC or "?")
                firstUpRef = firstUpRef or refC
            end
        end
    end
    Log.Info(MODULE, "OcclusionProbe sweep", {
        covered = tostring(Tunnels.IsCovered()),
        z = string.format("%.0f", pz),
        hits = (#parts > 0) and table.concat(parts, " ")
            or "none (all 16 channels MISS, simple AND complex)",
    })
    if firstUpRef then
        Log.Info(MODULE, "OcclusionProbe ceiling profile",
            {info = describeCollisionGT(firstUpRef)})
    end

    -- ROAD REFERENCE: the mesh under the car is the one guaranteed
    -- collision-bearing surface (wheels ride it). Its full profile is the
    -- baseline to compare every other mesh against. Simple first, complex
    -- fallback (which one hits also discriminates the collision model).
    local sDown = { X = px, Y = py, Z = pz + 100.0 }
    local eDown = { X = px, Y = py, Z = pz - 500.0 }
    local hitD, okD, distD, nameD, refD = traceChanSegGT(ksl, pawnObj, sDown, eDown, 0, false)
    local flavor = "simple"
    if not hitD then
        hitD, okD, distD, nameD, refD = traceChanSegGT(ksl, pawnObj, sDown, eDown, 0, true)
        flavor = "complex"
    end
    Log.Info(MODULE, "OcclusionProbe road profile", {
        hit = tostring(hitD), flavor = flavor, name = nameD or "?",
        info = hitD and describeCollisionGT(refD) or "no road hit (!?)",
    })

    -- CAR profile (2026-07-28, user q "can we find the car's channel?"):
    -- the pawn root's object type + response row is the other half of the
    -- car-vs-world channel matrix (cross-reference with the road/wall rows)
    pcall(function()
        local root = pawnObj:K2_GetRootComponent()
        if root then
            Log.Info(MODULE, "OcclusionProbe car profile",
                {info = describeCollisionGT(root)})
        end
    end)

    -- Third leg (2026-07-28): OBJECT-space queries. Channel traces ask
    -- "does the body BLOCK trace channel N"; object queries ask "is the
    -- body's object TYPE in my list" and hit regardless of channel
    -- responses. Car physics and (possibly) the game camera live in this
    -- space: if linings answer here while every channel trace misses,
    -- the lining collision is real but channel-deaf (model B), and the
    -- lookahead portal detector can query by object type.
    local oparts = {}
    local objHits = {}
    for ot = 0, 20 do
        local hit, dist, name, oref = false, nil, nil, nil
        local okCall = pcall(function()
            local outHit = {}
            local r = ksl:LineTraceSingleForObjects(pawnObj, s, e, {ot},
                false, {}, 0, outHit, true, TRACE_COLOR, TRACE_COLOR, 0.0)
            hit = traceResult(r, outHit)
            if hit then
                local h = outHit
                pcall(function() if h.OutHit then h = h.OutHit end end)
                pcall(function() dist = tonumber(h.Distance) end)
                pcall(function() name = nameFromRef(h.Component) end)
                pcall(function() oref = h.Component end)
            end
        end)
        if not okCall then
            oparts[#oparts + 1] = string.format("ot%d=ERR", ot)
        elseif hit then
            oparts[#oparts + 1] = string.format("ot%d=HIT(%s,%s)",
                ot, dist and string.format("%.0f", dist) or "?", name or "?")
            if oref ~= nil and #objHits < 6 then
                objHits[#objHits + 1] = { ot = ot, ref = oref }
            end
        end
    end
    Log.Info(MODULE, "OcclusionProbe objects", {
        hits = (#oparts > 0) and table.concat(oparts, " ")
            or "none (object types 0..20 MISS)",
    })
    -- Full profiles for the object hits (2026-07-28 v8 no-rain triage:
    -- resp0-31 on containing bodies names whoever Blocks the private rain
    -- channel; dist-0 hits are the suspects)
    for _, oh in ipairs(objHits) do
        Log.Info(MODULE, "OcclusionProbe object profile", {
            ot = oh.ot, info = describeCollisionGT(oh.ref),
        })
    end
end

-- ============== OCCLUSION VOLUME EXPERIMENT (2026-07-28) ==============
-- Alt+U: spawn/destroy a "roof slab" blocker above the car. The 15-press
-- field sweep proved NO trace channel sees TXR roof geometry from below,
-- so native rain occlusion needs collision WE provide. A native TriggerBox
-- is used instead of UDS_Occlusion_Volume_C: runtime-spawned brush Volumes
-- have NO brush model = no collision (classic trap), while a TriggerBox's
-- BoxComponent is fully runtime-configurable. Collision = QueryOnly,
-- ignore all, BLOCK ECC_Visibility (3) = the channel BOTH the UDW particle
-- ceiling/fall traces and the player-occlusion fan query. Expected in
-- rain: rain dies under the slab (within particle path-reuse latency) and
-- native interior effects engage. Self-verifies by running the channel
-- sweep right after spawn (expect ch3=HIT(TriggerBox...)).
local _occlVolume = nil

--- Drop actor refs on world change (never touch a cross-world actor ref;
--- the world destroys the actors with itself). Covers both the manual
--- test slab and the auto rain blocker.
function Tunnels.DropOcclusionVolumeRef()
    _occlVolume = nil
    rbActor = nil
    rbHoldUntil = nil
    rbLogged = false
end

function Tunnels.OcclusionVolumeToggle()
    -- Destroy path
    if _occlVolume ~= nil then
        local destroyed = false
        pcall(function()
            if _occlVolume.IsValid and _occlVolume:IsValid() then
                _occlVolume:K2_DestroyActor()
                destroyed = true
            end
        end)
        _occlVolume = nil
        Log.Info(MODULE, "Occlusion test volume DESTROYED", {ok = tostring(destroyed)})
        return
    end

    -- Spawn path (keybind handlers run on the game thread)
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
    if not pawnObj then
        Log.Warn(MODULE, "Occlusion volume: no pawn (run on a course)")
        return
    end

    -- Shared with the auto rain blocker (mechanism field-proven 2026-07-28)
    _occlVolume = spawnSlabGT(px, py, pz)
    if not _occlVolume then return end
    Log.Info(MODULE, "Occlusion test volume SPAWNED (manual slab)", {
        pos = string.format("%.0f,%.0f,%.0f", px, py, pz + 1500.0),
    })
    -- Immediate self-check: the sweep should report a TriggerBox hit
    Tunnels.OcclusionProbe()
end

-- ============== CEILING CENSUS + FLIP EXPERIMENT (2026-07-28) ==============
-- The probe verdict: linings are PhysicsOnly (real bodies, queries off).
-- If flipping them to QueryAndPhysics makes their EXISTING bodies answer
-- simple traces, rain collides with the REAL ceiling: no spawned slab, no
-- delays, no oddities: the native fix in pure Lua. These two debug keys
-- answer that: Alt+I = census (which components overhang the car, what
-- profile), Alt+Shift+I = flip the censused set queryable + re-sweep.

local _censusList = {}   -- comp refs from the last census (course-scoped)
local _boundsShapeLogged = false

--- Alt+I: enumerate StaticMeshComponents whose bounds contain the column
--- above the car. One-shot GT sweep over the component array: this is a
--- DEBUG key (expect a brief hitch), not runtime machinery.
function Tunnels.CeilingCensus()
    local px, py, pz = nil, nil, nil
    pcall(function()
        local UEH = getUEHelpers()
        local pc = UEH and UEH.GetPlayerController and UEH.GetPlayerController()
        local pawn = pc and pc.Pawn
        if pawn and pawn.IsValid and pawn:IsValid() then
            local loc = pawn:K2_GetActorLocation()
            if loc then px, py, pz = loc.X, loc.Y, loc.Z end
        end
    end)
    if px == nil then
        Log.Warn(MODULE, "Census: no pawn")
        return
    end

    -- v7 PROXIMITY census (2026-07-28: the Bounds property proved
    -- unreadable through every coercion, see ue4ss-lua-footguns item -2;
    -- K2_GetComponentLocation is a plain single-return UFunction whose
    -- vector unwraps to real numbers everywhere in this codebase).
    -- Collect every component within RadiusXY of the car across the swept
    -- classes, sort by distance, list the closest 14 with full collision
    -- profiles + dz (positive = above the car): the lining sections are
    -- necessarily among the closest meshes inside a bore.
    _censusList = {}
    local cands = {}
    local classCounts = {}
    local RADIUS_XY = 8000.0   -- 80 m
    local CLASSES = {
        "StaticMeshComponent",
        "InstancedStaticMeshComponent",
        "HierarchicalInstancedStaticMeshComponent",
        "BrushComponent",
    }
    for _, cls in ipairs(CLASSES) do
        local total = 0
        local okSweep, sweepErr = pcall(function()
            local comps = FindAllOf(cls)
            if type(comps) ~= "table" then return end
            for _, c in ipairs(comps) do
                total = total + 1
                if validRef(c) then
                    local cx, cy, cz
                    pcall(function()
                        local loc = c:K2_GetComponentLocation()
                        if loc then
                            cx, cy, cz = tonumber(loc.X), tonumber(loc.Y), tonumber(loc.Z)
                        end
                    end)
                    if cx and cy and cz then
                        local dx, dy = cx - px, cy - py
                        local d = math.sqrt(dx * dx + dy * dy)
                        if d <= RADIUS_XY then
                            cands[#cands + 1] = { c = c, d = d, dz = cz - pz, cls = cls }
                        end
                    end
                end
            end
        end)
        classCounts[#classCounts + 1] = cls:sub(1, 4) .. "=" .. total
            .. (okSweep and "" or "!ERR")
        if not okSweep then
            Log.Warn(MODULE, "Census sweep error", {
                class = cls, err = tostring(sweepErr):sub(1, 160),
            })
        end
    end
    table.sort(cands, function(a, b) return a.d < b.d end)
    local kept = math.min(#cands, 14)
    Log.Info(MODULE, "Ceiling census", {
        classes = table.concat(classCounts, " "),
        within80m = #cands, listed = kept,
    })
    for i = 1, kept do
        local it = cands[i]
        _censusList[#_censusList + 1] = it.c
        local nm = "?"
        pcall(function()
            local fn = it.c:GetFullName()
            if type(fn) == "string" then nm = fn:sub(-70) end
        end)
        Log.Info(MODULE, string.format("Census [%d] %s d=%.0f dz=%+.0f %s | %s",
            i, it.cls:sub(1, 4), it.d, it.dz, nm, describeCollisionGT(it.c)))
    end
    if kept == 0 then
        Log.Info(MODULE,
            "Census: nothing within 80 m in any swept class (streaming or class coverage gap: report this)")
    end
end

--- Alt+Shift+I: WORLD COLLISION FLIP (2026-07-28, user design: the
--- NoCollisionMod idea inverted: "enable the same collision as the road
--- has, on EVERYTHING"). Sweeps every mesh component in the world and
--- gives it the road's rain-relevant behavior: QueryOnly enable where
--- collision is off + Block on Visibility (channel 3) everywhere. NO
--- physics is added anywhere (cars/camera behavior unchanged; camera
--- channel untouched): only queries change, i.e. rain traces and other
--- Visibility queries start seeing the whole world, tunnel art included.
--- Whether art meshes carry cooked collision data is exactly what the
--- auto-sweep afterward reveals (ceiling HIT = the native fix works).
function Tunnels.CeilingFlip()
    -- Clean experiment: suppress the auto slab for this session so the
    -- sweep and the visible rain reflect the REAL ceiling, not the blocker
    if RB_ENABLED then
        RB_ENABLED = false
        pcall(function()
            if rbActor ~= nil and validRef(rbActor) then rbActor:K2_DestroyActor() end
        end)
        rbActor = nil
        rbHoldUntil = nil
        Log.Info(MODULE, "Auto rain blocker SUPPRESSED for this session (flip experiment)")
    end
    -- Everything-sweep, per class (the proven v7 loop pattern). Rules:
    -- en==0 (None) -> QueryOnly + vis-block (art meshes: the whole point);
    -- en==2 (PhysicsOnly) -> QueryAndPhysics + vis-block (none found so
    -- far, covered anyway); en==1/3 (already queryable, e.g. the Colli
    -- shells) -> vis-block only. Physics is never ADDED to anything that
    -- had none: gameplay collision is untouched.
    local CLASSES = {
        "StaticMeshComponent",
        "InstancedStaticMeshComponent",
        "HierarchicalInstancedStaticMeshComponent",
    }
    -- v2 (12:12 field run decoded): (a) EXCLUDE sky/weather actors: the
    -- BP_CourseSky world-enclosing Cube was the entire overshoot: every
    -- trace hit it at dist 0 = rain stopped everywhere + AI blinded.
    -- (b) The bore press proved art meshes carry COMPLEX collision only
    -- (ch0c hit the real ceiling at 389): rain traces are SIMPLE, so each
    -- flipped mesh's BodySetup gets CTF_UseComplexAsSimple (2) BEFORE
    -- enabling: the same flag the Colli road shells use: simple traces
    -- then route to the trimesh and rain can hit art.
    local enabledN, visN, skippedN, casN = 0, 0, 0, 0
    for _, cls in ipairs(CLASSES) do
        local okSweep, sweepErr = pcall(function()
            local comps = FindAllOf(cls)
            if type(comps) ~= "table" then return end
            for _, c in ipairs(comps) do
                if validRef(c) then
                    -- v7 (15:19 field: pure-Lua occlusion PROVEN in an
                    -- unpatched tunnel; overpasses still leak because the
                    -- tnl/Mesh_tn scalpel never touches them): EXCLUSION
                    -- filter instead: flip the WHOLE world except the known
                    -- poisons: the CourseSky world-enclosing Cube (the
                    -- 12:12 rain-dead-everywhere/AI-blind overshoot) and
                    -- vehicle meshes (mid-air rain near cars; shared assets
                    -- across every AI car; they move = path churn).
                    local compName = nil
                    pcall(function() compName = c:GetFullName() end)
                    local excluded = type(compName) == "string" and (
                        compName:find("CourseSky") or compName:find("Ultra_Dynamic")
                        or compName:find("UltraDynamic") or compName:find("GameVehicle")
                        or compName:find("BP_GV")) or compName == nil
                    if excluded then
                        skippedN = skippedN + 1
                    else
                        -- v6 (14:58 BREAKTHROUGH decoded): ch0s hits proved
                        -- the pak works AND exposed my wrong enum constant:
                        -- CTF_UseComplexAsSimple = 3, not 2 (every runtime
                        -- write of "2" was setting the useless
                        -- SimpleAsComplex mode). casN counts pre-existing
                        -- 3s (pak evidence); meshes without it get the
                        -- CORRECT runtime write of 3 pre-enable: if THAT
                        -- yields ch0s in unpatched sections, the whole fix
                        -- is pure Lua and the pak becomes optional.
                        pcall(function()
                            local bs = c.StaticMesh and c.StaticMesh.BodySetup
                            if bs then
                                if tonumber(bs.CollisionTraceFlag) == 3 then
                                    casN = casN + 1
                                else
                                    bs.CollisionTraceFlag = 3
                                end
                            end
                        end)
                        local en = nil
                        pcall(function() en = c:GetCollisionEnabled() end)
                        if en == 0 then
                            pcall(function() c:SetCollisionEnabled(1) end) -- QueryOnly
                            enabledN = enabledN + 1
                        elseif en == 2 then
                            pcall(function() c:SetCollisionEnabled(3) end) -- QueryAndPhysics
                            enabledN = enabledN + 1
                        end
                        pcall(function() c:SetCollisionResponseToChannel(3, 2) end) -- Visibility=Block
                        visN = visN + 1
                    end
                end
            end
        end)
        if not okSweep then
            Log.Warn(MODULE, "World flip sweep error", {
                class = cls, err = tostring(sweepErr):sub(1, 160),
            })
        end
    end
    Log.Info(MODULE, "WORLD RAIN COLLISION v7 applied", {
        queryEnabled = enabledN, preCtf3 = casN,
        visBlockSet = visN, skippedExcluded = skippedN,
    })
    Tunnels.OcclusionProbe()
end

-- ============== RAIN CHANNEL CYCLER (2026-07-28, user design) ==============
-- Alt+Y: step UDW's 'Weather Particle Collision Channel' through ECC 0..23,
-- one per press, with a full native re-bake each time (Update Static
-- Variables = channel mirror + SetAsset reset, so the change is visible
-- immediately). Field method: test rain on, press, drive under cover,
-- observe; repeat. Finds any EXISTING channel where the game's collision
-- world already occludes rain correctly: zero mesh mutation needed if one
-- exists. Every press logs channel + name.
local rainChanCycle = nil
local RAIN_CH_NAMES = {
    [0] = "WorldStatic", [1] = "WorldDynamic", [2] = "Pawn",
    [3] = "Visibility (stock)", [4] = "Camera", [5] = "PhysicsBody",
    [6] = "Vehicle", [7] = "Destructible", [8] = "EngineTrace1 (g8 envelopes)",
    [17] = "GameTrace4 (ColiRoad obj)", [18] = "GameTrace5 (ColiWall obj)",
}

function Tunnels.CycleRainChannel()
    local actors = getActors()
    local udw = actors and actors.GetUDW and actors.GetUDW()
    if not (udw and validRef(udw)) then
        Log.Warn(MODULE, "Rain channel cycle: no UDW (on a course?)")
        return
    end
    if rainChanCycle == nil then
        local cur = nil
        pcall(function() cur = udw["Weather Particle Collision Channel"] end)
        rainChanCycle = tonumber(cur) or 3
    end
    -- Full ECollisionChannel space: 32 slots (0..31; customs = GameTrace1
    -- at 14 through GameTrace18 at 31). The 24 cap belonged to the smaller
    -- ETraceTypeQuery space and never applied here (user catch).
    rainChanCycle = (rainChanCycle + 1) % 32
    local wrote = pcall(function()
        udw["Weather Particle Collision Channel"] = rainChanCycle
    end)
    local rebaked = false
    pcall(function()
        local fn = udw["Update Static Variables"]
        if fn then fn(udw); rebaked = true end
    end)
    local nm = RAIN_CH_NAMES[rainChanCycle]
        or (rainChanCycle >= 14 and ("GameTrace" .. (rainChanCycle - 13))
            or ("EngineTrace" .. (rainChanCycle - 7)))
    Log.Info(MODULE, "RAIN CHANNEL CYCLE", {
        channel = rainChanCycle, name = nm,
        wrote = tostring(wrote), rebaked = tostring(rebaked),
    })
end

function Tunnels.GetStatus()
    return {
        initialized = isInitialized,
        enabled = enabled,
        armed = armed,
        covered = tunnelNow,
        rainSuppressed = rainZoneNow,
        roof = roofNow,
        lastAttr = lastTunnelAttr,
    }
end

function Tunnels.IsInitialized()
    return isInitialized
end

--- Alias so the module can be ticked as either Tick() or Update().
Tunnels.Tick = Tunnels.Update

return Tunnels
