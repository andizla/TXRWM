-- TXR Weather Mod v3.0
-- systems/tunnels.lua
-- Covered-road detection. Two signals feed one "covered" state:
--   1. Road data (primary): the pawn's tunnel_attribute
--      (ERPDTunnelBitAttribute: Left=1, Right=2, Up=4); the Up bit = roofed
--      road, exact dev-authored boundaries, all real bores.
--   2. Roof trace: lone overpasses are not marked in the road data, so a
--      Visibility trace covers them (downward for deck tops, upward for
--      linings; TXR road meshes are one-sided for queries). Config-off
--      since the rain kill retired; the attribute carries every bore.
-- The covered flag drives the fog damp (enhanced_fog), forced headlights
-- in bores, and the photomode covered metering. This module also clears
-- the course volumes' authored LumenSkylightLeaking override once per
-- course (it flooded covered sections with flat sky ambient at every
-- volume edge). NO exposure writes here: per-volume exposure is a closed
-- dead end (blend-edge snapping), and stock exposure handles bores
-- correctly with the leak dead.
-- RAIN: no longer this module's job. Rain occludes on real geometry via
-- systems/rain_collision.lua (3.8.0); the old particle-hiding kill
-- (TunnelRainKill / OverpassRainKill, Weather.SetPrecipSuppressed) is
-- config-off and dormant, kept as the fallback mechanism.

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
--- @return boolean hit, boolean callOk, number|nil dist, string|nil hitName, string|nil leg, userdata|nil compRef
local function roofProbeGT(ksl, pawn, x, y, z)
    local sD = { X = x, Y = y, Z = z + 250.0 + OVERPASS_TRACE_LEN }
    local eD = { X = x, Y = y, Z = z + 250.0 }
    local hit, ok, dist, name, ref = traceChanSegGT(ksl, pawn, sD, eD, 0)
    if hit then return hit, ok, dist, name, "down", ref end
    local hit2, ok2, dist2, name2, ref2 = traceChanSegGT(ksl, pawn, eD, sD, 0)
    if hit2 then return hit2, (ok or ok2), dist2, name2, "up", ref2 end
    return false, (ok or ok2), nil, nil, nil, nil
end

