-- TXR Weather Mod v3.0
-- systems/gap_walls.lua
-- Shadow-blocker slabs: the SHIPPING half of the light-leak fix.
-- Extracted from tunnels.lua 2026-08-12; the authoring half (the live
-- editor) was split out to systems/slab_editor.lua 2026-08-14, which
-- release builds simply OMIT: no file, no keys, no dead config.
--
-- WHY THIS EXISTS: the map's covered galleries leak low sun through
-- geometry SEAMS (gaps with no faces, which no flag or material can
-- close: proven at the ginza gallery over three field rounds). The fix
-- is invisible shadow-only geometry standing on the seam line.
--
-- THE MACHINERY: hidden StaticMeshActors built from the engine cube
-- (proven cooked: the vehicle hitboxes use it), CastShadow +
-- bCastHiddenShadow so they write shadow depth without rendering,
-- collision off so nothing can ever hit them (except geo.solid props,
-- which keep collision and render: the jump ramp, cloned ground).
-- Movable mobility: VSM re-renders their shadow every frame, which is
-- what makes live editing possible.
--
-- Config.GapWalls.Slabs is the authoritative site list; the editor
-- prints paste-ready rows for it (Logs/slab_rows.txt).
--
-- COUPLING: one read-only external, Tunnels.GetCarPos() (the
-- containment poll's cached car position) for the proximity gate.
-- The editor consumes SpawnSlabGT/GetSlabs/DefaultVisible from here.

local GapWalls = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local GT = require("core.gt")
local State = require("core.state")
local Config = require("config")

local MODULE = "GapWalls"

-- Lazy-loaded to avoid circular dependencies
local Actors = nil
local UEHelpers = nil
local Tunnels = nil

local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

local function getUEHelpers()
    if not UEHelpers then
        pcall(function() UEHelpers = require("UEHelpers") end)
    end
    return UEHelpers
end

local function getCarPos()
    if not Tunnels then
        local ok, mod = pcall(require, "systems.tunnels")
        if ok then Tunnels = mod end
    end
    if Tunnels and Tunnels.GetCarPos then
        return Tunnels.GetCarPos()
    end
    return nil, nil, nil
end

-- ============== CONFIG-DERIVED (filled in Init, with safe fallbacks) ==============
local enabled = false          -- Config.GapWalls.Enabled
local GAP_VISIBLE = false      -- Config.GapWalls.Visible (debug: render
                               -- the slabs so placement can be checked
                               -- by eye at ANY sun state)
local GAP_MESH = "/Engine/BasicShapes/Cube.Cube"
-- cm, world axes; scale in meters (cube = 1 m).
local GAP_SLABS = {}
local GAP_CX, GAP_CY = 214618.0, -744809.0   -- proximity center (ginza)
local GAP_NEAR = 400000.0      -- 4 km proximity gate
local GAP_TRY_S = 5.0          -- attempt cadence while near
local GAP_MAX_TRIES = 60
local GAP_CHUNK = 6            -- slabs per GT closure: every SpawnActor
                               -- re-enters Lua through UE4SS's actor-hook
                               -- detour, and one 43-spawn closure died in
                               -- that machinery (2026-08-24 12:12:59 dump)

-- ============== STATE ==============
local isInitialized = false
local armed = false
local gapSpawned = false
local gapTries = 0
local gapNextTry = 0.0
local gapSpawnCursor = 0       -- next GAP_SLABS index already spawned
local gapChainActive = false   -- a chunk chain is in flight (tick holds off)
local spawnSrcLogged = false   -- one spawn-path line per world
local deferFailLogged = false  -- one deferred-fallback Warn per world
-- Live handles: {actor, geo={cx,cy,cz,yaw,pitch,roll,sx,sy,sz,solid}, sec}.
-- World-local like every actor ref in this codebase: dropped wholesale
-- on load/unload, every touch re-validated. The editor mutates this
-- same table (spawns, clones, deletions) through GetSlabs().
local gapActors = {}

-- Chain generation: GT.After continuations survive world swaps (gt.lua has
-- no unload purge), so each chunk closure carries the generation it was
-- armed under and aborts if a course load/unload bumped it since. Without
-- this, a stale continuation re-entered the NEXT world gate-bypassed and
-- could interleave with the tick's fresh chain (double spawn bursts).
local gapChainGen = 0
local gapChainArmedAt = 0.0   -- os.clock at arm, for the wedge self-heal

local function resetWorldState()
    gapSpawned = false
    gapTries = 0
    gapNextTry = 0.0
    gapSpawnCursor = 0
    gapChainActive = false
    gapChainGen = gapChainGen + 1
    gapActors = {}
    spawnSrcLogged = false
    deferFailLogged = false
end

-- ============== INTERNAL: spawning (game thread) ==============

--- FRotator (degrees) -> FQuat table, UE's own conversion formula.
--- Built in Lua so the deferred spawn's FTransform never touches the
--- rotator marshal (which drops Pitch and mis-axes Roll on this stack).
local function rotatorToQuat(pitchDeg, yawDeg, rollDeg)
    local d2 = math.pi / 360.0
    local sp, cp = math.sin(pitchDeg * d2), math.cos(pitchDeg * d2)
    local sy, cy = math.sin(yawDeg * d2), math.cos(yawDeg * d2)
    local sr, cr = math.sin(rollDeg * d2), math.cos(rollDeg * d2)
    return {
        X = cr * sp * sy - sr * cp * cy,
        Y = -cr * sp * cy - sr * cp * sy,
        Z = cr * cp * sy - sr * sp * cy,
        W = cr * cp * cy + sr * sp * sy,
    }
end

--- Deferred REFLECTED spawn (RE-UE4SS #527): world:SpawnActor is
--- UE4SS's own re-implementation of engine spawn internals and is
--- reported cross-game to corrupt state "after 3-10 spawns";
--- GameplayStatics' deferred pair spawns through the game's OWN
--- reflection instead, and its FTransform carries the full QUATERNION
--- (pitch AND roll land correctly, no rotator marshal involved).
local function spawnDeferredGT(world, cls, geo)
    local a = nil
    local why = nil
    local ok, err = pcall(function()
        local UEH = getUEHelpers()
        local gps = UEH and UEH.GetGameplayStatics and UEH.GetGameplayStatics()
        if not (gps and gps.IsValid and gps:IsValid()) then
            why = "no-GameplayStatics"
            return
        end
        local tf = {
            Rotation = rotatorToQuat(geo.pitch or 0.0, geo.yaw or 0.0,
                geo.roll or 0.0),
            Translation = { X = geo.cx, Y = geo.cy, Z = geo.cz },
            Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
        }
        -- 1 = ESpawnActorCollisionHandlingMethod::AlwaysSpawn; trailing
        -- 1 = ESpawnActorScaleMethod::MultiplyWithRoot (the UE5.1+ 6th
        -- param this call never passed - prime suspect for the fallback;
        -- harmless either way: Scale3D is 1,1,1 and the real scale is
        -- applied via SetActorScale3D afterwards).
        local actor = gps:BeginDeferredActorSpawnFromClass(
            world, cls, tf, 1, nil, 1)
        if actor == nil then why = "Begin returned nil"; return end
        if not (actor.IsValid and actor:IsValid()) then
            why = "Begin returned invalid " .. type(actor)
            return
        end
        gps:FinishSpawningActor(actor, tf)
        a = actor
    end)
    if not ok then why = tostring(err) end
    if (not a) and (not deferFailLogged) then
        deferFailLogged = true
        Log.Warn(MODULE, "Deferred spawn fell back", { why = why or "unknown" })
    end
    return a
end

--- Spawn ONE slab from a geo table. Returns the actor or nil.
local function spawnOneSlabGT(world, cls, mesh, geo, visible)
    local a = spawnDeferredGT(world, cls, geo)
    local deferred = a ~= nil
    if not a then
        pcall(function()
            -- Pseudo-path fallback. Roll is NOT in the spawn rotator:
            -- it lands on the wrong axis there (field 2026-08-24:
            -- pitch and roll moved the same); it goes in as a LOCAL
            -- delta below instead.
            a = world:SpawnActor(cls,
                { X = geo.cx, Y = geo.cy, Z = geo.cz },
                { Pitch = geo.pitch or 0.0, Yaw = geo.yaw, Roll = 0.0 })
        end)
    end
    if not spawnSrcLogged and a then
        spawnSrcLogged = true
        Log.Info(MODULE, "Spawn path this world", {
            src = deferred and "deferred-reflected" or "pseudo-SpawnActor",
        })
    end
    if not (a and a.IsValid and a:IsValid()) then return nil end
    -- solid = a physical prop (the jump ramp, cloned ground): collision
    -- stays on and it always renders; plain slabs are shadow-only ghosts
    if geo.solid then
        visible = true
    else
        pcall(function() a:SetActorEnableCollision(false) end)
    end
    local comp = nil
    pcall(function() comp = a.StaticMeshComponent end)
    if comp then
        -- StaticMeshActor spawns Mobility=Static, which rejects
        -- SetStaticMesh on a registered component: Movable first.
        pcall(function() comp:SetMobility(2) end)
        pcall(function() comp:SetStaticMesh(mesh) end)
        pcall(function() a:SetActorScale3D(
            { X = geo.sx, Y = geo.sy, Z = geo.sz }) end)
        if not visible then
            pcall(function() a:SetActorHiddenInGame(true) end)
        end
        pcall(function() comp.bCastShadowAsTwoSided = true end)
        pcall(function() comp.bCastHiddenShadow = true end)
        -- proxy rebuild so hidden+flags take (the shadow-fix recipe)
        pcall(function() comp:SetCastShadow(false) end)
        pcall(function() comp:SetCastShadow(true) end)
    end
    -- PSEUDO PATH ONLY: roll as a LOCAL rotation delta (after mobility
    -- is Movable): a local X-axis roll composes onto yaw+pitch exactly
    -- as FRotator's Yaw*Pitch*Roll does, and the K2 rotator marshal's
    -- pitch-drop cannot touch a pitch-0 delta. The deferred path
    -- already carries roll inside its quaternion (adding it again
    -- would double it).
    if not deferred and geo.roll and geo.roll ~= 0.0 then
        pcall(function() a:K2_AddActorLocalRotation(
            { Pitch = 0.0, Yaw = 0.0, Roll = geo.roll },
            false, {}, false) end)
    end
    return a
end

--- GT body: resolve the cube mesh and spawn the configured slabs in
--- CHUNKS of GAP_CHUNK per GT window, the chain continuing via
--- GT.After. Mesh/class/world are re-resolved EVERY chunk (no refs
--- carried across the gaps) and the teardown gate is re-checked at
--- run time like every GT closure; any bail-out clears the chain flag
--- so the 5s tick can re-arm. `gen` is the chain generation captured at
--- arm time: a stale continuation (world changed since) aborts silently
--- without touching the new world's state.
local function spawnGapWallsGT(gen)
    if gen ~= gapChainGen then return end
    if gapSpawned then gapChainActive = false; return end
    local actors = getActors()
    if actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
        gapChainActive = false
        return
    end
    local mesh = nil
    pcall(function()
        local m = StaticFindObject(GAP_MESH)
        if m and m.IsValid and m:IsValid() then mesh = m end
    end)
    -- First attempt always logs (two silent-failure rounds were enough):
    -- one line tells us the gate fired AND whether the mesh resolves.
    if gapSpawnCursor == 0
        and (gapTries <= 1 or (not mesh and gapTries >= GAP_MAX_TRIES - 1)) then
        Log.Info(MODULE, "Gap walls attempt", {
            try = gapTries, mesh = mesh and "resolved" or "nil",
        })
    end
    if not mesh then gapChainActive = false; return end
    local cls = nil
    pcall(function() cls = StaticFindObject("/Script/Engine.StaticMeshActor") end)
    if not cls then
        gapChainActive = false
        Log.Warn(MODULE, "Gap walls: StaticMeshActor class not found")
        return
    end
    local UEH = getUEHelpers()
    local world = UEH and UEH.GetWorld and UEH.GetWorld()
    if not world then gapChainActive = false; return end
    local n = 0
    while gapSpawnCursor < #GAP_SLABS and n < GAP_CHUNK do
        gapSpawnCursor = gapSpawnCursor + 1
        local gd = GAP_SLABS[gapSpawnCursor]
        local okS, sErr = pcall(function()
            local geo = { cx = gd.cx, cy = gd.cy, cz = gd.cz, yaw = gd.yaw,
                          sx = gd.sx, sy = gd.sy, sz = gd.sz,
                          pitch = gd.pitch, roll = gd.roll, solid = gd.solid }
            local a = spawnOneSlabGT(world, cls, mesh, geo, GAP_VISIBLE)
            if not a then
                Log.Warn(MODULE, "Gap wall spawn returned no actor",
                    { sec = gd.sec })
                return
            end
            gapActors[#gapActors + 1] = { actor = a, geo = geo, sec = gd.sec }
            Log.Info(MODULE, "Gap shadow wall spawned", {
                sec = gd.sec, visible = tostring(GAP_VISIBLE),
                at = string.format("%.0f,%.0f,%.0f yaw=%.1f", gd.cx, gd.cy,
                    gd.cz, gd.yaw),
            })
        end)
        if not okS then
            Log.Warn(MODULE, "Slab spawn body error",
                { sec = gd.sec, err = tostring(sErr) })
        end
        n = n + 1
    end
    if gapSpawnCursor < #GAP_SLABS then
        GT.After(0.25, function() spawnGapWallsGT(gen) end)
        return
    end
    gapChainActive = false
    if #gapActors > 0 then
        gapSpawned = true
        Log.Info(MODULE, "Gap shadow walls active", { walls = #gapActors })
    else
        gapSpawnCursor = 0   -- nothing spawned: the tick retries in full
    end
end

--- Async-side gate: cheap distance check on the poll-cached car
--- position; marshals the spawn to the GT on its own slow cadence.
local function gapWallsTick(now)
    if gapSpawned or gapTries >= GAP_MAX_TRIES then return end
    if #GAP_SLABS == 0 then return end
    if gapChainActive then
        -- Wedge self-heal: a chain closure evicted by the GT queue cap
        -- (pump dead) would leave the flag latched and the tick inert.
        -- Bump the generation so the stalled closure, if it ever drains,
        -- aborts at its gen check instead of interleaving with the fresh
        -- chain (two live chains = double spawns per GT window).
        if (now - gapChainArmedAt) > 30.0 then
            gapChainGen = gapChainGen + 1
            gapChainActive = false
        end
        return
    end
    if now < gapNextTry then return end
    gapNextTry = now + GAP_TRY_S
    local px, py = getCarPos()
    if not (px and py) then return end
    local dx, dy = px - GAP_CX, py - GAP_CY
    if (dx * dx + dy * dy) > (GAP_NEAR * GAP_NEAR) then return end
    gapTries = gapTries + 1
    if ExecuteInGameThread then
        gapChainActive = true
        gapChainArmedAt = now
        local gen = gapChainGen
        pcall(function() GT.Run(function() spawnGapWallsGT(gen) end) end)
    end
end

-- ============== PUBLIC API ==============

function GapWalls.Init()
    if isInitialized then return true end

    local cfg = Config.GapWalls
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.Visible ~= nil then GAP_VISIBLE = cfg.Visible end
    end

    -- Site list: data/gap_slabs.lua is the authored campaign home
    -- (config.lua is user knobs and gets replaced on update; the
    -- campaign will be LARGE). Config.GapWalls.Slabs appends on top
    -- as a user/experiment extension hook.
    pcall(function()
        local d = require("data.gap_slabs")
        if type(d) == "table" then GAP_SLABS = d end
    end)
    if cfg and type(cfg.Slabs) == "table" then
        for _, s in ipairs(cfg.Slabs) do
            GAP_SLABS[#GAP_SLABS + 1] = s
        end
    end

    isInitialized = true
    State.SetModuleStatus("gap_walls", true)

    if not enabled then
        Log.Info(MODULE, "Gap walls module disabled in config")
        return true
    end
    Log.Info(MODULE, "Initializing gap walls", {
        slabs = #GAP_SLABS, visible = GAP_VISIBLE,
    })
    return true
end

function GapWalls.OnCourseLoad()
    resetWorldState()   -- spawned slabs died with the old world
    armed = true
end

function GapWalls.OnCourseUnload()
    armed = false
    resetWorldState()
end

--- Per-tick entry (8 Hz from main); self-paces internally.
function GapWalls.Tick()
    if not (enabled and armed and isInitialized) then return true end
    gapWallsTick(os.clock())
    return true
end

--- EDITOR API (systems/slab_editor.lua only; absent in release builds).
--- Spawn one slab on the game thread, resolving mesh/class/world here.
--- meshOverride lets the ray cloner spawn a traced mesh instead of the
--- engine cube. Returns the actor or nil.
function GapWalls.SpawnSlabGT(geo, visible, meshOverride)
    local mesh, cls = meshOverride, nil
    if not mesh then
        pcall(function()
            local m = StaticFindObject(GAP_MESH)
            if m and m.IsValid and m:IsValid() then mesh = m end
        end)
    end
    pcall(function() cls = StaticFindObject("/Script/Engine.StaticMeshActor") end)
    local UEH = getUEHelpers()
    local world = UEH and UEH.GetWorld and UEH.GetWorld()
    if not (mesh and cls and world) then return nil end
    return spawnOneSlabGT(world, cls, mesh, geo, visible)
end

--- The live slab list (mutable by the editor: clones, deletions).
function GapWalls.GetSlabs()
    return gapActors
end

--- Config visibility for de-selected slabs (ghost mode).
function GapWalls.DefaultVisible()
    return GAP_VISIBLE
end

function GapWalls.GetStatus()
    return {
        initialized = isInitialized,
        enabled = enabled,
        armed = armed,
        spawned = gapSpawned,
        slabs = #gapActors,
    }
end

function GapWalls.IsInitialized()
    return isInitialized
end

--- Alias so the module can be ticked as either Tick() or Update().
GapWalls.Update = GapWalls.Tick

return GapWalls
