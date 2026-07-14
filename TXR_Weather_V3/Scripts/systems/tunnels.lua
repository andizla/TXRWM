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
local PROBE_PP = false           -- research flag: poll alive with features off
local TUNNEL_VOLUMES = {}        -- set: [shortName] = true (curated bores)
local TUNNEL_AUTO = true         -- authored-bias volumes count as covered too
local TUNNEL_AUTO_MIN = 0.05     -- authored-bias threshold for auto membership
local TUNNEL_RAIN_KILL = true
local TUNNEL_LOOKAHEAD_S = 1.2   -- rain-kill lookahead seconds
local KILL_SKY_LEAK = true       -- clear the volumes' authored
                                 -- LumenSkylightLeaking override (see header)
local OVERPASS_KILL = true
local OVERPASS_TRACE_LEN = 5000.0 -- cm of headroom checked (50 m)
local OVERPASS_DEBUG = false     -- throttled probe logging (dist + hit name)
local RAIN_CLEAR_POLLS = 4       -- uncovered polls before the kill releases
local POLL_RAIN_S = 0.25         -- poll cadence while precipitation can fall
local POLL_DRY_S = 1.0           -- poll cadence when dry

-- ============== STATE ==============
local isInitialized = false
local featuresActive = false     -- computed in Init: any feature on
local armed = false              -- course gate (set by main via OnCourseLoad)
local ppRefs = nil               -- per-course volume list (cleared on unload)
local ppInside = {}              -- [index] = true while the pawn is inside
local ppNextPoll = 0.0
local ppShapeLogged = false      -- one-shot out-table diagnostic if capture fails
local tunnelNow = false          -- car inside a covered volume
local rainZoneNow = false        -- car/lookahead/roof covered (drives the kill)
local rainClearCount = 0
local roofNow = false            -- roof signal from the last poll
local coverWasRoad = false       -- last covered poll included the road-data bit
local roofDbgLast = 0.0
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
--- @return boolean hit, boolean callOk, number|nil dist, string|nil hitName
local function traceChanSegGT(ksl, pawn, s, e, channel)
    local hit, callOk, dist, hitName = false, false, nil, nil
    local ok = pcall(function()
        local outHit = {}
        local r = ksl:LineTraceSingle(pawn, s, e, channel,
            false, {}, 0, outHit, true, TRACE_COLOR, TRACE_COLOR, 0.0)
        callOk = true
        hit = traceResult(r, outHit)
        if hit then
            local h = outHit
            pcall(function() if h.OutHit then h = h.OutHit end end)
            pcall(function() dist = tonumber(h.Distance) end)
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
    return hit, (ok and callOk), dist, hitName
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

-- ============== INTERNAL: containment poll (game thread) ==============

local function ppPollGT()
    local actors = getActors()
    if actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
        ppRefs = nil
        ppInside = {}
        tunnelReset()
        return
    end

    if not ppRefs then
        ppRefs = {}
        ppInside = {}
        tunnelReset()
        local leakCleared = 0
        pcall(function()
            local vols = FindAllOf("PostProcessVolume")
            if not vols then return end
            for _, v in ipairs(vols) do
                local e = { v = v }
                pcall(function()
                    local s = v.Settings
                    e.biasNum = tonumber(s.AutoExposureBias) or 0.0
                    e.bias = tostring(s.AutoExposureBias)
                end)
                -- Short name (same extraction as real_sun's ID dump): the
                -- stable key for the config tunnel list.
                pcall(function()
                    local fn = v:GetFullName() or ""
                    e.name = fn:match("PostProcessVolume_UAID_([^%s]+)$")
                        or fn:match("PersistentLevel%.([^%s]+)")
                end)
                if (e.name and TUNNEL_VOLUMES[e.name])
                    or (TUNNEL_AUTO and (e.biasNum or 0) > TUNNEL_AUTO_MIN) then
                    e.isTunnel = true
                end
                -- Bounds capture v4: Origin/BoxExtent are OUT-PARAMS, and
                -- UE4SS hands those back by FILLING a passed-in Lua table
                -- keyed by the param name, the convention already proven in
                -- this mod (GetDisplayVehicle/out_vehicle, GetIsMovingRHL/
                -- out_is_moving in headlights.lua). Accepts every plausible
                -- shape: param-name key holding an FVector, fields written
                -- straight into the table, or true return values.
                local function takeBounds(oT, xT)
                    if not (oT and xT) then return end
                    -- Each shape probed in its OWN pcall: indexing a missing
                    -- field on userdata ERRORS (does not return nil), so a
                    -- combined read would abort before trying the next shape.
                    local origin, extent
                    pcall(function() origin = oT.Origin end)
                    if origin == nil then origin = oT end
                    pcall(function() extent = xT.BoxExtent end)
                    if extent == nil then extent = xT end
                    local ox, oy, oz, ex, ey, ez
                    pcall(function()
                        ox, oy, oz = origin.X, origin.Y, origin.Z
                        ex, ey, ez = extent.X, extent.Y, extent.Z
                    end)
                    if ox and ex then
                        e.ox, e.oy, e.oz = ox, oy, oz
                        e.ex, e.ey, e.ez = ex, ey, ez
                    end
                end
                pcall(function()
                    local ksl = getKslRef()
                    if ksl then
                        local oT, xT = {}, {}
                        local r1, r2 = ksl:GetActorBounds(v, oT, xT)
                        takeBounds(oT, xT)
                        if not e.ox then takeBounds(r1, r2) end
                    end
                end)
                if not e.ox then
                    pcall(function()
                        local oT, xT = {}, {}
                        local r1, r2 = v:GetActorBounds(false, oT, xT, false)
                        takeBounds(oT, xT)
                        if not e.ox then takeBounds(r1, r2) end
                    end)
                end
                -- If v4 fails too, log what UE4SS actually put in the out
                -- tables (once) so the next log settles the convention
                -- instead of another silent failure.
                if not e.ox and not ppShapeLogged then
                    ppShapeLogged = true
                    pcall(function()
                        local oT, xT = {}, {}
                        local ksl = getKslRef()
                        if ksl then ksl:GetActorBounds(v, oT, xT) end
                        local keys = {}
                        for k, val in pairs(oT) do keys[#keys + 1] = "o." .. tostring(k) .. "=" .. type(val) end
                        for k, val in pairs(xT) do keys[#keys + 1] = "x." .. tostring(k) .. "=" .. type(val) end
                        Log.Info(MODULE, "Bounds shape debug",
                            {keys = (#keys > 0) and table.concat(keys, " ") or "BOTH EMPTY"})
                    end)
                end
                -- SKYLIGHT LEAK KILL (see header): clear the authored
                -- LumenSkylightLeaking override on EVERY volume (all 33
                -- carry it), so no volume boundary changes the world's GI
                -- anymore. Idempotent; volumes spawn fresh per course.
                if KILL_SKY_LEAK then
                    pcall(function()
                        local s = v.Settings
                        if s.bOverride_LumenSkylightLeaking == true then
                            s.bOverride_LumenSkylightLeaking = false
                            leakCleared = leakCleared + 1
                        end
                    end)
                end
                ppRefs[#ppRefs + 1] = e
            end
            local withBounds, tunnels = 0, 0
            for _, e2 in ipairs(ppRefs) do
                if e2.ox then withBounds = withBounds + 1 end
                if e2.isTunnel then tunnels = tunnels + 1 end
            end
            Log.Info(MODULE, "PP watcher armed", {
                volumes = #ppRefs, withBounds = withBounds, tunnels = tunnels,
                leakCleared = leakCleared,
            })
        end)
        return
    end

    -- Containment: which volume is the car inside right now? ENTER/EXIT logs
    -- identify tunnel volumes as the user simply drives around. The pawn ref
    -- is kept for the roof probe (trace WorldContextObject).
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

    -- Volume containment (RESEARCH ONLY since the road-data switch): the
    -- ENTER/EXIT lines remain the volume-classification tool but no longer
    -- feed the rain kill. Config.Tunnels.ProbePPVolumes revives them.
    if PROBE_PP then
        for i, e in ipairs(ppRefs) do
            if e.ox then
                local inside = math.abs(px - e.ox) <= e.ex
                    and math.abs(py - e.oy) <= e.ey
                    and math.abs(pz - e.oz) <= e.ez
                if inside and not ppInside[i] then
                    ppInside[i] = true
                    Log.Info(MODULE, "PP volume ENTER [" .. i .. "]", {
                        name = e.name or "?",
                        tunnel = e.isTunnel and "YES" or nil,
                        bias_authored = e.bias,
                        extent = string.format("%.0f,%.0f,%.0f", e.ex, e.ey, e.ez),
                    })
                elseif not inside and ppInside[i] then
                    ppInside[i] = nil
                    Log.Info(MODULE, "PP volume EXIT [" .. i .. "]", {name = e.name or "?"})
                end
            end
        end
    end

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
            -- Diagnosis aid (throttled): the probe with hit distance + hit
            -- component name, so a drive shows WHAT counts as cover and how
            -- high (deck tops expected; gantries = the false-positive
            -- candidates to tune the trace length against).
            if OVERPASS_DEBUG then
                local nowDbg = os.clock()
                if nowDbg - roofDbgLast >= 2.0 then
                    roofDbgLast = nowDbg
                    local h, okc, dist, hitName, leg = roofProbeGT(ksl, pawnObj, px, py, pz)
                    local field = "miss"
                    if h then
                        field = string.format("HIT(%s)@%s:%s", leg or "?",
                            dist and string.format("%.0f", dist) or "?",
                            hitName or "?")
                    elseif not okc then
                        field = "ERR"
                    end
                    Log.Info(MODULE, "Roof trace debug", {probe = field})
                end
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
        ppRefs = nil
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
        if cfg.ProbePPVolumes ~= nil then PROBE_PP = cfg.ProbePPVolumes end
        if type(cfg.TunnelVolumes) == "table" then
            TUNNEL_VOLUMES = {}
            for _, n in ipairs(cfg.TunnelVolumes) do TUNNEL_VOLUMES[n] = true end
        end
        if cfg.TunnelAutoByBias ~= nil then TUNNEL_AUTO = cfg.TunnelAutoByBias end
        if cfg.TunnelRainKill ~= nil then TUNNEL_RAIN_KILL = cfg.TunnelRainKill end
        if cfg.TunnelRainLookahead ~= nil then TUNNEL_LOOKAHEAD_S = cfg.TunnelRainLookahead end
        if cfg.KillVolumeSkylightLeak ~= nil then KILL_SKY_LEAK = cfg.KillVolumeSkylightLeak end
        if cfg.OverpassRainKill ~= nil then OVERPASS_KILL = cfg.OverpassRainKill end
        if cfg.OverpassTraceLength then OVERPASS_TRACE_LEN = cfg.OverpassTraceLength end
        if cfg.OverpassDebug ~= nil then OVERPASS_DEBUG = cfg.OverpassDebug end
        if cfg.RainClearPolls then RAIN_CLEAR_POLLS = cfg.RainClearPolls end
        if cfg.PollSecondsRain then POLL_RAIN_S = cfg.PollSecondsRain end
        if cfg.PollSecondsDry then POLL_DRY_S = cfg.PollSecondsDry end
    end

    featuresActive = TUNNEL_RAIN_KILL
        or PROBE_PP
        or KILL_SKY_LEAK

    isInitialized = true
    State.SetModuleStatus("tunnels", true)

    if not enabled then
        Log.Info(MODULE, "Tunnels module disabled in config")
        return true
    end

    Log.Info(MODULE, "Initializing tunnels module", {
        rainKill = TUNNEL_RAIN_KILL,
        overpass = OVERPASS_KILL,
        autoByBias = TUNNEL_AUTO,
        curated = (function() local n = 0 for _ in pairs(TUNNEL_VOLUMES) do n = n + 1 end return n end)(),
    })
    return true
end

function Tunnels.OnCourseLoad()
    ppRefs = nil            -- cached volume refs are course-world objects
    ppNextPoll = 0.0
    roofProbeLogged = false
    tunnelReset()           -- Weather.Apply on load clears any suppression
    armed = true
end

function Tunnels.OnCourseUnload()
    armed = false
    ppRefs = nil
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