--- SHADOW/SIDEDNESS READOUT for the mesh overhead (2026-07-29). The
--- tunnel sun-pool artifact is present in VANILLA (field-verified with no
--- engine.ini), which rules out the mod AND the forced-VSM config, so the
--- remaining candidates are content-side: the lining not casting shadows
--- at all, or casting them one-sided (the sun enters through backfaces),
--- or simply absent geometry. This is READ-ONLY and decides which:
---   CastShadow=false      -> reachable: SetCastShadow(true) is a real
---                            UFunction on this cook (it dirties render
---                            state itself, unlike a raw flag write).
---   CastShadow=true + two-sided flags/material false -> winding case.
---                            bCastShadowAsTwoSided has NO setter and no
---                            exposed MarkRenderStateDirty, so a live
---                            write is a silent no-op = NOT fixable here.
--- Property names verified in UE4SS_ObjectDump (PrimitiveComponent
--- CastShadow, bCastShadowAsTwoSided, bCastHiddenShadow, bCastStaticShadow,
--- bCastDynamicShadow). Unreadable entries print "?" rather than guessing.
local function describeShadowGT(ref)
    local comp = nil
    pcall(function()
        if ref and ref.Get then comp = ref:Get() else comp = ref end
    end)
    if not comp then return "unresolvable" end
    local parts = {}
    -- The MESH ASSET name first: Config.RainCollision.TargetPatterns match
    -- against this path, so it is the field that says which pattern to add
    -- when a surface is leaking and was never flipped.
    pcall(function()
        local sm = comp.StaticMesh
        if sm then
            local fn = sm:GetFullName()
            if type(fn) == "string" then
                parts[#parts + 1] = "mesh=" .. (fn:match("([^%.%s/]+)$") or fn)
            end
        end
    end)
    for _, p in ipairs({
        "CastShadow", "bCastShadowAsTwoSided", "bCastDynamicShadow",
        "bCastStaticShadow", "bCastHiddenShadow",
    }) do
        local v = "?"
        pcall(function() v = tostring(comp[p]) end)
        parts[#parts + 1] = p .. "=" .. v
    end
    -- Material sidedness: the other half of the winding question. Slot 0
    -- is enough for a lining. GetMaterial is a UFunction, so this only
    -- runs from game-thread callers (keybind handlers are).
    pcall(function()
        local mat = comp:GetMaterial(0)
        if mat then
            local nm = "?"
            pcall(function()
                local fn = mat:GetFullName()
                if type(fn) == "string" then nm = fn:match("([^%.%s/]+)$") or fn end
            end)
            parts[#parts + 1] = "mat=" .. nm
            -- MaterialInstances do not carry TwoSided; the BASE material
            -- does, so try that first. Type-check the result: reading a
            -- missing property on this build yields a UObject rather than
            -- nil, which the first version of this probe printed verbatim.
            local ts = nil
            pcall(function()
                local base = mat.GetBaseMaterial and mat:GetBaseMaterial()
                if base then
                    local v = base.TwoSided
                    if type(v) == "boolean" then ts = v end
                end
            end)
            if ts == nil then
                pcall(function()
                    local v = mat.TwoSided
                    if type(v) == "boolean" then ts = v end
                end)
            end
            parts[#parts + 1] = "matTwoSided=" .. (ts == nil and "?" or tostring(ts))
        end
    end)
    return table.concat(parts, " ")
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
    -- The fast cadence exists for the rain KILL's portal reaction. Native
    -- occlusion (Config.RainCollision) superseded that kill, so a wet
    -- preset alone no longer re-arms the 4 Hz poll: the live consumers
    -- (fog damp, the covered flag for headlights and photomode) ran on the
    -- dry cadence for the whole no-rain build. Re-enabling TunnelRainKill
    -- restores the old behavior.
    local fast = rainZoneNow or roofNow
    if not fast and TUNNEL_RAIN_KILL then
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
    end

    -- The containment poll always earns its keep: the covered flag it
    -- maintains feeds the fog damp, headlights AutoOnInTunnel and the
    -- photomode CoveredLens. (It used to hang on the rain kill / leak kill
    -- flags, so turning those off silently killed covered detection too.)
    featuresActive = true

    isInitialized = true
    State.SetModuleStatus("tunnels", true)

    if not enabled then
        Log.Info(MODULE, "Tunnels module disabled in config")
        return true
    end

    Log.Info(MODULE, "Initializing tunnels module", {
        rainKill = TUNNEL_RAIN_KILL,
        overpass = OVERPASS_KILL,
    })
    return true
end

function Tunnels.OnCourseLoad()
    ppArmed = false         -- fresh course volumes: re-run the leak kill
    ppNextPoll = 0.0
    roofProbeLogged = false
    tunnelReset()           -- Weather.Apply on load clears any suppression
    armed = true
end

function Tunnels.OnCourseUnload()
    armed = false
    ppArmed = false
    tunnelReset()
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

--- NEARBY MESH CENSUS (2026-07-30). The sun trace names what SHADES you;
--- this names what is AROUND you, which is what you need when a specific
--- surface is lit and you do not know its asset. Field case: the wall
--- (_wr) and deck (_br) at a spot were both confirmed flipped, yet the
--- KERB strip stayed lit, so the kerb is a separate asset that
--- TargetPatterns never matches. One press next to the lit surface names
--- it, and the name becomes the pattern.
--- Runs only on the Alt+N keypress, so the sweep cost (one FindAllOf plus
--- a location read per component, ~100 ms) is a deliberate one-off: this
--- is exactly the work that was retired from the automatic bore-entry
--- census for being a hitch.
--- Is this hit one of TXR's INVISIBLE collision shells? Identify them by
--- what they ARE (the Colli asset family / Ma_Colli* materials), NOT by
--- CastShadow=false. Using the flag was a real bug (caught 2026-07-30):
--- it also matches a VISIBLE mesh that merely does not cast
--- shadows, so the fan skipped straight past such a surface and reported
--- whatever stood behind it. In a shadow investigation a visible
--- non-casting mesh is the single most interesting thing we could find, so
--- it must be reported, not stepped over.
local function isCollisionShellGT(ref)
    local comp = nil
    pcall(function()
        if ref and ref.Get then comp = ref:Get() else comp = ref end
    end)
    if not comp then return false end
    local hit = false
    pcall(function()
        local sm = comp.StaticMesh
        if sm then
            local fn = sm:GetFullName()
            if type(fn) == "string" then
                -- shells: ps3_rise_*, ps3_wall_*, Colli_*, joint_*
                if fn:find("Colli") or fn:find("ps3_rise") or fn:find("ps3_wall")
                   or fn:find("/joint_") then
                    hit = true
                end
            end
        end
    end)
    if not hit then
        pcall(function()
            local mat = comp:GetMaterial(0)
            if mat then
                local mn = mat:GetFullName()
                if type(mn) == "string" and mn:find("Ma_Colli") then hit = true end
            end
        end)
    end
    return hit
end

--- Trace a direction, stepping past invisible collision shells only.
--- Stops at the first RENDERING surface, whatever its shadow flags.
--- @return number|nil dist, string|nil name, userdata|nil ref, number skipped
local function traceSkippingShellsGT(ksl, pawn, px, py, pz, ux, uy, uz, reach)
    local skipped, from = 0, 0.0
    for _ = 1, 5 do
        local s = { X = px + ux * from, Y = py + uy * from, Z = pz + uz * from }
        local e = { X = px + ux * reach, Y = py + uy * reach, Z = pz + uz * reach }
        local h, _okc, dist, hitName, ref = traceChanSegGT(ksl, pawn, s, e, 0)
        if not h then return nil, nil, nil, skipped end
        if isCollisionShellGT(ref) then
            skipped = skipped + 1
            from = from + (dist or 0.0) + 50.0
            if from >= reach then return nil, nil, nil, skipped end
        else
            return (dist or 0) + from, hitName, ref, skipped
        end
    end
    return nil, nil, nil, skipped
end

--- SURFACE FAN (2026-07-30). Replaces distance-from-origin censusing, which
--- cannot see large geometry: K2_GetComponentLocation returns a mesh's PIVOT,
--- and a tunnel/wall/kerb section is anchored hundreds of metres away, so the
--- surfaces wrapped around the car never register as "nearby" (field: 112
--- components in range were 109 car parts plus a sign, a collision shell and
--- a bush). Rays find surfaces where they actually ARE. Fires 12 directions:
--- a horizontal ring at kerb height plus four angled down, each skipping
--- invisible shells, reporting the mesh name and its shadow flags. Park next
--- to the lit surface and the ray that reaches it names the asset.
--- SECTION ROSTER (2026-07-30). The decisive tool, and the one the ray
--- probes could never be: TXR's art meshes ship with collision DISABLED,
--- so they answer NO trace at all (the founding finding of the whole
--- occlusion arc). Rays can therefore only ever see collision shells, stock
--- collision-bearing meshes, and meshes WE already flipped, which is why
--- every sweep kept returning the one wall we had fixed and never the kerb.
--- Enumerating by NAME does not care about collision: take the section
--- token from a mesh we did identify (e.g. SMsr_c1_067A_wr -> "c1_067") and
--- list every distinct asset in that section with its shadow flags. The
--- kerb is necessarily in that list.
--- ASSET CENSUS rev 2 (2026-07-30, after the sun-direction screenshot).
--- The residual lit kerb turned out NOT to be a one-sided face at all: the
--- covered sections have GAPS in their outer wall, and where a wall segment
--- is absent the low sun reaches the kerb directly. Flipping cannot fix a
--- hole, which is why five rounds of pattern targeting changed nothing even
--- though the roster confirmed every wall/kerb/deck asset had twoSided=true.
--- So this census answers the only question left that Lua can act on:
---   (a) rosters for the section AND its neighbours, carrying the visibility
---       flags. If a leaking section HAS the wall component but it is
---       invisible or culled, bCastHiddenShadow makes a hidden primitive cast
---       shadows anyway, which is a real fix. If the wall simply is not in the
---       list, the geometry is missing and no flag reaches it.
---   (b) a map-wide suffix-family tally, so "did we miss a wall family?" stops
---       being guesswork. TXR names assets <SMxx>_<route>_<section><variant>_
---       <suffix>, so the suffix is the family: _wc/_wl/_wr walls, _s
---       sidewalk, _br barrier, _r roadway, _a apron, w_ext exterior wall.
--- Both come out of ONE component sweep with the asset name cached per mesh,
--- so a press costs about what the collision pass costs.
local function assetCensusGT(keys)
    keys = (type(keys) == "table") and keys or {}
    local rows, seen = {}, {}
    local fam, famSeen = {}, {}
    for _, k in ipairs(keys) do rows[k] = {} end
    pcall(function()
        local comps = FindAllOf("StaticMeshComponent")
        if type(comps) ~= "table" then return end
        local nameOf = {}
        for _, c in ipairs(comps) do
            if validRef(c) then
                local short, sm = nil, nil
                pcall(function() sm = c.StaticMesh end)
                if sm then
                    local mk = nil
                    pcall(function() mk = tostring(sm) end)
                    if mk and nameOf[mk] ~= nil then
                        short = nameOf[mk] or nil
                    else
                        local nm = nil
                        pcall(function() nm = sm:GetFullName() end)
                        if type(nm) == "string" then
                            short = nm:match("([^%.%s/]+)$") or nm
                        end
                        if mk then nameOf[mk] = short or false end
                    end
                end
                if type(short) == "string" then
                    -- section rosters (flags read at most once per component)
                    local read, cast, two, en, vis, hid, hs =
                        false, "?", "?", "?", "?", "?", "?"
                    for _, k in ipairs(keys) do
                        if short:find(k, 1, true)
                           and not seen[k .. "|" .. short] then
                            seen[k .. "|" .. short] = true
                            if not read then
                                read = true
                                pcall(function() cast = tostring(c.CastShadow) end)
                                pcall(function() two = tostring(c.bCastShadowAsTwoSided) end)
                                pcall(function() en = tostring(c:GetCollisionEnabled()) end)
                                pcall(function() vis = tostring(c.bVisible) end)
                                pcall(function() hid = tostring(c.bHiddenInGame) end)
                                pcall(function() hs = tostring(c.bCastHiddenShadow) end)
                            end
                            local t = rows[k]
                            t[#t + 1] = { mesh = short, cast = cast, two = two,
                                          en = en, vis = vis, hid = hid, hs = hs }
                        end
                    end
                    -- suffix family, tallied once per distinct asset
                    local tail = short:match("^SM%a*_[^_]+_%w+_(.+)$")
                    if tail then
                        local head = tail:match("^(%a+)")
                        local family = (head and #head <= 3) and head or tail
                        if not famSeen[family .. "|" .. short] then
                            famSeen[family .. "|" .. short] = true
                            local f = fam[family]
                            if not f then
                                f = { assets = 0, flipped = 0, unflipped = 0,
                                      noCast = 0, ex = short }
                                fam[family] = f
                            end
                            local fCast, fTwo = nil, nil
                            pcall(function() fCast = c.CastShadow end)
                            pcall(function() fTwo = c.bCastShadowAsTwoSided end)
                            f.assets = f.assets + 1
                            if fTwo == true then
                                f.flipped = f.flipped + 1
                            else
                                f.unflipped = f.unflipped + 1
                                f.ex = short
                            end
                            if fCast == false then f.noCast = f.noCast + 1 end
                        end
                    end
                end
            end
        end
    end)
    for _, k in ipairs(keys) do
        local t = rows[k]
        table.sort(t, function(a, b) return a.mesh < b.mesh end)
        Log.Info(MODULE, string.format("SECTION '%s': %d distinct meshes", k, #t))
        for i, r in ipairs(t) do
            Log.Info(MODULE, string.format(
                "SECT[%s %02d] mesh=%-28s cast=%-5s twoSided=%-5s vis=%-5s "
                .. "hidden=%-5s hidShadow=%-5s coll=%s",
                k, i, r.mesh, r.cast, r.two, r.vis, r.hid, r.hs, r.en))
        end
    end
    local flist = {}
    for name, f in pairs(fam) do flist[#flist + 1] = { name = name, f = f } end
    table.sort(flist, function(a, b)
        if a.f.unflipped ~= b.f.unflipped then
            return a.f.unflipped > b.f.unflipped
        end
        return a.name < b.name
    end)
    Log.Info(MODULE, string.format(
        "FAMILY CENSUS: %d suffix families in the loaded world "
        .. "(sorted by unflipped assets)", #flist))
    for i, e in ipairs(flist) do
        Log.Info(MODULE, string.format(
            "FAM[%02d] %-16s assets=%-4d flipped=%-4d unflipped=%-4d "
            .. "noCast=%-4d e.g. %s",
            i, e.name, e.f.assets, e.f.flipped, e.f.unflipped, e.f.noCast,
            e.f.ex))
    end
end

--- DENSE SWEEP: 16 directions x 5 heights = 80 shell-skipping rays inside a
--- 15 m sphere, deduped by mesh asset, printed as an UNCAPPED list sorted
--- by nearest hit. This is the "just show me everything around the car"
--- tool. Ray-based on purpose: origin distance cannot see large sections
--- (their pivots are hundreds of metres away), and the Bounds property is
--- unreadable on this build, so rays are the only way to locate surfaces
--- where they physically are. Heights step from just above the road (a
--- kerb top) to roof level, measured from the pawn origin.
local function surfaceFanGT(ksl, pawn, px, py, pz)
    local REACH = 1500.0    -- 15 m
    local HEIGHTS = { 5.0, 25.0, 60.0, 150.0, 300.0 }
    local DIRS = 16
    local found = {}        -- mesh name -> {dist, info}
    for _, h in ipairs(HEIGHTS) do
        for i = 0, DIRS - 1 do
            local a = (math.pi * 2.0) * (i / DIRS)
            local dist, name, ref = traceSkippingShellsGT(
                ksl, pawn, px, py, pz + h,
                math.cos(a), math.sin(a), 0.0, REACH)
            if dist then
                local info = describeShadowGT(ref)
                local isCar = type(info) == "string" and (
                    info:find("MI_Car") or info:find("SM_Hit")
                    or info:find("_EF_") or info:find("Wheel"))
                local key = tostring(info):match("mesh=([^%s]+)") or (name or "?")
                if not isCar then
                    local prev = found[key]
                    if (not prev) or dist < prev.dist then
                        found[key] = { dist = dist, info = info, h = h,
                                       deg = math.floor((i / DIRS) * 360 + 0.5) }
                    end
                end
            end
        end
    end
    local list = {}
    for k, v in pairs(found) do list[#list + 1] = { k = k, v = v } end
    table.sort(list, function(a, b) return a.v.dist < b.v.dist end)
    Log.Info(MODULE, string.format(
        "SWEEP: %d distinct meshes within %.0f m (%d rays)",
        #list, REACH / 100.0, #HEIGHTS * DIRS))
    for i, it in ipairs(list) do
        local cast = tostring(it.v.info):match("CastShadow=(%S+)") or "?"
        local two = tostring(it.v.info):match("bCastShadowAsTwoSided=(%S+)") or "?"
        local mat = tostring(it.v.info):match("mat=(%S+)") or "?"
        Log.Info(MODULE, string.format(
            "SWEEP[%02d] d=%-6.0f z+%-5.0f az=%-3d mesh=%-28s cast=%-5s twoSided=%-5s mat=%s",
            i, it.v.dist, it.v.h, it.v.deg, it.k, cast, two, mat))
    end
    if #list == 0 then
        Log.Info(MODULE, "SWEEP: nothing rendering within 15 m in any direction")
    end
end

--- UNCAPPED origin-distance list (2026-07-30 ask: "list all meshes
--- within 15 m, no cap, as a list I can look at"). Complements the ray
--- sweep: this one catches small props whose pivot really is nearby, while
--- the sweep catches big sections whose pivot is far away. Deduped by mesh
--- asset so the output stays readable.
local function nearbyMeshCensusGT(px, py, pz)
    local RADIUS = 1500.0   -- 15 m, as asked
    local MIN_DIST = 50.0   -- skip anything on top of the camera/car
    local KEEP = math.huge  -- UNCAPPED
    local cands = {}
    pcall(function()
        local comps = FindAllOf("StaticMeshComponent")
        if type(comps) ~= "table" then return end
        for _, c in ipairs(comps) do
            if validRef(c) then
                local cx, cy, cz
                pcall(function()
                    local loc = c:K2_GetComponentLocation()
                    if loc then
                        cx, cy, cz = tonumber(loc.X), tonumber(loc.Y), tonumber(loc.Z)
                    end
                end)
                if cx and cy and cz then
                    local dx, dy, dz = cx - px, cy - py, cz - pz
                    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                    -- VEHICLES OUT (field 2026-07-30: the first run listed 12
                    -- of the player car's own body parts, all at d=0, because
                    -- they are attached to the pawn). Same name filter the
                    -- rain pass uses, and it drops AI cars too.
                    local nm = nil
                    if d >= MIN_DIST and d <= RADIUS then
                        pcall(function() nm = c:GetFullName() end)
                    end
                    local isVehicle = type(nm) == "string" and (
                        nm:find("GameVehicle") or nm:find("BP_GV")
                        or nm:find("Wheel") or nm:find("_EF_"))
                    if nm and not isVehicle then
                        cands[#cands + 1] = { c = c, d = d }
                    end
                end
            end
        end
    end)
    table.sort(cands, function(a, b) return a.d < b.d end)
    -- Dedupe by mesh asset (one line per asset, nearest instance) so the
    -- uncapped list stays readable when a section ships many components.
    local seen, rows = {}, {}
    for _, it in ipairs(cands) do
        local mesh, cast, two = "?", "?", "?"
        pcall(function()
            local sm = it.c.StaticMesh
            if sm then
                local fn = sm:GetFullName()
                if type(fn) == "string" then mesh = fn:match("([^%.%s/]+)$") or fn end
            end
        end)
        if not seen[mesh] then
            seen[mesh] = true
            pcall(function() cast = tostring(it.c.CastShadow) end)
            pcall(function() two = tostring(it.c.bCastShadowAsTwoSided) end)
            rows[#rows + 1] = { d = it.d, mesh = mesh, cast = cast, two = two }
        end
        if #rows >= KEEP then break end
    end
    Log.Info(MODULE, string.format(
        "ORIGIN LIST: %d components within %.0f m, %d distinct meshes",
        #cands, RADIUS / 100.0, #rows))
    for i, r in ipairs(rows) do
        Log.Info(MODULE, string.format(
            "ORIGIN[%02d] d=%-6.0f mesh=%-28s cast=%-5s twoSided=%s",
            i, r.d, r.mesh, r.cast, r.two))
    end
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
    local shadowInfo = nil
    local ksl = getKslRef()
    if ksl then
        local h, okc, dist, hitName, leg, ref = roofProbeGT(ksl, pawnObj, px, py, pz)
        if h then
            probe = string.format("HIT(%s)@%scm:%s", leg or "?",
                dist and string.format("%.0f", dist) or "?", hitName or "?")
            -- Shadow/sidedness of whatever is overhead: the read that
            -- decides the vanilla tunnel sun-pool question (see
            -- describeShadowGT). Also useful under a deck.
            if ref ~= nil then shadowInfo = describeShadowGT(ref) end
        elseif okc then
            probe = "miss"
        else
            probe = "ERR"
        end
    end

    -- SUN TRACE (2026-07-30): the roof probe only looks straight up and
    -- down, so a section leaking through a WALL never gets identified by
    -- it. Trace from the car TOWARD THE SUN instead: whatever that ray
    -- hits is exactly the surface that should be casting the shadow, and
    -- its flags say why it is not. UDS "Cached Sun Vector" is the LIGHT
    -- direction (sun -> scene), so the sun lies along its negation.
    -- Struct members are read inside pcall and reduced to plain numbers
    -- immediately (the standing struct-userdata rule).
    local sunProbe = "no-uds"
    local sunShadow = nil
    if ksl then
        local sx, sy, sz = nil, nil, nil
        pcall(function()
            local actors = getActors()
            local uds = actors and actors.GetUDS and actors.GetUDS()
            if uds and uds.IsValid and uds:IsValid() then
                local v = uds["Cached Sun Vector"]
                if v then
                    sx, sy, sz = tonumber(v.X), tonumber(v.Y), tonumber(v.Z)
                end
            end
        end)
        if sx and sy and sz then
            local len = math.sqrt(sx * sx + sy * sy + sz * sz)
            if len > 0.001 then
                -- Unit direction toward the sun (negate: the cached vector
                -- points sun -> scene)
                local ux, uy, uz = -sx / len, -sy / len, -sz / len
                local REACH = 15000.0        -- 150 m
                -- WALK PAST THE INVISIBLE COLLISION SHELLS. TXR's collision
                -- world is ~21 invisible shell meshes (Ma_ColliRoad /
                -- Ma_ColliWall) that block Visibility, so a single trace from
                -- the car always stops on one of them a few metres out and
                -- never reaches the visible structure (field 2026-07-30: all
                -- three probes returned Ma_ColliWall at 190-595 cm). Shells do
                -- not render, so CastShadow=false identifies them: step the
                -- start point past each such hit and keep going until we find
                -- something that actually casts.
                local skipped = 0
                local from = 0.0
                for _ = 1, 8 do
                    local s = { X = px + ux * from, Y = py + uy * from,
                                Z = pz + 250.0 + uz * from }
                    local e = { X = px + ux * REACH, Y = py + uy * REACH,
                                Z = pz + 250.0 + uz * REACH }
                    local h, okc, dist, hitName, ref = traceChanSegGT(ksl, pawnObj, s, e, 0)
                    if not h then
                        sunProbe = okc
                            and string.format(
                                "MISS after %d shell(s): nothing rendering between car and sun", skipped)
                            or "ERR"
                        break
                    end
                    -- shells identified by asset family, not by CastShadow
                    -- (see isCollisionShellGT): a visible non-casting mesh
                    -- must be reported, it is the prime suspect
                    if isCollisionShellGT(ref) then
                        -- invisible collision shell: step past it and retry
                        skipped = skipped + 1
                        from = from + (dist or 0.0) + 50.0
                        if from >= REACH then
                            sunProbe = string.format("MISS (ran out of reach after %d shells)", skipped)
                            break
                        end
                    else
                        sunProbe = string.format("HIT@%scm:%s (skipped %d shell(s))",
                            dist and string.format("%.0f", (dist or 0) + from) or "?",
                            hitName or "?", skipped)
                        if ref ~= nil then sunShadow = describeShadowGT(ref) end
                        break
                    end
                end
            end
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
        shadow = shadowInfo or "no-hit",
        sun_probe = sunProbe,
        sun_shadow = sunShadow or "n/a",
    })

    -- Names the surfaces physically around you. The FAN is the reliable one
    -- (rays hit geometry where it is); the origin-distance census only ever
    -- finds small props, since large sections are anchored far away, so it
    -- is kept purely as a secondary listing.
    if ksl then surfaceFanGT(ksl, pawnObj, px, py, pz) end
    nearbyMeshCensusGT(px, py, pz)

    -- SECTION ROSTER: the one enumeration that does not depend on collision,
    -- so it is the only way to see art meshes we have not flipped. Derive
    -- the section token from whichever mesh the probes DID identify.
    local sectionKey = nil
    for _, src in ipairs({ shadowInfo, sunShadow }) do
        if type(src) == "string" then
            local mesh = src:match("mesh=([^%s]+)")
            -- SMsr_c1_067A_wr -> c1_067 (drop the A/B variant letter so the
            -- whole section is listed, not just one sub-piece)
            local key = mesh and mesh:match("(c%d+_%d+)")
            if key then sectionKey = key; break end
        end
    end
    -- Neighbour sections matter as much as the current one: the leak is a GAP
    -- in the outer wall, so the useful comparison is a leaking section against
    -- an adjacent intact one. c1_067 -> c1_065 .. c1_069. With no section
    -- token we still run the map-wide family tally, which needs no key.
    local keys = {}
    if sectionKey then
        local route, num = sectionKey:match("^(c%d+)_(%d+)$")
        if route and num then
            local n, width = tonumber(num), #num
            for d = -2, 2 do
                if n + d >= 0 then
                    keys[#keys + 1] =
                        string.format("%s_%0" .. width .. "d", route, n + d)
                end
            end
        else
            keys[1] = sectionKey
        end
    else
        Log.Info(MODULE,
            "SECTION: no section token in the probe hits; family census only")
    end
    assetCensusGT(keys)
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
    -- 0..23 (2026-07-28 challenge: "the camera DOES collide with the
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

    -- CAR profile (2026-07-28 question: "can we find the car's channel?"):
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
